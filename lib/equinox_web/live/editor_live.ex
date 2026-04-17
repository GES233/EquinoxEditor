defmodule EquinoxWeb.EditorLive do
  use EquinoxWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 握手时初始化一个 Session
      session_id = "default_session"
      Equinox.Session.start(session_id)
      # 这里可以按需 subscribe 等待 engine 的事件

      send(self(), :push_initial_state)
    end

    {:ok, assign(socket, page_title: "Equinox Editor", session_id: "default_session")}
  end

  def handle_info(:push_initial_state, socket) do
    # 1. Provide project initial state
    project =
      Equinox.Project.new(%{
        name: "Equinox Default Session",
        tracks: %{
          "track_1" =>
            Equinox.Editor.Track.new(
              id: "track_1",
              type: "synth",
              name: "Main Vocal",
              segments: %{
                "seg_1" =>
                  Equinox.Editor.Segment.new(%{
                    id: "seg_1",
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

    socket = push_event(socket, "project_load", project)
    socket = push_event(socket, "arranger-island:project_load", project)

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

  def handle_event("synth_graph_update", payload, socket) do
    IO.puts("Received topology update from NodeEditor:")
    IO.inspect(payload)
    # TODO: 将前端发来的 node/edges 解析为 Graph.t() 并推入 Track History
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen flex flex-col bg-zinc-900 text-white">
      <div class="p-4 border-b border-zinc-700 font-bold">Equinox M0 Skeleton</div>

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
        
    <!-- Right panel: Arranger Editorr -->
        <.live_component
          module={EquinoxWeb.EditorLive.ArrangerComponent}
          id="arranger-island"
          session_id={@session_id}
        />
      </div>
    </div>
    """
  end
end
