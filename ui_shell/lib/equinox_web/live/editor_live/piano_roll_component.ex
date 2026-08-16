defmodule EquinoxWeb.EditorLive.PianoRollComponent do
  use EquinoxWeb, :live_component

  require Logger

  alias Equinox.Session.Server
  alias EquinoxDomain.Port.Channels.Curve
  alias EquinoxUIShell.ProjectPresenter

  def render(assigns) do
    ~H"""
    <div
      class="flex-1 border border-zinc-700 rounded overflow-hidden"
      id={@id}
      phx-hook="PianoRollHook"
      phx-target={@myself}
      phx-update="ignore"
    >
    </div>
    """
  end

  def handle_event("focus_segment", %{"track_id" => track_id, "segment_id" => seg_id}, socket) do
    send(self(), {:focus_segment, track_id, seg_id})
    {:noreply, socket}
  end

  # 前端音符是窗口相对 tick 的 plain map；segment id 即 "w<start_tick>"（见 Presenter）
  def handle_event(
        "replace_segment_notes",
        %{"track_id" => track_id, "segment_id" => seg_id, "notes" => note_params},
        socket
      ) do
    server = Equinox.Session.server(socket.assigns.session_id)

    with {:ok, window_start} <- ProjectPresenter.parse_window_id(seg_id),
         {:ok, note_attrs} <- ui_notes_to_attrs(note_params, window_start),
         {:ok, _track} <- Server.replace_window_notes(server, track_id, window_start, note_attrs) do
      # 写时 transport 可能杀死 patch（如锚定音符被删）——排干 kernel 通知队列上浮
      case Server.take_notifications(server) do
        [] -> :ok
        notifications -> send(self(), {:push_notifications, notifications})
      end

      send(self(), :project_updated)
      {:noreply, socket}
    else
      {:error, reason} ->
        Logger.warning(
          "replace_segment_notes failed (track #{inspect(track_id)}, segment #{seg_id}): " <>
            inspect(reason)
        )

        {:noreply, socket}
    end
  end

  # 手绘笔画采纳：前端给锚定音符 id 列表 + 绝对 tick 控制点（string 键），
  # 在此收口为 Curve.build_payload 的 atom 键形状后走真实 adopt 链路
  def handle_event(
        "adopt_curve",
        %{"track_id" => track_id, "note_ids" => note_ids, "points" => points},
        socket
      )
      when is_list(note_ids) and is_list(points) do
    server = Equinox.Session.server(socket.assigns.session_id)

    with {:ok, payload} <- stroke_curve_payload(points),
         {:ok, _track, _patch} <-
           Server.adopt_intervention(server, track_id,
             channel: Curve,
             anchor: {:ordinal, note_ids},
             payload: payload
           ) do
      send(self(), :project_updated)
      {:noreply, socket}
    else
      {:error, reason} ->
        Logger.warning("adopt_curve failed (track #{inspect(track_id)}): #{inspect(reason)}")
        send(self(), {:push_notifications, [{:adopt_failed, reason}]})
        {:noreply, socket}
    end
  end

  defp stroke_curve_payload(points) do
    normalized =
      Enum.map(points, fn point ->
        %{
          tick: point["tick"],
          value: point["value"],
          handle_left: nil,
          handle_right: nil
        }
      end)

    Curve.build_payload(:pitch, Coconut.Curve.Adapter.Bezier, normalized)
  end

  defp ui_notes_to_attrs(note_params, window_start) do
    Enum.reduce_while(note_params, {:ok, []}, fn note, {:ok, acc} ->
      case ProjectPresenter.ui_note_to_attrs(note, window_start) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, attrs_list} -> {:ok, Enum.reverse(attrs_list)}
      {:error, _} = err -> err
    end
  end
end
