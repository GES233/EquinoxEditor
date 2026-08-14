defmodule EquinoxDomain.Windowing do
  @moduledoc """
  分窗（Windowing）——`[{note_id, Note, span}]` → 瞬态 `[Window]` 的单向纯投影。

  基准规则移植自旧版（z 库）`RestSplit3Beats` 策略：

  1. content span = 音符 span ∪ `opts[:extra_spans]`（外部 content 区间，
     如 Metric 锚 patch 的 tick 区间——对应旧版「scope 撑窗」语义，
     由调用方（kernel）从 patch 锚推导传入）。
  2. 相邻 content 空档 `gap < 3 * beat_ticks` → 粘连；
     `gap >= 3 * beat_ticks` → 切开，**前 1 拍归前窗、后 2 拍归后窗**，
     更长空隙中间留死区（不进任何窗口）。
  3. `beat_ticks` 取 `opts[:beat_ticks] || opts[:tpqn] || 480`
     （无 TimeSig 时的显式假定：四分音符 = 一拍）。

  随后应用 slice_flag 两遍修正（移植旧 `SlicePolicy`）：

  1. `force_merge` 并窗——右窗首个音符的 flag 为 `:force_merge` 时并入左窗
     （fold 处理链式合并）；
  2. `force_slice` 切窗——窗内（非首个音符）flag 为 `:force_slice` 的音符
     在其 span 起点处下刀；退化切点（零长半窗，如和弦同 start）跳过。

  flag 管辖音符**之前**的边界，每个边界由右侧音符独立管辖，两遍修正互不冲突。
  纯函数，无任何 coconut 写路径耦合。
  """

  alias EquinoxDomain.Score.SliceFlag
  alias EquinoxDomain.Windowing.Window

  @default_beat_ticks 480

  @typedoc "分窗输入项：`{note_id, note, {start_tick, end_tick}}`（来自 `Coconut.Edit.Track.view/1`）。"
  @type item :: {Coconut.Score.Note.note_id(), Coconut.Score.Note.t(), Coconut.Edit.Track.span()}

  @doc """
  对 `items` 跑分窗投影，返回 `{:ok, [Window.t()]}`（按 start 升序）。

  ## 选项

  - `:beat_ticks` — 一拍 tick 数（优先）
  - `:tpqn` — 无 `:beat_ticks` 时当作一拍
  - `:extra_spans` — 额外 content 区间 `[{start_tick, end_tick}]`，默认 `[]`
  """
  @spec slice([item()], keyword()) :: {:ok, [Window.t()]} | {:error, term()}
  def slice(items, opts \\ []) when is_list(items) do
    beat = beat_ticks(opts)
    threshold = 3 * beat

    note_spans =
      Enum.map(items, fn {id, _note, {start_tick, end_tick}} ->
        %{start: start_tick, end: end_tick, note_ids: [id]}
      end)

    extra_spans =
      opts
      |> Keyword.get(:extra_spans, [])
      |> Enum.map(fn {start_tick, end_tick} ->
        %{start: start_tick, end: end_tick, note_ids: []}
      end)

    spans = Enum.sort_by(note_spans ++ extra_spans, & &1.start)

    blocks =
      spans
      |> merge_spans(threshold)
      |> apply_cut_ownership(threshold, beat)

    notes_by_id = Map.new(items, fn {id, note, _span} -> {id, note} end)
    spans_by_id = Map.new(items, fn {id, _note, span} -> {id, span} end)

    with {:ok, windows} <- build_windows(blocks) do
      windows =
        windows
        |> apply_force_merges(notes_by_id)
        |> apply_force_slices(notes_by_id, spans_by_id)

      {:ok, windows}
    end
  end

  # ---- 一拍 ----

  defp beat_ticks(opts) do
    cond do
      is_integer(opts[:beat_ticks]) and opts[:beat_ticks] > 0 -> opts[:beat_ticks]
      is_integer(opts[:tpqn]) and opts[:tpqn] > 0 -> opts[:tpqn]
      true -> @default_beat_ticks
    end
  end

  # ---- 基准规则（RestSplit3Beats 移植） ----

  # 将已排序 spans 合成 content blocks；threshold 用于「小缝必粘」
  defp merge_spans([], _threshold), do: []

  defp merge_spans([first | rest], threshold) do
    rest
    |> Enum.reduce({[first], first}, fn span, {acc, prev} ->
      gap = span.start - prev.end

      if gap < threshold do
        merged = %{
          start: min(prev.start, span.start),
          end: max(prev.end, span.end),
          note_ids: prev.note_ids ++ span.note_ids
        }

        {[merged | tl(acc)], merged}
      else
        {[span | acc], span}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # 对已切开的相邻块应用 1/2 空拍归属（merge_spans 已在 gap < threshold 时
  # 粘连，故此处相邻块 gap 必 >= threshold）
  defp apply_cut_ownership([], _threshold, _beat), do: []
  defp apply_cut_ownership([only], _threshold, _beat), do: [only]

  defp apply_cut_ownership(blocks, threshold, beat) do
    blocks
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({[], hd(blocks)}, fn [_left, right], {done, cur_left} ->
      gap = right.start - cur_left.end

      {left2, right2} =
        if gap >= threshold do
          {
            %{cur_left | end: cur_left.end + beat},
            %{right | start: max(0, right.start - 2 * beat)}
          }
        else
          {cur_left, right}
        end

      # 校正：归属后不得交叉
      {left2, right2} =
        if left2.end > right2.start do
          mid = div(cur_left.end + right.start, 2)
          {%{left2 | end: mid}, %{right2 | start: mid}}
        else
          {left2, right2}
        end

      {[left2 | done], right2}
    end)
    |> then(fn {done, last} -> Enum.reverse([last | done]) end)
  end

  defp build_windows(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, acc} ->
      case Window.new(%{
             start_tick: block.start,
             end_tick: block.end,
             note_ids: Enum.uniq(block.note_ids)
           }) do
        {:ok, window} -> {:cont, {:ok, [window | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      {:error, _} = err -> err
    end
  end

  # ---- force_merge：合并相邻窗 ----

  # fold 自左向右，acc 头部始终是「最近一窗」（可能已链式合并过多窗）；
  # 右窗首个音符的 flag 为 :force_merge 时把它并入该窗。
  defp apply_force_merges(windows, notes_by_id) do
    windows
    |> Enum.reduce([], fn window, acc ->
      first_id = List.first(window.note_ids)

      with [left | rest] <- acc,
           true <- not is_nil(first_id),
           :force_merge <- notes_by_id |> Map.fetch!(first_id) |> SliceFlag.get(),
           {:ok, merged} <-
             Window.new(%{
               start_tick: left.start_tick,
               end_tick: window.end_tick,
               note_ids: left.note_ids ++ window.note_ids
             }) do
        [merged | rest]
      else
        # 无左邻 / 右窗首音符非 :force_merge / Window.new 失败（理论不可达）→ 保持原窗
        _ -> [window | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ---- force_slice：窗内切窗 ----

  defp apply_force_slices(windows, notes_by_id, spans_by_id) do
    Enum.flat_map(windows, &split_window(&1, notes_by_id, spans_by_id))
  end

  # 窗内非首音符中 flag 为 :force_slice 的都是切点，逐一切
  defp split_window(%Window{} = window, notes_by_id, spans_by_id) do
    cut_ids =
      window.note_ids
      |> Enum.drop(1)
      |> Enum.filter(fn id ->
        notes_by_id |> Map.fetch!(id) |> SliceFlag.get() == :force_slice
      end)

    do_split(window, cut_ids, spans_by_id, [])
  end

  defp do_split(%Window{} = window, [], _spans_by_id, acc),
    do: Enum.reverse([window | acc])

  defp do_split(%Window{} = window, [cut_id | rest], spans_by_id, acc) do
    {cut_start, _} = Map.fetch!(spans_by_id, cut_id)
    {left_ids, right_ids} = Enum.split_while(window.note_ids, &(&1 != cut_id))

    with true <- cut_start > window.start_tick and cut_start < window.end_tick,
         {:ok, left} <-
           Window.new(%{
             start_tick: window.start_tick,
             end_tick: cut_start,
             note_ids: left_ids
           }),
         {:ok, right} <-
           Window.new(%{
             start_tick: cut_start,
             end_tick: window.end_tick,
             note_ids: right_ids
           }) do
      do_split(right, rest, spans_by_id, [left | acc])
    else
      # 退化切点：音符起点落在当前窗边界上/外（如和弦等同 tick 音符之间
      # 无法下刀）——跳过该刀，当前窗保持完整，继续检查后续切点
      _ -> do_split(window, rest, spans_by_id, acc)
    end
  end
end
