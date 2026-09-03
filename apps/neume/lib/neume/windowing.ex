defmodule Neume.Windowing do
  @moduledoc """
  分窗（Windowing）——`[{note_id, {start_tick, end_tick}}]` → 瞬态 `[Window]`
  的单向纯投影，用于增量渲染的失效粒度。

  基准规则移植自旧版 `RestSplit3Beats`：

  1. 相邻音符空档 `gap < 3 * beat_ticks` → 粘连进同一窗；
  2. `gap >= 3 * beat_ticks` → 切开，**前 1 拍归前窗、后 2 拍归后窗**，
     更长空隙中间留死区（不进任何窗口）；
  3. `beat_ticks` 取 `opts[:beat_ticks] || opts[:tpqn] || 480`
     （无 TimeSig 时的显式假定：四分音符 = 一拍）。

  窗口是瞬态投影，不持久化；每次编辑后整体重算。
  """

  @default_beat_ticks 480

  defmodule Window do
    @moduledoc "分窗输出：半开 tick 区间 + 窗内音符 id（按时间升序）。"

    @enforce_keys [:start_tick, :end_tick, :note_ids]
    defstruct [:start_tick, :end_tick, :note_ids]

    @type t :: %__MODULE__{
            start_tick: non_neg_integer(),
            end_tick: non_neg_integer(),
            note_ids: [term()]
          }
  end

  @typedoc "分窗输入项：`{note_id, {start_tick, end_tick}}`。"
  @type item :: {term(), {non_neg_integer(), non_neg_integer()}}

  @doc """
  对 `items` 跑分窗投影，返回按 start 升序的 `[Window.t()]`。

  ## 选项

  - `:beat_ticks` — 一拍 tick 数（优先）
  - `:tpqn` — 无 `:beat_ticks` 时当作一拍
  """
  @spec split([item()], keyword()) :: [Window.t()]
  def split(items, opts \\ []) when is_list(items) do
    beat = beat_ticks(opts)
    threshold = 3 * beat

    spans =
      items
      |> Enum.map(fn {id, {start_tick, end_tick}} ->
        %{start: start_tick, end: end_tick, note_ids: [id]}
      end)
      |> Enum.sort_by(& &1.start)

    spans
    |> merge_spans(threshold)
    |> apply_cut_ownership(threshold, beat)
    |> Enum.map(fn block ->
      %Window{
        start_tick: block.start,
        end_tick: block.end,
        note_ids: Enum.uniq(block.note_ids)
      }
    end)
  end

  defp beat_ticks(opts) do
    cond do
      is_integer(opts[:beat_ticks]) and opts[:beat_ticks] > 0 -> opts[:beat_ticks]
      is_integer(opts[:tpqn]) and opts[:tpqn] > 0 -> opts[:tpqn]
      true -> @default_beat_ticks
    end
  end

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
end
