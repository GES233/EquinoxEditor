defmodule EquinoxWeb.EditorLive.ArrangerComponent do
  use EquinoxWeb, :live_component

  require Logger

  alias Equinox.Session.Server

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
    # TS 侧只发 label；type 在此边界显式固定为 :external_audio。
    # 注意（coconut 迁移期已知偏差）：kernel `add_track/2` 目前把 :module
    # 强制为 `Coconut.Edit.Track.Vocal`，且 coconut Track 不收 :type/:gain
    # 字段——此处的音频轨意图会被静默丢弃，实际落成一条 Vocal 轨。
    # 待 kernel 支持音频轨型前，保持 UI 意图原样上送。
    case Server.add_track(server(socket), %{type: :external_audio, name: label, gain: 1.0}) do
      {:ok, _track} ->
        send(self(), :project_updated)
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("add_external_node failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("remove_external_node", %{"id" => track_id}, socket) do
    case Server.remove_track(server(socket), track_id) do
      :ok ->
        send(self(), :project_updated)
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("remove_external_node failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("update_node_properties", %{"node_id" => "output"}, socket) do
    {:noreply, socket}
  end

  def handle_event("update_node_properties", %{"node_id" => track_id, "props" => props}, socket) do
    server = server(socket)

    mix_updates =
      %{}
      |> maybe_put(:gain, Map.get(props, "volume"))
      |> maybe_put(:mute, Map.get(props, "muted"))
      |> maybe_put(:solo, Map.get(props, "solo"))

    with :ok <- maybe_update_track_mix(server, track_id, mix_updates),
         :ok <- maybe_update_track_position(server, track_id, Map.get(props, "position")) do
      send(self(), :project_updated)
      {:noreply, socket}
    else
      {:error, reason} ->
        Logger.warning(
          "update_node_properties failed (track #{inspect(track_id)}): #{inspect(reason)}"
        )

        {:noreply, socket}
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

  defp server(socket), do: Equinox.Session.server(socket.assigns.session_id)

  defp maybe_update_track_mix(_server, _track_id, updates) when map_size(updates) == 0, do: :ok

  defp maybe_update_track_mix(server, track_id, updates) do
    case Server.update_track_mix(server, track_id, updates) do
      {:ok, _track} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_update_track_position(_server, _track_id, nil), do: :ok

  defp maybe_update_track_position(server, track_id, position) do
    case Server.update_track_ui_state(server, track_id, :arranger_position, position) do
      {:ok, _track} -> :ok
      {:error, _} = err -> err
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
