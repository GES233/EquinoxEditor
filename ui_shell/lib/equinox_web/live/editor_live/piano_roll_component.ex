defmodule EquinoxWeb.EditorLive.PianoRollComponent do
  use EquinoxWeb, :live_component

  require Logger

  alias Equinox.Session.Server
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
