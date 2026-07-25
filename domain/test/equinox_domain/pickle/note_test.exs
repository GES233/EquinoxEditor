defmodule EquinoxDomain.Pickle.NoteTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Pickle
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Score.Note

  defp note(overrides \\ %{}) do
    {:ok, key} = TwelveET.new(60)

    attrs =
      Map.merge(
        %{
          id: "Note_x",
          start_tick: 480,
          duration_tick: 240,
          key: key,
          lyric: "啦",
          seq_id: 3,
          annotation: "注",
          metadata: %{"slice_flag" => "force_slice"}
        },
        overrides
      )

    {:ok, note} = Note.new(attrs)
    note
  end

  test "dump/load round-trip 结构相等且产物 plain" do
    note = note()

    assert {:ok, dump} = Pickle.Note.dump(note)
    assert_plain!(dump)

    assert dump == %{
             id: "Note_x",
             start_tick: 480,
             duration_tick: 240,
             key: %{module: TwelveET, midi: 60.0},
             lyric: "啦",
             seq_id: 3,
             annotation: "注",
             metadata: %{"slice_flag" => "force_slice"}
           }

    assert {:ok, loaded} = Pickle.Note.load(dump)
    assert loaded == note
  end

  test "nil 字段（lyric/annotation/seq_id）round-trip 保留 nil" do
    note = note(%{lyric: nil, annotation: nil, seq_id: nil, metadata: %{}})

    assert {:ok, dump} = Pickle.Note.dump(note)
    assert_plain!(dump)
    assert {:ok, loaded} = Pickle.Note.load(dump)
    assert loaded == note
  end

  test "load 未知 key module 包装为 error tuple 而非 raise" do
    dump = %{
      id: "Note_x",
      start_tick: 0,
      duration_tick: 480,
      key: %{module: This.Module.Does.Not.Exist, midi: 60},
      lyric: nil,
      seq_id: nil,
      annotation: nil,
      metadata: %{}
    }

    assert {:error, {:key_from_midi_failed, _}} = Pickle.Note.load(dump)
  end

  test "load 非法字段经 Note.new/1 校验报错" do
    note = note()
    assert {:ok, dump} = Pickle.Note.dump(note)

    assert {:error, {:invalid_negative_tick, -1}} =
             Pickle.Note.load(%{dump | start_tick: -1})
  end
end
