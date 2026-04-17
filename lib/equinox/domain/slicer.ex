defmodule Equinox.Domain.Slicer do
  @moduledoc """
  将一条完整的轨道（Track）中的 Notes 根据休止符间隔拆分成多个 Segment 的范围。
  """

  alias Equinox.Domain.Note

  @type slice :: %{
          start_tick: non_neg_integer(),
          end_tick: non_neg_integer(),
          notes: [Note.t()]
        }

  @doc """
  将 `notes` 列表（必须按 `start_tick` 排序）切片。
  `min_rest_ticks` 决定了多长的休止符才会触发拆段。
  """
  @spec slice([Note.t()], non_neg_integer()) :: [slice()]
  # 默认 960 ticks = 半个 4/4 拍 (假设 1 beat = 480 ticks)
  def slice(notes, min_rest_ticks \\ 960)

  def slice([], _min_rest), do: []

  def slice([first | rest], min_rest_ticks) do
    do_slice(
      rest,
      min_rest_ticks,
      [first],
      first.start_tick,
      first.start_tick + first.duration_tick,
      []
    )
    |> Enum.reverse()
  end

  defp do_slice([], _min_rest, current_chunk, start_t, end_t, acc) do
    finished_slice = %{
      start_tick: start_t,
      end_tick: end_t,
      notes: Enum.reverse(current_chunk)
    }

    [finished_slice | acc]
  end

  defp do_slice([note | rest], min_rest_ticks, current_chunk, start_t, end_t, acc) do
    gap = note.start_tick - end_t

    if gap >= min_rest_ticks do
      # 触发拆段
      finished_slice = %{
        start_tick: start_t,
        end_tick: end_t,
        notes: Enum.reverse(current_chunk)
      }

      do_slice(
        rest,
        min_rest_ticks,
        [note],
        note.start_tick,
        note.start_tick + note.duration_tick,
        [finished_slice | acc]
      )
    else
      # 继续堆叠
      new_end = max(end_t, note.start_tick + note.duration_tick)
      do_slice(rest, min_rest_ticks, [note | current_chunk], start_t, new_end, acc)
    end
  end
end
