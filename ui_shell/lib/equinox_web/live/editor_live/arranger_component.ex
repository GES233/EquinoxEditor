defmodule EquinoxWeb.EditorLive.ArrangerComponent do
  use EquinoxWeb, :live_component

  alias Equinox.{Editor, Project, Track}

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

  def handle_event("select_track", %{"track_id" => track_id}, socket) do
    send(self(), {:select_track, track_id})
    {:noreply, socket}
  end

  def handle_event("focus_segment", %{"track_id" => track_id, "segment_id" => segment_id}, socket) do
    send(self(), {:focus_segment, track_id, segment_id})
    {:noreply, socket}
  end

  # Arranger hooks
  def handle_event("add_arranger_node", payload, socket) do
    IO.inspect(payload, label: "Arranger Add External Node")
    {:noreply, socket}
  end

  def handle_event("add_external_node", %{"label" => label}, socket) do
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})

    track =
      Track.new(%{
        id: "track_#{System.unique_integer([:positive])}",
        type: "external_audio",
        name: label,
        gain: 1.0
      })

    case Project.add_track(project, track) do
      {:ok, updated_project} ->
        persist_project(socket, updated_project)

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_external_node", %{"id" => track_id}, socket) do
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})
    updated_project = Project.remove_track(project, track_id)
    persist_project(socket, updated_project)
  end

  def handle_event("update_node_properties", %{"node_id" => "output"}, socket) do
    {:noreply, socket}
  end

  def handle_event("update_node_properties", %{"node_id" => track_id, "props" => props}, socket) do
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})

    with {:ok, updated_project} <- apply_track_props(project, track_id, props) do
      persist_project(socket, updated_project)
    else
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("add_edge", _payload, socket) do
    {:noreply, socket}
  end

  def handle_event("remove_edge", _payload, socket) do
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

  defp apply_track_props(%Project{} = project, track_id, props) do
    mix_updates =
      %{}
      |> maybe_put(:gain, Map.get(props, "volume"))
      |> maybe_put(:mute, Map.get(props, "muted"))
      |> maybe_put(:solo, Map.get(props, "solo"))

    with {:ok, project} <- maybe_update_track_mix(project, track_id, mix_updates),
         {:ok, project} <- maybe_update_track_position(project, track_id, Map.get(props, "position")) do
      {:ok, project}
    end
  end

  defp maybe_update_track_mix(project, _track_id, updates) when map_size(updates) == 0, do: {:ok, project}

  defp maybe_update_track_mix(project, track_id, updates) do
    Editor.update_track_mix(project, track_id, updates)
  end

  defp maybe_update_track_position(project, _track_id, nil), do: {:ok, project}

  defp maybe_update_track_position(project, track_id, position) do
    Editor.update_track_ui_state(project, track_id, :arranger_position, position)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp persist_project(socket, updated_project) do
    GenServer.call(
      Equinox.Session.server(socket.assigns.session_id),
      {:update_project, updated_project}
    )

    send(self(), {:project_updated, updated_project})
    {:noreply, socket}
  end
end
