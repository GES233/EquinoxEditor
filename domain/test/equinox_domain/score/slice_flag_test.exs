defmodule EquinoxDomain.Score.SliceFlagTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Score.SliceFlag
  alias Zongzi.Score.{Key.TwelveET, Note}
  alias Zongzi.Util.ID

  defp new_note(metadata \\ %{}) do
    {:ok, key} = TwelveET.new(60)

    {:ok, note} =
      Note.new(%{
        id: ID.generate_id("Note_"),
        start_tick: 0,
        duration_tick: 480,
        key: key,
        lyric: "a",
        metadata: metadata
      })

    note
  end

  test "get/1：metadata 缺省或读不到该键时均为 :auto" do
    assert SliceFlag.get(new_note()) == :auto
    assert SliceFlag.get(new_note(%{"other" => 1})) == :auto
  end

  test "get/1 容忍原子与字符串两种写法，未知值按 :auto" do
    for {stored, expected} <- [
          {"force_slice", :force_slice},
          {:force_slice, :force_slice},
          {"force_merge", :force_merge},
          {:force_merge, :force_merge},
          {"auto", :auto},
          {"unknown", :auto},
          {42, :auto}
        ] do
      assert SliceFlag.get(new_note(%{"slice_flag" => stored})) == expected
    end
  end

  test "set/2 写入字符串形式并可 get 往返" do
    note = new_note()

    {:ok, note} = SliceFlag.set(note, :force_slice)
    assert note.metadata["slice_flag"] == "force_slice"
    assert SliceFlag.get(note) == :force_slice

    {:ok, note} = SliceFlag.set(note, :force_merge)
    assert note.metadata["slice_flag"] == "force_merge"
    assert SliceFlag.get(note) == :force_merge
  end

  test "set/2 :auto 从 metadata 删除该键" do
    {:ok, note} = SliceFlag.set(new_note(), :force_slice)
    assert Map.has_key?(note.metadata, "slice_flag")

    {:ok, note} = SliceFlag.set(note, :auto)
    refute Map.has_key?(note.metadata, "slice_flag")
    assert SliceFlag.get(note) == :auto
  end

  test "set/2 非法 flag 报错" do
    assert {:error, {:invalid_slice_flag, :bogus}} = SliceFlag.set(new_note(), :bogus)
  end
end
