defmodule Equinox.Domain.Slicer do
  @moduledoc """
  将一条完整的轨道（Track）中的 Notes 根据休止符间隔拆分成多个 Slice 或 Segment 候选。
  """

  alias Equinox.Domain.Note
  alias Equinox.Editor.Segment
  alias Equinox.Track

  @default_min_rest_ticks 960

  @type id :: String.t()

  @type slice :: %{
          id: id(),
          start_tick: non_neg_integer(),
          end_tick: non_neg_integer(),
          notes: [Note.t()]
        }

  @spec slice([Note.t()], non_neg_integer()) :: [slice()]
  def slice(notes, min_rest_ticks \\ @default_min_rest_ticks) do
    notes
    |> repair_slice_flags(min_rest_ticks)
    |> slices_from_flags()
  end

  @spec repair_slice_flags([Note.t()], non_neg_integer()) :: [Note.t()]
  def repair_slice_flags(notes, min_rest_ticks \\ @default_min_rest_ticks) do
    notes
    |> Enum.sort_by(&{&1.start_tick, Note.end_tick(&1), &1.id})
    |> partition_notes(min_rest_ticks)
    |> Enum.flat_map(&apply_slice_flags/1)
  end

  @spec slices_from_flags([Note.t()]) :: [slice()]
  def slices_from_flags(notes) do
    notes
    |> Enum.sort_by(&{&1.start_tick, Note.end_tick(&1), &1.id})
    |> Enum.reduce({[], nil}, fn note, {acc, current} ->
      case {note.slice_flag, current} do
        {{:on_start, slice_id}, nil} ->
          {acc, begin_slice(slice_id, note)}

        {{:on_start, slice_id}, %{notes: current_notes} = open_slice} when current_notes != [] ->
          finished = finalize_slice(open_slice)
          {[finished | acc], begin_slice(slice_id, note)}

        {:on_end, nil} ->
          {acc, begin_slice(Equinox.Utils.ID.generate(), note)}

        {:on_end, open_slice} ->
          finished = open_slice |> append_note(note) |> finalize_slice()
          {[finished | acc], nil}

        {_, nil} ->
          {acc, begin_slice(Equinox.Utils.ID.generate(), note)}

        {_, open_slice} ->
          {acc, append_note(open_slice, note)}
      end
    end)
    |> finalize_open_slice()
    |> Enum.reverse()
  end

  @spec materialize_segments(Track.id(), [Note.t()], keyword()) :: [Segment.t()]
  def materialize_segments(track_id, notes, opts \\ []) do
    min_rest_ticks = Keyword.get(opts, :min_rest_ticks, @default_min_rest_ticks)

    segment_ids =
      opts
      |> Keyword.get(:segment_ids, %{})
      |> Enum.into(%{})
      |> Map.new(fn
        {k, v} when is_binary(k) -> {k, v}
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      end)

    name_prefix = Keyword.get(opts, :name_prefix, "Slice")

    notes
    |> slice(min_rest_ticks)
    |> Enum.with_index(1)
    |> Enum.map(fn {slice, index} ->
      segment_id = Map.get(segment_ids, slice.id, slice.id)

      Segment.new(%{
        id: segment_id,
        track_id: track_id,
        name: "#{name_prefix} #{index}",
        offset_tick: slice.start_tick,
        notes: Enum.map(slice.notes, &%{&1 | start_tick: &1.start_tick - slice.start_tick}),
        extra: %{slice_id: slice.id}
      })
    end)
  end

  defp partition_notes([], _min_rest_ticks), do: []

  defp partition_notes([first | rest], min_rest_ticks) do
    {groups, current_group, _previous_note} =
      Enum.reduce(rest, {[], [first], first}, fn note, {groups, current_group, previous_note} ->
        if split_before_note?(previous_note, note, min_rest_ticks) do
          {[Enum.reverse(current_group) | groups], [note], note}
        else
          {groups, [note | current_group], note}
        end
      end)

    Enum.reverse([Enum.reverse(current_group) | groups])
  end

  defp apply_slice_flags(notes) do
    slice_id = choose_slice_id(notes)

    case notes do
      [single_note] ->
        [%{single_note | slice_flag: {:on_start, slice_id}}]

      [first_note | rest] ->
        last_index = length(rest) - 1

        rest
        |> Enum.with_index()
        |> Enum.map(fn
          {note, ^last_index} -> %{note | slice_flag: :on_end}
          {note, _index} -> %{note | slice_flag: nil}
        end)
        |> List.insert_at(0, %{first_note | slice_flag: {:on_start, slice_id}})
    end
  end

  defp split_before_note?(previous_note, note, min_rest_ticks) do
    gap = note.start_tick - Note.end_tick(previous_note)

    gap >= min_rest_ticks or Note.manual_slice_start?(note) or
      Note.manual_slice_end?(previous_note)
  end

  defp choose_slice_id([first_note | _rest]) do
    cond do
      Note.manual_slice_start?(first_note) ->
        Note.slice_start_id(Note.manual_slice_flag(first_note))

      Note.slice_start?(first_note.slice_flag) ->
        Note.slice_start_id(first_note.slice_flag)

      true ->
        Equinox.Utils.ID.generate()
    end
  end

  defp begin_slice(slice_id, note) do
    %{
      id: slice_id,
      start_tick: note.start_tick,
      end_tick: Note.end_tick(note),
      notes: [note]
    }
  end

  defp append_note(slice, note) do
    %{slice | end_tick: max(slice.end_tick, Note.end_tick(note)), notes: slice.notes ++ [note]}
  end

  defp finalize_slice(slice), do: slice

  defp finalize_open_slice({acc, nil}), do: acc
  defp finalize_open_slice({acc, open_slice}), do: [finalize_slice(open_slice) | acc]
end
