defmodule EquinoxWeb.EditorLive.ArrangerComponent do
  use EquinoxWeb, :live_component

  def render(assigns) do
    ~H"""
    <div
      class="h-18 border border-zinc-700 rounded overflow-hidden"
      id={@id}
      phx-hook="ArrangerHook"
      phx-target={@myself}
      phx-update="ignore"
    >
    </div>
    """
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
end
