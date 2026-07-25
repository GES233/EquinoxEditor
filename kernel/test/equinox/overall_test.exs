defmodule Equinox.OverallTest do
  use ExUnit.Case, async: false

  alias Equinox.Kernel.{Blackboard, Graph, StepRegistry}
  alias Equinox.Session
  alias Equinox.Session.Server
  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Score.Key.TwelveET
  alias Zongzi.Util.ID

  test "overall kernel flow covers registry, server editing APIs, and session lifecycle" do
    assert {:ok, phonemizer_spec} = StepRegistry.lookup(:phonemizer)
    assert phonemizer_spec.inputs == [:notes]

    # domain 夹具：工程 + 一轨 + 一个音符（全部经 domain API 构造）
    {:ok, project} = Project.new(id: ID.generate_id("Project_"), name: "Overall Flow")
    {:ok, track} = Track.new(id: ID.generate_id("Track_"), name: "Lead")

    {:ok, track, _note} =
      Track.insert_note(track, %{
        start_tick: 0,
        duration_tick: 480,
        key: twelve_et(60),
        lyric: "la"
      })

    {:ok, project} = Project.add_track(project, track)
    track_id = track.id

    session_id = "overall-session"
    assert {:error, :session_not_found} = Session.resolve(session_id)

    server_pid =
      start_supervised!(
        Server.child_spec(
          session_id: session_id,
          name: Session.server(session_id),
          project: project
        )
      )

    server = Session.server(session_id)

    assert {:ok, server_pid_from_registry} = Session.resolve(session_id)
    assert is_pid(server_pid_from_registry)
    assert {:ok, _oi_pid} = Oi.Runtime.Session.resolve(session_id)

    # ---- get_view：初始视图 ----
    view = Server.get_view(server)
    assert view.project.name == "Overall Flow"
    assert view.graphs == %{}
    assert {:ok, _track} = Project.get_track(view.project, track_id)

    # ---- add_track：缺 :id 自动补；project_id 对齐；重复 id 报错 ----
    assert {:ok, added} = Server.add_track(server, %{name: "Backing"})
    assert is_binary(added.id)
    assert added.project_id == view.project.id
    assert added.name == "Backing"

    assert {:error, {:already_exists, _}} = Server.add_track(server, %{id: added.id})

    # ---- replace_window_notes：对既有 window（start 0）整体替换 ----
    assert {:ok, updated} =
             Server.replace_window_notes(server, track_id, 0, [
               %{start_tick: 0, duration_tick: 240, key: twelve_et(60), lyric: "la"},
               %{start_tick: 240, duration_tick: 480, key: twelve_et(62), lyric: "ha"}
             ])

    active = Track.active_notes(updated)
    assert length(active) == 2
    assert Enum.any?(active, fn {_seq, note} -> note.lyric == "ha" end)

    # 窗口不存在 → 显式报错
    assert {:error, {:window_not_found, 9999}} =
             Server.replace_window_notes(server, track_id, 9999, [])

    # ---- update_track_mix：只取混音字段 ----
    assert {:ok, mixed} =
             Server.update_track_mix(server, track_id, gain: 0.75, pan: -0.2, bogus: 1)

    assert mixed.gain == 0.75
    assert mixed.pan == -0.2

    # ---- update_track_ui_state：写入 metadata["ui_state"] ----
    assert {:ok, ui} = Server.update_track_ui_state(server, track_id, :focused_window, 0)
    assert ui.metadata["ui_state"] == %{focused_window: 0}

    assert {:ok, ui} = Server.update_track_ui_state(server, track_id, :zoom, 1.5)
    assert ui.metadata["ui_state"] == %{focused_window: 0, zoom: 1.5}

    # ---- update_synth_graph：写入 Session 侧 graphs ----
    graph = Graph.new()
    assert :ok = Server.update_synth_graph(server, track_id, graph)

    assert {:error, {:track_not_found, _}} =
             Server.update_synth_graph(server, "Track_missing", graph)

    # ---- remove_track：连带清 graphs；重复移除报错 ----
    assert :ok = Server.update_synth_graph(server, added.id, graph)
    assert :ok = Server.remove_track(server, added.id)
    assert {:error, {:track_not_found, _}} = Server.remove_track(server, added.id)

    # ---- get_view：汇总断言 ----
    view = Server.get_view(server)
    assert view.graphs == %{track_id => graph}
    assert {:ok, stored} = Project.get_track(view.project, track_id)
    assert stored.gain == 0.75
    assert stored.pan == -0.2
    assert stored.metadata["ui_state"] == %{focused_window: 0, zoom: 1.5}
    assert length(Track.active_notes(stored)) == 2

    # ---- dispatch 冒烟：cast 驱动完整编译-渲染链路 ----
    # 异步调度，空 Graph 可能瞬间完成 —— 不等中间态，直接校验最终结果
    assert :ok = Server.dispatch(server, [])

    # 等渲染任务收尾：黑板合并、render_tasks 清空、编译缓存按轨填充
    Process.sleep(300)
    state = :sys.get_state(server)
    assert state.render_tasks == nil
    assert %Blackboard{} = state.blackboard
    assert {%Graph{}, %Oi.Compiled{}} = state.compile_cache[track_id]

    # ---- 生命周期：重复启动与停止 ----
    assert {:error, {:already_started, _pid}} =
             Server.start_link(
               session_id: session_id,
               name: Session.server(session_id)
             )

    assert :ok = GenServer.stop(server_pid)
    # 这个断言偶尔会因为编译缓存的关系报错
    assert {:error, :session_not_found} = Session.resolve(session_id)
    assert {:error, :session_not_found} = Oi.Runtime.Session.resolve(session_id)
  end

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end
end
