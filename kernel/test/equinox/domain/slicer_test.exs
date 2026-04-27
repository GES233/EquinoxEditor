defmodule Equinox.Domain.SlicerTest do
  use ExUnit.Case, async: true

  alias Equinox.Domain.Note
  alias Equinox.Domain.Slicer

  describe "repair_slice_flags/2" do
    test "marks slice starts and ends from rest gaps" do
      notes = [
        Note.new(%{id: "n1", start_tick: 0, duration_tick: 480, lyric: "a"}),
        Note.new(%{id: "n2", start_tick: 480, duration_tick: 480, lyric: "b"}),
        Note.new(%{id: "n3", start_tick: 2160, duration_tick: 240, lyric: "c"})
      ]

      repaired = Slicer.repair_slice_flags(notes, 960)

      assert [first, second, third] = repaired
      assert match?({:on_start, _}, first.slice_flag)
      assert second.slice_flag == :on_end
      assert match?({:on_start, _}, third.slice_flag)
    end

    test "keeps manual single-note slice overrides" do
      notes = [
        Note.new(%{id: "n1", start_tick: 0, duration_tick: 480})
        |> Note.put_manual_slice_flag({:on_start, "solo-slice"})
      ]

      repaired = Slicer.repair_slice_flags(notes, 960)

      assert [%{slice_flag: {:on_start, "solo-slice"}}] = repaired
    end

    test "splits slices on manual boundaries even without rest gap" do
      notes = [
        Note.new(%{id: "n1", start_tick: 0, duration_tick: 480})
        |> Note.put_manual_slice_flag(:on_end),
        Note.new(%{id: "n2", start_tick: 480, duration_tick: 480})
        |> Note.put_manual_slice_flag({:on_start, "manual-start"}),
        Note.new(%{id: "n3", start_tick: 960, duration_tick: 480})
      ]

      repaired = Slicer.repair_slice_flags(notes, 960)

      assert [first, second, third] = repaired
      assert match?({:on_start, _}, first.slice_flag)
      assert second.slice_flag == {:on_start, "manual-start"}
      assert third.slice_flag == :on_end
    end
  end

  describe "slice/2" do
    test "builds slices from repaired flags" do
      notes = [
        Note.new(%{id: "n1", start_tick: 0, duration_tick: 480}),
        Note.new(%{id: "n2", start_tick: 480, duration_tick: 480}),
        Note.new(%{id: "n3", start_tick: 2160, duration_tick: 240})
      ]

      [first, second] = Slicer.slice(notes, 960)

      assert first.start_tick == 0
      assert first.end_tick == 960
      assert Enum.map(first.notes, & &1.id) == ["n1", "n2"]
      assert second.start_tick == 2160
      assert Enum.map(second.notes, & &1.id) == ["n3"]
    end
  end

  describe "materialize_segments/3" do
    test "creates offset segments and preserves slice ids" do
      notes = [
        Note.new(%{id: "n1", start_tick: 480, duration_tick: 240}),
        Note.new(%{id: "n2", start_tick: 720, duration_tick: 240}),
        Note.new(%{id: "n3", start_tick: 2160, duration_tick: 240})
      ]

      [first, second] = Slicer.materialize_segments("track-1", notes, min_rest_ticks: 960)

      assert first.track_id == "track-1"
      assert first.offset_tick == 480
      assert Enum.map(first.notes, & &1.start_tick) == [0, 240]
      assert is_binary(first.extra.slice_id)
      assert second.offset_tick == 2160
      assert Enum.map(second.notes, & &1.start_tick) == [0]
    end

    test "reuses provided segment ids by slice id" do
      notes = [
        Note.new(%{
          id: "n1",
          start_tick: 0,
          duration_tick: 480,
          slice_flag: {:on_start, "slice-a"}
        }),
        Note.new(%{id: "n2", start_tick: 480, duration_tick: 480, slice_flag: :on_end})
      ]

      [segment] =
        Slicer.materialize_segments("track-1", notes,
          min_rest_ticks: 960,
          segment_ids: %{"slice-a" => "segment-a"}
        )

      assert segment.id == "segment-a"
      assert segment.extra.slice_id == "slice-a"
    end
  end
end
