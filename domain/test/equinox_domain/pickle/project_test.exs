defmodule EquinoxDomain.Pickle.ProjectTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Score.{Tempo, TempoMap, TimeSigMap}
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Score.Tempo.Event

  @tpqn 480

  # tempo 源事件（Step + Linear；Linear 要求有限 end_tick，故用 {events, last} 形态）
  @tempo_events [
    {0, %Event{module: Tempo.Step, context: %{bpm: 120}}},
    {960, %Event{module: Tempo.Linear, context: %{bpm_start: 120, bpm_end: 60}}}
  ]

  # 拍号源事件（standard / compound / san 各一）
  @time_sig_events [
    {1, {:standard, 4, 4}},
    {3, {:compound, [2, 3], 8}},
    {5, :san}
  ]

  setup do
    {:ok, track} = Track.new(id: "Track_t1", project_id: "Project_p1", name: "主唱")
    {:ok, key} = TwelveET.new(60)

    {:ok, track, _note} =
      Track.insert_note(track, start_tick: 0, duration_tick: @tpqn, key: key, lyric: "a")

    {:ok, project} =
      Project.new(
        id: "Project_p1",
        name: "demo",
        tempo_map: {@tempo_events, 1920},
        time_sig_map: @time_sig_events,
        tracks: %{"Track_t1" => track},
        metadata: %{"author" => "qy"}
      )

    %{project: project}
  end

  test "dump 产物 plain 且带 version", %{project: project} do
    assert {:ok, dump} = Project.dump(project)
    assert_plain!(dump)

    assert dump.version == 1
    assert dump.id == "Project_p1"
    # {events, last_tick} 形态编成 map
    assert %{events: [[0, _], [960, _]], last_tick: 1920} = dump.tempo_events
    # 拍号 sig 已归一化
    assert %{events: [[1, ["standard", 4, 4]], [3, ["compound", [2, 3], 8]], [5, "san"]]} =
             dump.time_sig_events

    assert Map.has_key?(dump.tracks, "Track_t1")
  end

  test "load(dump(project)) 结构全等（含 tracks）", %{project: project} do
    assert {:ok, dump} = Project.dump(project)
    assert {:ok, loaded} = Project.load(dump)

    assert loaded == project
  end

  test "round-trip 后编译态投影一致且换算结果相同", %{project: project} do
    assert {:ok, dump} = Project.dump(project)
    assert {:ok, loaded} = Project.load(dump)

    # tempo：编译成功且与原编译一致
    assert {:ok, tempo_map} = Project.compiled_tempo_map(loaded, tpqn: @tpqn)
    assert {:ok, ^tempo_map} = Project.compiled_tempo_map(project, tpqn: @tpqn)

    # tick → sec 换算一致（Step 区 120bpm：480 tick = 0.5s）
    assert TempoMap.tick_to_sec(tempo_map, 480, @tpqn) == 0.5

    # 拍号：编译成功且与原编译一致
    assert {:ok, time_sig_map} = Project.compiled_time_sig_map(loaded, tpqn: @tpqn)
    assert {:ok, ^time_sig_map} = Project.compiled_time_sig_map(project, tpqn: @tpqn)

    # bar → tick 换算一致（4/4、tpqn 480：第 2 小节起于 1920 tick）
    assert TimeSigMap.bar_to_tick(time_sig_map, 2, @tpqn) == {:ok, 1920}
  end

  test "空 Project（默认 [] 源事件）round-trip；编译报 empty 由调用方处理" do
    {:ok, project} = Project.new(id: "Project_empty", name: "空")

    assert {:ok, dump} = Project.dump(project)
    assert_plain!(dump)
    assert {:ok, loaded} = Project.load(dump)
    assert loaded == project

    assert {:error, :empty_tempo_events} = Project.compiled_tempo_map(loaded)
    assert {:error, :empty_time_sig_events} = Project.compiled_time_sig_map(loaded)
  end

  test "load 损坏的 track dump 向上返回 error", %{project: project} do
    assert {:ok, dump} = Project.dump(project)

    # Track 的标量字段无校验，从 notes_by_seq 里造一个非法 note 触发子 codec error
    bad = put_in(dump.tracks["Track_t1"].notes_by_seq[1].start_tick, -1)

    assert {:error, {:invalid_negative_tick, -1}} = Project.load(bad)
  end
end
