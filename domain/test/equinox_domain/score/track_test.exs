defmodule EquinoxDomain.Score.TrackTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Score.{SliceFlag, Track}
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  @tpqn 480

  setup do
    {:ok, track} =
      Track.new(
        id: ID.generate_id("Track_"),
        project_id: ID.generate_id("Project_"),
        name: "测试轨"
      )

    {:ok, key} = TwelveET.new(60)
    %{track: track, key: key}
  end

  defp insert(track, key, start_tick, duration \\ @tpqn, lyric \\ "a") do
    {:ok, track, note} =
      Track.insert_note(track,
        start_tick: start_tick,
        duration_tick: duration,
        key: key,
        lyric: lyric
      )

    {track, note}
  end

  defp active_seqs(track) do
    track |> Track.active_notes() |> Enum.map(fn {seq, _note} -> seq end)
  end

  defp active_starts(track) do
    track |> Track.active_notes() |> Enum.map(fn {_seq, note} -> note.start_tick end)
  end

  # 每个写操作后都应能切片——notes_by_seq 与 Timeline active 序同步
  defp assert_slice_ok(track) do
    case Track.slice(track) do
      {:ok, _segments} -> :ok
      {:error, reason} -> flunk("Track.slice/1 失败：#{inspect(reason)}")
    end
  end

  test "new/1 缺省初始化空 Timeline", %{track: track} do
    assert %Zongzi.Timeline{} = track.timeline
    assert Track.active_notes(track) == []
    assert_slice_ok(track)
  end

  describe "insert_note/2 定位" do
    test "按 start_tick 插入到头/中/尾", %{track: track, key: key} do
      {track, b} = insert(track, key, 960)
      {track, a} = insert(track, key, 0)
      {track, d} = insert(track, key, 2880)
      {track, c} = insert(track, key, 1920)

      assert active_starts(track) == [0, 960, 1920, 2880]
      assert active_seqs(track) == [a.seq_id, b.seq_id, c.seq_id, d.seq_id]
      assert_slice_ok(track)
    end

    test "同 start_tick 稳定插入到既有同 tick 音符之后", %{track: track, key: key} do
      {track, first} = insert(track, key, 480, @tpqn, "先")
      {track, second} = insert(track, key, 480, @tpqn, "后")

      assert first.seq_id != second.seq_id
      assert String.starts_with?(first.id, "Note_")

      assert Track.active_notes(track) |> Enum.map(fn {_seq, note} -> note.lyric end) ==
               ["先", "后"]

      assert_slice_ok(track)
    end
  end

  describe "delete_note/2" do
    test "删除并同步 notes_by_seq", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)

      {:ok, track} = Track.delete_note(track, a.seq_id)

      assert {:error, {:note_not_found, seq_a}} = Track.note(track, a.seq_id)
      assert seq_a == a.seq_id
      assert active_seqs(track) == [b.seq_id]
      assert_slice_ok(track)
    end

    test "seq 不存在报错", %{track: track, key: key} do
      {track, _a} = insert(track, key, 0)

      assert {:error, {:note_not_found, 999_999}} = Track.delete_note(track, 999_999)
      assert_slice_ok(track)
    end
  end

  describe "split_note/4" do
    test "before 保原 seq、after 新 seq，notes_by_seq 同步", %{track: track, key: key} do
      {track, a} = insert(track, key, 0, 960)

      {:ok, track, before_note, after_note} = Track.split_note(track, a.seq_id, 480)

      assert before_note.seq_id == a.seq_id
      assert after_note.seq_id != a.seq_id
      assert before_note.duration_tick == 480
      assert after_note.start_tick == 480
      assert after_note.duration_tick == 480

      assert {:ok, ^before_note} = Track.note(track, before_note.seq_id)
      assert {:ok, ^after_note} = Track.note(track, after_note.seq_id)
      assert map_size(track.notes_by_seq) == 2
      assert active_starts(track) == [0, 480]
      assert_slice_ok(track)
    end

    test "attrs 透传给后半音符", %{track: track, key: key} do
      {track, a} = insert(track, key, 0, 960)

      {:ok, track, _before_note, after_note} =
        Track.split_note(track, a.seq_id, 480, lyric: "啦")

      assert after_note.lyric == "啦"
      assert_slice_ok(track)
    end
  end

  describe "merge_notes/3" do
    test "merged 写回 seq_a、seq_b 消失", %{track: track, key: key} do
      {track, a} = insert(track, key, 0, 480, "你")
      {track, b} = insert(track, key, 480, 480, "好")

      {:ok, track, merged} = Track.merge_notes(track, a.seq_id, b.seq_id)

      assert merged.seq_id == a.seq_id
      assert merged.start_tick == 0
      assert merged.duration_tick == 960
      assert merged.lyric == "你好"

      assert {:ok, ^merged} = Track.note(track, a.seq_id)
      assert {:error, {:note_not_found, seq_b}} = Track.note(track, b.seq_id)
      assert seq_b == b.seq_id
      refute Map.has_key?(track.notes_by_seq, b.seq_id)
      assert active_seqs(track) == [a.seq_id]
      assert_slice_ok(track)
    end
  end

  describe "update_note/3" do
    test "拖拽跨邻居后重定位（seq 不变、链表序正确）", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {track, c} = insert(track, key, 1920)

      {:ok, track} = Track.update_note(track, a.seq_id, start_tick: 2400)

      assert {:ok, moved} = Track.note(track, a.seq_id)
      assert moved.start_tick == 2400
      assert moved.seq_id == a.seq_id
      assert active_seqs(track) == [b.seq_id, c.seq_id, a.seq_id]
      assert_slice_ok(track)
    end

    test "拖到中间位置", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {track, c} = insert(track, key, 1920)

      {:ok, track} = Track.update_note(track, c.seq_id, start_tick: 480)

      assert active_seqs(track) == [a.seq_id, c.seq_id, b.seq_id]
      assert_slice_ok(track)
    end

    test "位置已正确时不动链表", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)

      # 同 tick 更新：仍应保持在 b 之前
      {:ok, track} = Track.update_note(track, a.seq_id, start_tick: 0)

      assert active_seqs(track) == [a.seq_id, b.seq_id]
      assert_slice_ok(track)
    end

    test "不改 start_tick 时不重定位", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)

      {:ok, track} = Track.update_note(track, a.seq_id, lyric: "改")

      assert {:ok, note} = Track.note(track, a.seq_id)
      assert note.lyric == "改"
      assert active_seqs(track) == [a.seq_id, b.seq_id]
      assert_slice_ok(track)
    end

    test "seq 不存在报错", %{track: track} do
      assert {:error, {:note_not_found, 42}} = Track.update_note(track, 42, lyric: "x")
    end
  end

  describe "apply_slice_flag/3" do
    test "写入/读取往返", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)

      {:ok, track} = Track.apply_slice_flag(track, a.seq_id, :force_slice)
      {:ok, note} = Track.note(track, a.seq_id)
      assert SliceFlag.get(note) == :force_slice

      {:ok, track} = Track.apply_slice_flag(track, a.seq_id, :auto)
      {:ok, note} = Track.note(track, a.seq_id)
      assert SliceFlag.get(note) == :auto
      assert_slice_ok(track)
    end

    test "非法 flag 报错", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)

      assert {:error, {:invalid_slice_flag, :bad}} =
               Track.apply_slice_flag(track, a.seq_id, :bad)
    end
  end
end
