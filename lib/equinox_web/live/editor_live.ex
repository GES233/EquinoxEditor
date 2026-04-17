defmodule EquinoxWeb.EditorLive do
  use EquinoxWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 握手时初始化一个 Session
      session_id = "default_session"
      Equinox.Session.start(session_id)
      # 这里可以按需 subscribe 等待 engine 的事件
    end

    {:ok, assign(socket, page_title: "Equinox Editor", session_id: "default_session")}
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
  def handle_event("add_external_node", payload, socket) do
    IO.inspect(payload, label: "Arranger Add External Node")
    {:noreply, socket}
  end

  def handle_event("remove_external_node", payload, socket) do
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
            phx-hook="PianoRollHook"
            phx-update="ignore"
          >
          </div>
          <div
            class="h-48 border border-zinc-700 rounded overflow-hidden"
            id="arranger-island"
            phx-hook="ArrangerHook"
            phx-update="ignore"
          >
          </div>
        </div>
        
    <!-- Right panel: Node Editor -->
        <div
          class="w-1/3 border border-zinc-700 rounded overflow-hidden"
          id="node-editor-island"
          phx-hook="NodeEditorHook"
          phx-update="ignore"
        >
        </div>
      </div>
    </div>
    """
  end
end
