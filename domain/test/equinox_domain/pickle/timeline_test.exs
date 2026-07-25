defmodule EquinoxDomain.Pickle.TimelineTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Pickle
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Score.Note
  alias Zongzi.Timeline

  # 建一条含墓碑的 Timeline：插 3 个音符，删中间一个
  setup do
    {:ok, timeline} = Timeline.new("Track_t1")
    {:ok, key} = TwelveET.new(60)

    {seqs, timeline} =
      [0, 960, 1920]
      |> Enum.map_reduce(timeline, fn start_tick, tl ->
        {:ok, note} =
          Note.new(%{
            id: "Note_#{start_tick}",
            start_tick: start_tick,
            duration_tick: 480,
            key: key
          })

        {:ok, tl, note} = Timeline.insert_note(tl, note)
        {note.seq_id, tl}
      end)

    [_a, b, _c] = seqs
    {:ok, timeline} = Timeline.delete_note(timeline, b)

    %{timeline: timeline}
  end

  test "dump 形状：note_order / seq_map / tombstones / next_seq，不含 track_id",
       %{timeline: timeline} do
    assert {:ok, dump} = Pickle.Timeline.dump(timeline)
    assert_plain!(dump)

    assert dump.note_order == [1, 2, 3]
    assert dump.seq_map == %{1 => "Note_0", 3 => "Note_1920"}
    assert dump.tombstones == [2]
    assert dump.next_seq == 4
    refute Map.has_key?(dump, :track_id)
  end

  test "load(dump, track_id) 全字段结构相等（nodes/seq_map/tombstones/next_seq/track_id）",
       %{timeline: timeline} do
    assert {:ok, dump} = Pickle.Timeline.dump(timeline)
    assert {:ok, loaded} = Pickle.Timeline.load(dump, timeline.track_id)

    assert loaded == timeline
  end

  test "track_id 由宿主注入，不取自 dump", %{timeline: timeline} do
    assert {:ok, dump} = Pickle.Timeline.dump(timeline)
    assert {:ok, loaded} = Pickle.Timeline.load(dump, "Track_other")

    assert loaded.track_id == "Track_other"
    # 其余结构不变
    assert loaded.nodes == timeline.nodes
    assert loaded.seq_map == timeline.seq_map
    assert loaded.tombstones == timeline.tombstones
  end

  test "空 Timeline round-trip" do
    {:ok, timeline} = Timeline.new("Track_empty")

    assert {:ok, dump} = Pickle.Timeline.dump(timeline)
    assert_plain!(dump)
    assert {:ok, loaded} = Pickle.Timeline.load(dump, "Track_empty")
    assert loaded == timeline
  end
end
