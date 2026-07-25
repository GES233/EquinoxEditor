defmodule EquinoxDomain.Score.SlicePolicy do
  @moduledoc """
  Equinox 窗口策略 = zongzi 默认 `RestSplit3Beats` + slice_flag 两遍修正。

  slice_flag 语义见 `EquinoxDomain.Score.SliceFlag`：flag 管辖音符**之前**
  的边界，每个边界由右侧音符的 flag 独立管辖，因此两遍修正之间无冲突：

  1. `apply_force_merges` — 相邻片边界处，右片首个 seq 的音符 flag 为
     `:force_merge` → 合并两片（fold 处理链式合并）；
  2. `apply_force_slices` — 片内（非首 seq）flag 为 `:force_slice` 的
     音符 → 在该 seq 处切片，一片多个 force_slice 逐一切。
  """

  @behaviour Zongzi.Windowing.Strategy

  alias EquinoxDomain.Score.SliceFlag
  alias Zongzi.Windowing.{Context, RestSplit3Beats, Segment}

  @impl true
  def window(%Context{} = ctx) do
    with {:ok, %Context{} = ctx} <- RestSplit3Beats.window(ctx) do
      segments =
        ctx.current_segments
        |> apply_force_merges(ctx.notes_by_seq)
        |> apply_force_slices(ctx.notes_by_seq)

      {:ok, %{ctx | current_segments: segments}}
    end
  end

  # ---- force_merge：合并相邻片 ----

  # fold 自左向右，acc 头部始终是「最近一片」（可能已链式合并过多片）；
  # 右片首 seq 的音符 flag 为 :force_merge 时把它并入该片。
  defp apply_force_merges(segments, notes_by_seq) do
    segments
    |> Enum.reduce([], fn seg, acc ->
      first_seq = List.first(seg.seq_ids)

      with [left | rest] <- acc,
           true <- not is_nil(first_seq),
           :force_merge <- notes_by_seq |> Map.fetch!(first_seq) |> SliceFlag.get(),
           {:ok, merged} <-
             Segment.new(left.start_tick, seg.end_tick, left.seq_ids ++ seg.seq_ids) do
        [merged | rest]
      else
        # 无左邻 / 右片首音符非 :force_merge / Segment.new 失败（理论不可达）→ 保持原片
        _ -> [seg | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ---- force_slice：片内切片 ----

  defp apply_force_slices(segments, notes_by_seq) do
    Enum.flat_map(segments, &split_segment(&1, notes_by_seq))
  end

  # 片内非首 seq 中 flag 为 :force_slice 的音符都是切点，逐一切
  defp split_segment(%Segment{} = seg, notes_by_seq) do
    cut_seqs =
      seg.seq_ids
      |> Enum.drop(1)
      |> Enum.filter(fn seq ->
        notes_by_seq |> Map.fetch!(seq) |> SliceFlag.get() == :force_slice
      end)

    do_split(seg, cut_seqs, notes_by_seq, [])
  end

  defp do_split(%Segment{} = seg, [], _notes_by_seq, acc), do: Enum.reverse([seg | acc])

  defp do_split(%Segment{} = seg, [cut_seq | rest], notes_by_seq, acc) do
    note = Map.fetch!(notes_by_seq, cut_seq)
    {left_seqs, right_seqs} = Enum.split_while(seg.seq_ids, &(&1 != cut_seq))

    with true <- note.start_tick > seg.start_tick and note.start_tick < seg.end_tick,
         {:ok, left} <- Segment.new(seg.start_tick, note.start_tick, left_seqs),
         {:ok, right} <- Segment.new(note.start_tick, seg.end_tick, right_seqs) do
      do_split(right, rest, notes_by_seq, [left | acc])
    else
      # 退化切点：note.start_tick 落在当前片边界上/外（如和弦等同 tick 音符
      # 之间无法下刀），或 Segment.new 报错——跳过该刀，当前片保持完整，
      # 继续检查后续切点
      _ -> do_split(seg, rest, notes_by_seq, acc)
    end
  end
end
