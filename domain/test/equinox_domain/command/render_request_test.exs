defmodule EquinoxDomain.Command.RenderRequestTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias EquinoxDomain.Score.Track
  alias Zongzi.{Intervention, Windowing.Segment}
  alias Zongzi.Score.{Key.TwelveET, Tempo, TempoMap}
  alias Zongzi.Util.ID

  @tpqn 480

  setup do
    {:ok, track} =
      Track.new(
        id: ID.generate_id("Track_"),
        project_id: ID.generate_id("Project_"),
        name: "渲染轨"
      )

    {:ok, key} = TwelveET.new(60)

    {:ok, tempo_map} =
      TempoMap.compile([{0, %Tempo.Event{module: Tempo.Step, context: %{bpm: 120}}}], tpqn: @tpqn)

    %{track: track, key: key, tempo_map: tempo_map}
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

  defp mount(track, seq_id, range) do
    {:ok, int} =
      Intervention.new(
        id: ID.generate_id("iv_"),
        channel: PhonemeTiming.channel(),
        declaration: PhonemeTiming
      )

    payload = %{range: range, deltas: []}

    {:ok, track, mounted} = Track.mount_intervention(track, int, payload, seq_id, %{})
    {track, mounted}
  end

  defp window(start_tick, end_tick, seq_ids) do
    {:ok, segment} = Segment.new(start_tick, end_tick, seq_ids)
    segment
  end

  describe "from_window/3 notes 与 tempo_segments 行为不变" do
    test "按 seq_ids 取回 Note 本体、切片 tempo_segments", %{
      track: track,
      key: key,
      tempo_map: tempo_map
    } do
      {track, a} = insert(track, key, 0)
      {track, _b} = insert(track, key, 960)

      segment = window(0, 960, [a.seq_id])
      assert {:ok, req} = RenderRequest.from_window(segment, track, tempo_map)

      assert req.track_id == track.id
      assert req.note_ids == [a.id]
      assert req.notes == [a]
      assert req.time_range == {0, 960}
      assert [%{start_pos: 0, start_sec: start_sec}] = req.tempo_segments
      assert start_sec == 0.0
      assert req.interventions == []
      assert req.declarations == %{}
    end

    test "seq 缺 Note 本体时报 note_not_found", %{track: track, tempo_map: tempo_map} do
      segment = window(0, 960, [42_424])

      assert {:error, {:note_not_found, 42_424}} =
               RenderRequest.from_window(segment, track, tempo_map)
    end
  end

  describe "from_window/3 interventions 过滤" do
    test "scope 与窗口区间（左闭右开）相交才纳入，declarations 随之派生", %{
      track: track,
      key: key,
      tempo_map: tempo_map
    } do
      {track, a} = insert(track, key, 0)
      {track, b} = insert(track, key, 960)
      {track, int_a} = mount(track, a.seq_id, [0, 480])
      {track, int_b} = mount(track, b.seq_id, [960, 1440])

      # 窗口 A [0, 960)：int_a 相交，int_b 起点贴右边界被排除
      segment_a = window(0, 960, [a.seq_id])
      assert {:ok, req_a} = RenderRequest.from_window(segment_a, track, tempo_map)
      assert Enum.map(req_a.interventions, & &1.id) == [int_a.id]
      assert req_a.declarations == %{phoneme_timing: PhonemeTiming}

      # 窗口 B [480, 1440)：int_a 终点贴左边界被排除，int_b 相交
      segment_b = window(480, 1440, [b.seq_id])
      assert {:ok, req_b} = RenderRequest.from_window(segment_b, track, tempo_map)
      assert Enum.map(req_b.interventions, & &1.id) == [int_b.id]

      # 窗口 C [0, 1920)：两者都纳入
      segment_c = window(0, 1920, [a.seq_id, b.seq_id])
      assert {:ok, req_c} = RenderRequest.from_window(segment_c, track, tempo_map)
      assert Enum.map(req_c.interventions, & &1.id) == [int_b.id, int_a.id]
      assert req_c.declarations == %{phoneme_timing: PhonemeTiming}
    end
  end
end
