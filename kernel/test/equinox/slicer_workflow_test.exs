defmodule Equinox.SlicerWorkflowTest do
  use ExUnit.Case, async: true

  alias Equinox.Domain.Note
  alias Equinox.Domain.Slicer
  alias Equinox.Project
  alias Equinox.Track

  test "bulk note import materializes phrase-like segments onto a track" do
    notes = [
      Note.new(%{id: "n1", start_tick: 0, duration_tick: 480, key: 60, lyric: "la"}),
      Note.new(%{id: "n2", start_tick: 480, duration_tick: 480, key: 62, lyric: "li"}),
      Note.new(%{id: "n3", start_tick: 2160, duration_tick: 240, key: 64, lyric: "lu"}),
      Note.new(%{id: "n4", start_tick: 2400, duration_tick: 240, key: 65, lyric: "na"})
    ]

    segments =
      Slicer.materialize_segments("track-1", notes,
        min_rest_ticks: 960,
        name_prefix: "Imported"
      )

    track =
      Track.new(%{
        id: "track-1",
        segments: Map.new(segments, fn segment -> {segment.id, segment} end)
      })

    project = Project.new(%{tracks: %{"track-1" => track}})

    assert [first, second] = Track.list_segments(track) |> Enum.sort_by(& &1.offset_tick)
    assert first.name == "Imported 1"
    assert first.offset_tick == 0
    assert Enum.map(first.notes, & &1.start_tick) == [0, 480]
    assert Enum.map(first.notes, & &1.id) == ["n1", "n2"]
    assert is_binary(first.extra.slice_id)

    assert second.name == "Imported 2"
    assert second.offset_tick == 2160
    assert Enum.map(second.notes, & &1.start_tick) == [0, 240]
    assert Enum.map(second.notes, & &1.id) == ["n3", "n4"]
    assert is_binary(second.extra.slice_id)

    assert {:ok, persisted_track} = Project.get_track(project, "track-1")
    assert map_size(persisted_track.segments) == 2
  end

  test "incremental note entry keeps segment identity stable across re-materialization" do
    initial_notes = [
      Note.new(%{id: "n1", start_tick: 0, duration_tick: 480, key: 60, lyric: "la"})
    ]

    repaired_initial_notes = Slicer.repair_slice_flags(initial_notes, 960)
    [first_segment] = Slicer.materialize_segments("track-1", repaired_initial_notes, min_rest_ticks: 960)

    assert first_segment.offset_tick == 0
    assert Enum.map(first_segment.notes, & &1.id) == ["n1"]

    slice_id_map = %{first_segment.extra.slice_id => first_segment.id}

    contiguous_notes =
      repaired_initial_notes ++
        [Note.new(%{id: "n2", start_tick: 480, duration_tick: 480, key: 62, lyric: "li"})]

    repaired_contiguous_notes = Slicer.repair_slice_flags(contiguous_notes, 960)

    [same_segment] =
      Slicer.materialize_segments("track-1", repaired_contiguous_notes,
        min_rest_ticks: 960,
        segment_ids: slice_id_map
      )

    assert same_segment.id == first_segment.id
    assert same_segment.extra.slice_id == first_segment.extra.slice_id
    assert Enum.map(same_segment.notes, & &1.id) == ["n1", "n2"]

    expanded_notes =
      repaired_contiguous_notes ++
        [Note.new(%{id: "n3", start_tick: 2160, duration_tick: 240, key: 64, lyric: "lu"})]

    repaired_expanded_notes = Slicer.repair_slice_flags(expanded_notes, 960)

    segment_ids = %{
      same_segment.extra.slice_id => same_segment.id
    }

    [preserved_segment, new_segment] =
      Slicer.materialize_segments("track-1", repaired_expanded_notes,
        min_rest_ticks: 960,
        segment_ids: segment_ids
      )

    assert preserved_segment.id == same_segment.id
    assert preserved_segment.extra.slice_id == same_segment.extra.slice_id
    assert Enum.map(preserved_segment.notes, & &1.id) == ["n1", "n2"]

    assert Enum.map(new_segment.notes, & &1.id) == ["n3"]
    assert new_segment.offset_tick == 2160
    assert new_segment.id == new_segment.extra.slice_id
    refute new_segment.id == preserved_segment.id
  end
end
