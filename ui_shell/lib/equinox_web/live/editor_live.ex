defmodule EquinoxWeb.EditorLive do
  use EquinoxWeb, :live_view

  alias Equinox.Project

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 握手时初始化一个 Session
      session_id = "default_session"
      Equinox.Session.start(session_id)
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
    # 1. Provide project initial state
    project = build_default_proj()
    context = build_editor_context(project)

    GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:update_project, project})

    socket =
      socket
      |> assign_editor_context(context)
      |> push_project_state(project)
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
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})
    context = build_editor_context(project, track_id, nil, "track")

    socket =
      socket
      |> assign_editor_context(context)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_info({:focus_segment, track_id, segment_id}, socket) do
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})
    context = build_editor_context(project, track_id, segment_id, "segment")

    socket =
      socket
      |> assign_editor_context(context)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_info({:project_updated, project}, socket) do
    context =
      build_editor_context(
        project,
        socket.assigns.current_track_id,
        socket.assigns.current_segment_id,
        socket.assigns.current_scope
      )

    socket =
      socket
      |> assign_editor_context(context)
      |> push_project_state(project)
      |> push_editor_context(context)

    {:noreply, socket}
  end

  def handle_event("synth_graph_update", payload, socket) do
    IO.puts("Received topology update from NodeEditor:")

    track_id = Map.get(payload, "track_id", socket.assigns.current_track_id)
    nodes = Map.get(payload, "nodes", [])
    edges = Map.get(payload, "edges", [])

    {:ok, synth_graph} = Equinox.Kernel.SvelteFlowTranslator.from_svelte_payload(nodes, edges)

    # 更新 Session/Project (这里临时只推入 default_session)
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})

    updated_project =
      case Project.get_track(project, track_id) do
        {:ok, track} ->
          updated_track = %{track | synth_graph: synth_graph}
          {:ok, new_proj} = Project.update_track(project, track_id, updated_track)
          new_proj

        {:error, _} ->
          project
      end

    # 理论上应该通过 Command 机制更新，这里简化处理
    GenServer.call(
      Equinox.Session.server(socket.assigns.session_id),
      {:update_project, updated_project}
    )

    socket =
      socket
      |> assign(current_scope: "track_synth")
      |> push_editor_context(%{
        track_id: track_id,
        segment_id: socket.assigns.current_segment_id,
        scope: "track_synth"
      })

    send(self(), {:project_updated, updated_project})

    {:noreply, socket}
  end

  def handle_event("render_audio", _payload, socket) do
    IO.puts("Triggering render pipeline via Session.Server dispatcher...")

    # 触发 Orchid 渲染流程
    GenServer.cast(
      Equinox.Session.server(socket.assigns.session_id),
      {:dispatch, [concurrency: 4, timeout: 5000]}
    )

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
          <!-- phx-update="ignore" is required so LiveView doesn't destroy Svelte's DOM -->
          <div
            class="flex-1 border border-zinc-700 rounded overflow-hidden"
            id="slicer-island"
            phx-update="ignore"
          >
            <!-- 插入 Slicer -->
          </div>

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

  defp push_project_state(socket, %Project{} = project) do
    push_event(socket, "project_load", project)
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
    case preferred_track_id && Project.get_track(project, preferred_track_id) do
      {:ok, _track} ->
        preferred_track_id

      _ ->
        project.tracks
        |> Map.keys()
        |> Enum.sort_by(&to_string/1)
        |> List.first()
    end
  end

  defp resolve_segment_id(_project, nil, _preferred_segment_id), do: nil

  defp resolve_segment_id(%Project{} = project, track_id, preferred_segment_id) do
    with {:ok, track} <- Project.get_track(project, track_id) do
      case preferred_segment_id && Map.fetch(track.segments, preferred_segment_id) do
        {:ok, _segment} ->
          preferred_segment_id

        _ ->
          track.segments
          |> Map.keys()
          |> Enum.sort_by(&to_string/1)
          |> List.first()
      end
    else
      {:error, _} -> nil
    end
  end

  defp build_default_proj do
    Equinox.Project.new(%{
      name: "Equinox Default Session",
      tracks: %{
        "track_1" =>
          Equinox.Editor.Track.new(
            id: "track_1",
            type: "synth",
            name: "Main Vocal",
            gain: 0.8,
            ui_state: %{arranger_position: %{x: 50, y: 30}},
            segments: %{
              "seg_1" =>
                Equinox.Editor.Segment.new(%{
                  id: "seg_1",
                  track_id: "track_1",
                  offset_tick: 480,
                  notes: [
                    Equinox.Domain.Note.new(%{
                      start_tick: 0,
                      duration_tick: 240,
                      key: 60,
                      lyric: "a"
                    }),
                    Equinox.Domain.Note.new(%{
                      start_tick: 240,
                      duration_tick: 480,
                      key: 62,
                      lyric: "ha"
                    })
                  ]
                })
            }
          )
      }
    })
  end
end
