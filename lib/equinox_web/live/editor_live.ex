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
    # Fetch nodes from registry
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

  def handle_event("update_notes", %{"notes" => notes}, socket) do
    IO.puts("Received notes from PianoRoll:")
    IO.inspect(notes)
    # TODO: 走 Equinox.Session.Server 的 apply_operation 操作 History
    {:noreply, socket}
  end

  def handle_event("synth_graph_update", payload, socket) do
    IO.puts("Received topology update from NodeEditor:")
    IO.inspect(payload)
    # TODO: 将前端发来的 node/edges 解析为 Graph.t() 并推入 Track History
    {:noreply, socket}
  end

  # Arranger hooks
  def handle_event("add_arranger_node", payload, socket) do
    IO.inspect(payload, label: "Arranger Add External Node")
    {:noreply, socket}
  end

  def handle_event("add_external_node", payload, socket) do
    IO.inspect(payload, label: "Arranger Remove External Node")
    {:noreply, socket}
  end

  def handle_event("update_node_properties", payload, socket) do
    IO.inspect(payload, label: "Arranger Update Node Properties")
    {:noreply, socket}
  end

  def handle_event("mix", _payload, socket) do
    IO.puts("Arranger triggered Mix (Dispatch to Engine)")
    # 模拟通知前端开始 Mix，然后在后台跑 Engine
    {:noreply, push_event(socket, "mix_result", %{status: "started"})}
  end

  def handle_event("export", payload, socket) do
    IO.inspect(payload, label: "Arranger Export Audio")
    {:noreply, push_event(socket, "export_result", %{status: "started"})}
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
            id="piano-roll-island"
            phx-update="ignore"
          >
            <!-- 插入 Slicer -->
          </div>
          <div
            class="flex-1 border border-zinc-700 rounded overflow-hidden"
            id="piano-roll-island"
            phx-hook="PianoRollHook"
            phx-update="ignore"
          >
          </div>
        </div>

        <!-- Right panel: Node Editor -->
        <div
          class="h-18 border border-zinc-700 rounded overflow-hidden"
          id="arranger-island"
          phx-hook="ArrangerHook"
          phx-update="ignore"
        >
        </div>
      </div>
    </div>
    """
  end
end
