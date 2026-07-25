defmodule EquinoxDomain.Score.SlicePolicyTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Score.Track
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  @tpqn 480
  # 3 拍休止阈值（RestSplit3Beats：gap < 3 拍粘连，>= 3 拍切开）
  @rest_3_beats 3 * @tpqn

  setup do
    {:ok, track} =
      Track.new(
        id: ID.generate_id("Track_"),
        project_id: ID.generate_id("Project_"),
        name: "切片策略测试轨"
      )

    {:ok, key} = TwelveET.new(60)
    %{track: track, key: key}
  end

  defp insert(track, key, start_tick, duration \\ @tpqn) do
    {:ok, track, note} =
      Track.insert_note(track,
        start_tick: start_tick,
        duration_tick: duration,
        key: key,
        lyric: "a"
      )

    {track, note}
  end

  defp slice_segments(track) do
    {:ok, segments} = Track.slice(track)
    Enum.map(segments, fn seg -> {seg.start_tick, seg.end_tick, seg.seq_ids} end)
  end

  test "空轨道切出空列表", %{track: track} do
    assert slice_segments(track) == []
  end

  test "auto：小间隙粘连为一窗", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    # 间隙 1 拍 < 3 拍阈值
    {track, b} = insert(track, key, @tpqn * 2)

    assert slice_segments(track) == [{0, @tpqn * 3, [a.seq_id, b.seq_id]}]
  end

  test "auto：≥3 拍休止切开，1 拍归前片 2 拍归后片", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    # A 结束于 480；休止恰为 3 拍 → B 起于 480 + 1440
    b_start = @tpqn + @rest_3_beats
    {track, b} = insert(track, key, b_start)

    assert slice_segments(track) == [
             {0, @tpqn * 2, [a.seq_id]},
             {b_start - @tpqn * 2, b_start + @tpqn, [b.seq_id]}
           ]
  end

  test "force_slice：小间隙也强切", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    {track, b} = insert(track, key, @tpqn)
    {:ok, track} = Track.apply_slice_flag(track, b.seq_id, :force_slice)

    assert slice_segments(track) == [
             {0, @tpqn, [a.seq_id]},
             {@tpqn, @tpqn * 2, [b.seq_id]}
           ]
  end

  test "force_merge：跨 ≥3 拍休止也禁切", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    b_start = @tpqn + @rest_3_beats
    {track, b} = insert(track, key, b_start)
    {:ok, track} = Track.apply_slice_flag(track, b.seq_id, :force_merge)

    assert slice_segments(track) == [
             {0, b_start + @tpqn, [a.seq_id, b.seq_id]}
           ]
  end

  test "force_slice：片内非首位置切开", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    {track, b} = insert(track, key, @tpqn)
    {track, c} = insert(track, key, @tpqn * 2)
    {:ok, track} = Track.apply_slice_flag(track, c.seq_id, :force_slice)

    assert slice_segments(track) == [
             {0, @tpqn * 2, [a.seq_id, b.seq_id]},
             {@tpqn * 2, @tpqn * 3, [c.seq_id]}
           ]
  end

  test "单一 force_slice 音符独立成窗（前后都有边界时）", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    {track, b} = insert(track, key, @tpqn)
    {track, c} = insert(track, key, @tpqn * 2)
    {:ok, track} = Track.apply_slice_flag(track, b.seq_id, :force_slice)
    {:ok, track} = Track.apply_slice_flag(track, c.seq_id, :force_slice)

    assert slice_segments(track) == [
             {0, @tpqn, [a.seq_id]},
             {@tpqn, @tpqn * 2, [b.seq_id]},
             {@tpqn * 2, @tpqn * 3, [c.seq_id]}
           ]
  end

  test "force_merge 链式合并三片", %{track: track, key: key} do
    {track, a} = insert(track, key, 0)
    b_start = @tpqn + @rest_3_beats
    {track, b} = insert(track, key, b_start)
    c_start = b_start + @tpqn + @rest_3_beats
    {track, c} = insert(track, key, c_start)
    {:ok, track} = Track.apply_slice_flag(track, b.seq_id, :force_merge)
    {:ok, track} = Track.apply_slice_flag(track, c.seq_id, :force_merge)

    assert slice_segments(track) == [
             {0, c_start + @tpqn, [a.seq_id, b.seq_id, c.seq_id]}
           ]
  end
end
