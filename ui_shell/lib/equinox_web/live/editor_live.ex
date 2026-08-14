defmodule EquinoxWeb.EditorLive do
  use EquinoxWeb, :live_view

  require Logger

  alias Coconut.Edit.{History, Operations.InsertNote}
  alias Coconut.Score.Key.TwelveET
  alias Coconut.Util.ID
  alias Equinox.Session.Server
  alias EquinoxDomain.Score.{Project, Track, TrackMeta}
  alias EquinoxUIShell.{ProjectPresenter, SessionHost}

  @graph_translator Application.compile_env(
                      :equinox_ui_shell,
                      :graph_translator,
                      EquinoxUIShell.SvelteFlowGraphTranslator
                    )

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 握手时初始化一个 Session；demo 工程经 child_spec 的 project opt 注入
      # （重复连接时 Session 已存在，start_session 返回 already_started，幂等）
      session_id = "default_session"
      SessionHost.start_session(session_id, project: build_default_proj())
      # 这里可以按需 subscribe 等待 engine 的事件

      send(self(), :push_initial_state)
    end

    {:ok,
     assign(socket,
       page_title: "Equinox Editor",
       session_id: "default_session",
       current_track_id: nil,
       current_segment_id: nil,
       current_scope: "track"
     )}
  end

  def handle_info(:push_initial_state, socket) do
    # 1. 推工程初始状态（Session 视图 → presenter → 前端 TS 形状）
    view = Server.get_view(server(socket))
    context = build_editor_context(view.project)

    socket =
      socket
      |> assign_editor_context(context)
      |> push_project_state(view)
      |> push_editor_context(context)

    # 2. Fetch nodes from registry
    all_nodes = Equinox.Kernel.StepRegistry.list_all()

    # Determine synth vs arranger nodes by a simple heuristic (or we can add categories to StepRegistry)
    # For now: :track_input, :mixer, :master_output -> Arranger; others -> Synth
    arranger_types = [:track_input, :mixer, :master_output]

    synth_defs =
      all_nodes
      |> Enum.reject(fn {name, _spec} -> name in arranger_types end)
      |> Enum.map(fn {name, spec} ->
        %{
          name: to_string(name) |> String.capitalize(),
          module: to_string(spec.module),
          inputs: spec.inputs,
          outputs: spec.outputs
        }
      end)

    arranger_defs =
      all_nodes
      |> Enum.filter(fn {name, _spec} -> name in arranger_types end)
      |> Enum.map(fn {name, spec} ->
        %{
          name: to_string(name) |> String.capitalize(),
          module: to_string(spec.module),
          inputs: spec.inputs,
          outputs: spec.outputs
        }
      end)

    socket =
      socket
      |> push_event("synth_nodes_available", %{nodes: synth_defs})
      |> push_event("arranger_nodes_available", %{nodes: arranger_defs})

    {:noreply, socket}
  end

  def handle_info({:select_track, track_id}, socket) do
    view = Server.get_view(server(socket))
    context = build_editor_context(view.project, track_id, nil, "track")

    socket =
      socket
      |> assign_editor_context(context)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_info({:focus_segment, track_id, segment_id}, socket) do
    view = Server.get_view(server(socket))
    context = build_editor_context(view.project, track_id, segment_id, "segment")

    socket =
      socket
      |> assign_editor_context(context)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_info(:project_updated, socket) do
    # 统一从 Session 重取视图再重推（不带 payload；窗口边界可能已变，context 重新解析）
    view = Server.get_view(server(socket))

    context =
      build_editor_context(
        view.project,
        socket.assigns.current_track_id,
        socket.assigns.current_segment_id,
        socket.assigns.current_scope
      )

    socket =
      socket
      |> assign_editor_context(context)
      |> push_project_state(view)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_event("synth_graph_update", payload, socket) do
    track_id = Map.get(payload, "track_id", socket.assigns.current_track_id)
    nodes = Map.get(payload, "nodes", [])
    edges = Map.get(payload, "edges", [])

    {:ok, synth_graph} = @graph_translator.to_graph(nodes, edges)

    case Server.update_synth_graph(server(socket), track_id, synth_graph) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("update_synth_graph failed: #{inspect(reason)}")
    end

    socket =
      socket
      |> assign(current_scope: "track_synth")
      |> push_editor_context(%{
        track_id: track_id,
        segment_id: socket.assigns.current_segment_id,
        scope: "track_synth"
      })

    send(self(), :project_updated)

    {:noreply, socket}
  end

  def handle_event("render_audio", _payload, socket) do
    IO.puts("Triggering render pipeline via Session.Server dispatcher...")

    # 触发 Orchid 渲染流程
    Server.dispatch(server(socket), concurrency: 4, timeout: 5000)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen flex flex-col bg-zinc-900 text-white">
      <div class="p-4 border-b border-zinc-700 flex justify-between items-center">
        <div class="font-bold">Equinox M0 Skeleton</div>
        <button
          phx-click="render_audio"
          class="px-4 py-2 bg-amber-600 hover:bg-amber-500 text-white font-semibold rounded shadow-md cursor-pointer transition-colors"
        >
          ▶ Render & Play
        </button>
      </div>

      <div class="flex-1 flex p-4 gap-4">
        <!-- Left panel: Piano Roll & Arranger -->
        <div class="flex-1 flex flex-col gap-4">
          <.live_component
            module={EquinoxWeb.EditorLive.PianoRollComponent}
            id="piano-roll-island"
            session_id={@session_id}
          />
        </div>
        <!-- Right panel: Node Editor & Arranger -->
        <div class="flex-1 flex flex-col gap-4">
          <div
            class="flex-1 border border-zinc-700 rounded overflow-hidden relative"
            id="node-editor-island"
            phx-hook="NodeEditorHook"
            phx-update="ignore"
          >
            <!-- 插入 NodeEditor -->
          </div>

          <.live_component
            module={EquinoxWeb.EditorLive.ArrangerComponent}
            id="arranger-island"
            session_id={@session_id}
          />
        </div>
      </div>
    </div>
    """
  end

  ## 一些 Private functions

  defp server(socket), do: Equinox.Session.server(socket.assigns.session_id)

  defp push_project_state(socket, view) do
    push_event(socket, "project_load", ProjectPresenter.to_frontend(view))
  end

  defp push_editor_context(socket, context) do
    push_event(socket, "editor_context", context)
  end

  defp assign_editor_context(socket, context) do
    assign(socket,
      current_track_id: context.track_id,
      current_segment_id: context.segment_id,
      current_scope: context.scope
    )
  end

  defp build_editor_context(
         %Project{} = project,
         preferred_track_id \\ nil,
         preferred_segment_id \\ nil,
         preferred_scope \\ "track"
       ) do
    track_id = resolve_track_id(project, preferred_track_id)
    segment_id = resolve_segment_id(project, track_id, preferred_segment_id)

    %{track_id: track_id, segment_id: segment_id, scope: preferred_scope}
  end

  defp resolve_track_id(%Project{} = project, preferred_track_id) do
    case preferred_track_id && Project.fetch_track(project, preferred_track_id) do
      {:ok, _track} ->
        preferred_track_id

      _ ->
        project.workspace.tracks
        |> Map.keys()
        |> Enum.sort_by(&to_string/1)
        |> List.first()
    end
  end

  defp resolve_segment_id(_project, nil, _preferred_segment_id), do: nil

  # segment 即窗口投影：preferred 失配（窗口边界已变 / 不存在）时回落首个 window id
  defp resolve_segment_id(%Project{} = project, track_id, preferred_segment_id) do
    with {:ok, _track} <- Project.fetch_track(project, track_id),
         {:ok, windows} <- Track.slice(project, track_id) do
      window_ids =
        windows
        |> Enum.map(&ProjectPresenter.window_id(&1.start_tick))
        |> Enum.sort()

      if preferred_segment_id && preferred_segment_id in window_ids do
        preferred_segment_id
      else
        List.first(window_ids)
      end
    else
      {:error, _} -> nil
    end
  end

  # demo 工程：一轨两音符（绝对 tick 0..240 / 240..720，同窗口），
  # tempo 全局轨一个 Step 120 事件。结构写经 coconut History + InsertNote
  # （与 kernel 写路径同源；kernel overall_test 夹具同款模式）。
  defp build_default_proj do
    {:ok, key1} = TwelveET.new(60)
    {:ok, key2} = TwelveET.new(62)

    {:ok, project} =
      Project.new(
        id: ID.generate_id("Project_"),
        metadata: %{name: "Equinox Default Session"}
      )

    {:ok, project, _track} = Project.add_track(project, id: "track_1", name: "Main Vocal")

    note1_id = ID.generate_id("Note_")
    note2_id = ID.generate_id("Note_")

    {:ok, project} =
      seed_elements(project, [
        # coconut tempo 是一条全局轨：元素为 %{bpm: milli_bpm}
        # （InsertNote cast 时经 `Coconut.Score.Tempo.cast_bpm/1` 归一化）
        {"global:tempo", ID.generate_id("Tempo_"), :head, {0, 480}, %{bpm: 120}},
        {"track_1", note1_id, :head, {0, 240}, %{pitch: key1, lyric: "a"}},
        {"track_1", note2_id, note1_id, {240, 720}, %{pitch: key2, lyric: "ha"}}
      ])

    # 混音 / UI 状态属 equinox 侧表（TrackMeta，不进 History）
    {:ok, meta} =
      TrackMeta.new(gain: 0.8, ui_state: %{arranger_position: %{x: 50, y: 30}})

    {:ok, project} = Project.put_track_meta(project, "track_1", meta)
    project
  end

  # 经 coconut History 逐条 apply InsertNote 手势，返回 workspace 已推进的 project
  defp seed_elements(%Project{} = project, inserts) do
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
end
