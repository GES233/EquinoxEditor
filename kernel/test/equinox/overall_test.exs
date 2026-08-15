defmodule Equinox.OverallTest do
  use ExUnit.Case, async: false

  alias Coconut.Edit.{History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Coconut.Util.ID
  alias Equinox.Kernel.{Blackboard, Graph, StepRegistry}
  alias Equinox.Session
  alias Equinox.Session.Server
  alias EquinoxDomain.Port.Channels.PhonemeTiming
  alias EquinoxDomain.Score.{Project, Track}

  test "overall kernel flow covers registry, server editing APIs, and session lifecycle" do
    assert {:ok, phonemizer_spec} = StepRegistry.lookup(:phonemizer)
    assert phonemizer_spec.inputs == [:notes]

    # domain 夹具：工程（tempo 轨带 120bpm 事件）+ 一轨 + 一个音符
    # （结构写经 coconut History/Operations，与 kernel 写路径同源）
    project = build_project("Overall Flow")
    {:ok, project, _track} = Project.add_track(project, id: ID.generate_id("Track_"))
    [track_id] = Map.keys(project.tracks_meta)

    {:ok, project} =
      insert_notes(project, [
        {track_id, ID.generate_id("Note_"), :head, {0, 480}, %{pitch: twelve_et(60), lyric: "la"}}
      ])

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
    assert view.project.metadata.name == "Overall Flow"
    assert view.graphs == %{}
    assert {:ok, _track} = Project.fetch_track(view.project, track_id)

    # ---- add_track：缺 :id 自动补；重复 id 报错 ----
    assert {:ok, added} = Server.add_track(server, %{name: "Backing"})
    assert is_binary(added.id)
    assert added.name == "Backing"

    assert {:error, {:track_id_taken, _}} = Server.add_track(server, %{id: added.id})

    # ---- add_track：`:type` 映射 coconut 轨型，缺省 Vocal；混音键进侧表 ----
    assert added.module == Coconut.Edit.Track.Vocal

    assert {:ok, audio} =
             Server.add_track(server, %{type: :external_audio, name: "FX", gain: 0.5})

    assert audio.module == Coconut.Edit.Track.Audio
    assert audio.name == "FX"

    assert {:ok, audio_meta} = Project.track_meta(Server.get_view(server).project, audio.id)
    assert audio_meta.gain == 0.5

    # 字符串形 type 同样映射
    assert {:ok, audio2} = Server.add_track(server, %{"type" => "external_audio"})
    assert audio2.module == Coconut.Edit.Track.Audio

    # 清掉音频轨，保持后续断言的状态整洁
    assert :ok = Server.remove_track(server, audio.id)
    assert :ok = Server.remove_track(server, audio2.id)

    # ---- replace_window_notes：对既有 window（start 0）整体替换 ----
    assert {:ok, updated} =
             Server.replace_window_notes(server, track_id, 0, [
               %{start_tick: 0, duration_tick: 240, key: twelve_et(60), lyric: "la"},
               %{start_tick: 240, duration_tick: 480, key: twelve_et(62), lyric: "ha"}
             ])

    assert length(Coconut.Edit.Track.view(updated)) == 2

    # 窗口不存在 → 显式报错
    assert {:error, {:window_not_found, 9999}} =
             Server.replace_window_notes(server, track_id, 9999, [])

    # ---- update_track_mix：只取混音字段（侧表写） ----
    assert {:ok, mixed} =
             Server.update_track_mix(server, track_id, gain: 0.75, pan: -0.2, bogus: 1)

    assert mixed.gain == 0.75
    assert mixed.pan == -0.2

    # ---- update_track_ui_state：写入 TrackMeta.ui_state（侧表写） ----
    assert {:ok, ui} = Server.update_track_ui_state(server, track_id, :focused_window, 0)
    assert ui.ui_state == %{focused_window: 0}

    assert {:ok, ui} = Server.update_track_ui_state(server, track_id, :zoom, 1.5)
    assert ui.ui_state == %{focused_window: 0, zoom: 1.5}

    # ---- update_synth_graph：写入 Session 侧 graphs ----
    graph = Graph.new()
    assert :ok = Server.update_synth_graph(server, track_id, graph)

    assert {:error, {:unknown_track, _}} =
             Server.update_synth_graph(server, "Track_missing", graph)

    # ---- remove_track：连带清 graphs 与侧表；重复移除报错 ----
    assert :ok = Server.update_synth_graph(server, added.id, graph)
    assert :ok = Server.remove_track(server, added.id)
    assert {:error, {:unknown_track, _}} = Server.remove_track(server, added.id)

    # ---- get_view：汇总断言 ----
    view = Server.get_view(server)
    assert view.graphs == %{track_id => graph}
    assert {:ok, stored_meta} = Project.track_meta(view.project, track_id)
    assert stored_meta.gain == 0.75
    assert stored_meta.pan == -0.2
    assert stored_meta.ui_state == %{focused_window: 0, zoom: 1.5}
    assert {:ok, notes} = Track.notes(view.project, track_id)
    assert length(notes) == 2
    assert Enum.any?(notes, fn {_id, note, _span} -> note.lyric == "ha" end)

    # ---- adopt_intervention：采纳引擎产出为轨道 patch ----
    [{first_id, _first_note, _span} | _] = notes

    payload = %{
      deltas: [%{identity: "ph_a", onset_delta_ms: 10, duration_delta_ms: 20}]
    }

    assert {:ok, adopted_track, patch} =
             Server.adopt_intervention(
               server,
               track_id,
               channel: PhonemeTiming,
               seq_id: first_id,
               payload: payload
             )

    assert [^patch] = adopted_track.patches
    assert String.starts_with?(patch.id, "Patch_")
    assert patch.channel == PhonemeTiming.channel()
    assert patch.patch.payload == payload
    assert is_binary(patch.patch.base_digest)

    # Server 状态里的 track 也已写入同一条 patch
    assert {:ok, stored} = Project.fetch_track(Server.get_view(server).project, track_id)
    assert [^patch] = stored.patches

    # seq_id 非存活音符 → 投影失败显式报错
    assert {:error, {:note_not_found, _}} =
             Server.adopt_intervention(
               server,
               track_id,
               channel: PhonemeTiming,
               seq_id: "Note_missing",
               payload: %{deltas: []}
             )

    # ---- dispatch 冒烟：cast 驱动完整编译-渲染链路 ----
    # 轨上有一条 patch 但未注入 channel spec → check 阶段一票否决（渲染任务
    # 报错收尾，黑板不被污染）；本断言只关心任务收尾与编译缓存
    assert :ok = Server.dispatch(server, [])

    # 等渲染任务收尾：render_tasks 清空、编译缓存按轨填充
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
    # Registry 的注销经 monitor DOWN 异步生效（GenServer.stop 只保证进程死亡），
    # 轮询等条目摘除；Oi 会话在 terminate/2 里同步销毁，直接断言即可
    assert_eventually(fn -> Session.resolve(session_id) == {:error, :session_not_found} end)
    assert {:error, :session_not_found} = Oi.Runtime.Session.resolve(session_id)
  end

  # 异步条件的轮询断言（Registry 注销等 monitor DOWN 驱动的清理；
  # 全套件负载下（MCP 子进程测试拖慢调度）摘除可能较慢，预算放宽到 5s）
  defp assert_eventually(fun, retries \\ 500)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, retries) do
    unless fun.() do
      Process.sleep(10)
      assert_eventually(fun, retries - 1)
    end
  end

  # 工程夹具：tempo 轨一个 120bpm 事件（经 History + InsertNote 写入）
  defp build_project(name) do
    {:ok, project} = Project.new(id: ID.generate_id("Project_"), metadata: %{name: name})

    {:ok, project} =
      insert_notes(project, [
        {"global:tempo", ID.generate_id("Tempo_"), :head, {0, 480}, %{bpm: 120}}
      ])

    project
  end

  # 经 coconut History 批量插入元素（InsertNote 手势逐条 apply），
  # 返回 workspace 已推进的 project
  defp insert_notes(%Project{} = project, inserts) do
    hist = History.new(project.workspace)

    Enum.reduce_while(inserts, {:ok, hist}, fn {track_id, note_id, after_id, span, attrs},
                                               {:ok, hist} ->
      req = %InsertNote{
        track_id: track_id,
        note_id: note_id,
        after_id: after_id,
        span: span,
        attrs: attrs
      }

      case History.apply(hist, req) do
        {:ok, hist} -> {:cont, {:ok, hist}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, hist} -> {:ok, %{project | workspace: History.current(hist).workspace}}
      {:error, _} = err -> err
    end
  end

  defp twelve_et(midi) do
    {:ok, key} = TwelveET.new(midi)
    key
  end
end
