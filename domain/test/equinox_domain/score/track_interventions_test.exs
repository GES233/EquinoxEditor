defmodule EquinoxDomain.Score.TrackInterventionsTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias EquinoxDomain.Score.Track
  alias Zongzi.Intervention
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  @tpqn 480
  @projection %{"C" => [0.0, 0.05], "V" => [0.05, 0.10]}

  setup do
    {:ok, track} =
      Track.new(
        id: ID.generate_id("Track_"),
        project_id: ID.generate_id("Project_"),
        name: "干预轨"
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

  # 在 seq_id 上挂载一条 phoneme_timing 干预（range 初始值由调用方给）
  defp mount(track, seq_id, range) do
    {:ok, int} =
      Intervention.new(
        id: ID.generate_id("iv_"),
        channel: PhonemeTiming.channel(),
        declaration: PhonemeTiming
      )

    payload = %{
      range: range,
      deltas: [%{identity: "V", onset_delta_ms: 20, duration_delta_ms: 0}]
    }

    Track.mount_intervention(track, int, payload, seq_id, @projection)
  end

  describe "mount_intervention/5" do
    test "挂载成功：snapshot 已存、三元组锚派生正确、prepend 到 interventions",
         %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {track, c} = insert(track, key, 1920)

      assert {:ok, track, mounted} = mount(track, b.seq_id, [960, 1440])

      assert mounted.anchor == {a.seq_id, b.seq_id, c.seq_id}
      assert mounted.snapshot == %{"V" => [0.05, 0.10]}
      assert mounted.payload.range == [960, 1440]
      assert track.interventions == [mounted]
    end

    test "首尾音符的锚 nil 侧正确", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)

      assert {:ok, _track, mounted} = mount(track, a.seq_id, [0, 480])
      assert mounted.anchor == {nil, a.seq_id, nil}
    end

    test "死 seq（不存在/已删）报 {:error, :not_active}", %{track: track, key: key} do
      {track, a} = insert(track, key, 0)
      {:ok, track} = Track.delete_note(track, a.seq_id)

      assert {:error, :not_active} = mount(track, a.seq_id, [0, 480])
      assert {:error, :not_active} = mount(track, 999_999, [0, 480])
    end
  end

  describe "rebase_interventions/1" do
    test "被锚音符删除后：干预进 conflicts 且从 track.interventions 移除",
         %{track: track, key: key} do
      {track, _a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {:ok, track, mounted} = mount(track, b.seq_id, [960, 1440])

      {:ok, track} = Track.delete_note(track, b.seq_id)
      assert {:ok, track, report} = Track.rebase_interventions(track)

      assert track.interventions == []
      assert [{conflicted, :relocate_forbidden}] = report.conflicts
      assert conflicted.id == mounted.id
      assert report.decisions[mounted.id] == :conflict
    end

    test "被锚音符拖拽后：干预 survived 且 payload.range 被 on_rebase 刷新",
         %{track: track, key: key} do
      {track, _a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {track, _c} = insert(track, key, 1920)
      {:ok, track, mounted} = mount(track, b.seq_id, [960, 1440])

      # 拖到 1200（仍在两邻之间，三元组 3/3 匹配 → preserve）
      {:ok, track} = Track.update_note(track, b.seq_id, start_tick: 1200)
      assert {:ok, track, report} = Track.rebase_interventions(track)

      assert report.conflicts == []
      assert report.decisions[mounted.id] == :preserve

      assert [survived] = track.interventions
      assert survived.id == mounted.id
      assert survived.payload.range == [1200, 1680]
      # snapshot 由 declaration 管，结构 rebase 不动它
      assert survived.snapshot == mounted.snapshot
    end

    test "空 interventions 时返回空报告", %{track: track} do
      assert {:ok, ^track, %{conflicts: [], decisions: %{}}} =
               Track.rebase_interventions(track)
    end
  end
end
