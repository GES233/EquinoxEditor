defmodule EquinoxWeb.EditorLive.PianoRollComponent do
  use EquinoxWeb, :live_component

  alias Equinox.Editor
  alias Equinox.Domain.Note

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

  def handle_event(
        "replace_segment_notes",
        %{"track_id" => track_id, "segment_id" => seg_id, "notes" => note_params},
        socket
      ) do
    project = GenServer.call(Equinox.Session.server(socket.assigns.session_id), {:get_project})
    notes = Enum.map(note_params, &build_note/1)

    case Editor.replace_segment_notes(project, track_id, seg_id, notes) do
      {:ok, updated_project} ->
        GenServer.call(
          Equinox.Session.server(socket.assigns.session_id),
          {:update_project, updated_project}
        )

        send(self(), {:project_updated, updated_project})
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp build_note(note_params) do
    Note.new(%{
      id: Map.get(note_params, "id"),
      start_tick: Map.get(note_params, "start_tick", 0),
      duration_tick:
        Map.get(note_params, "duration_tick", Map.get(note_params, "length_tick", 480)),
      key: Map.get(note_params, "key", Map.get(note_params, "pitch", 60)),
      lyric: Map.get(note_params, "lyric", "la"),
      phoneme: Map.get(note_params, "phoneme"),
      extra: Map.get(note_params, "extra", %{})
    })
  end
end
