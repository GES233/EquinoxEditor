defmodule EquinoxDomain.Score.SliceFlagTest do
  use ExUnit.Case, async: true

  alias Coconut.Score.Note
  alias EquinoxDomain.Score.SliceFlag

  defp note!(metadata) do
    {:ok, note} = Note.new(%{id: "Note_t1", metadata: metadata})
    note
  end

  describe "get/1" do
    test "缺省（无 metadata 键）为 :auto" do
      assert SliceFlag.get(note!(%{})) == :auto
    end

    test "读取字符串形式" do
      assert SliceFlag.get(note!(%{"slice_flag" => "force_slice"})) == :force_slice
      assert SliceFlag.get(note!(%{"slice_flag" => "force_merge"})) == :force_merge
    end

    test "容忍原子形式" do
      assert SliceFlag.get(note!(%{"slice_flag" => :force_slice})) == :force_slice
    end

    test "未知值按 :auto" do
      assert SliceFlag.get(note!(%{"slice_flag" => "bogus"})) == :auto
    end
  end

  describe "set/2" do
    test "写入字符串形式" do
      {:ok, note} = SliceFlag.set(note!(%{}), :force_slice)
      assert note.metadata == %{"slice_flag" => "force_slice"}
      assert SliceFlag.get(note) == :force_slice
    end

    test ":auto 删除该键" do
      {:ok, note} = SliceFlag.set(note!(%{"slice_flag" => "force_merge", "keep" => 1}), :auto)
      assert note.metadata == %{"keep" => 1}
    end

    test "非法 flag 报错" do
      assert {:error, {:invalid_slice_flag, :bogus}} = SliceFlag.set(note!(%{}), :bogus)
    end

    test "set → get 往返" do
      for flag <- [:force_slice, :force_merge, :auto] do
        {:ok, note} = SliceFlag.set(note!(%{}), flag)
        assert SliceFlag.get(note) == flag
      end
    end
  end
end
