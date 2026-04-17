defmodule EquinoxWeb.EditorLive.PianoRollComponent do
  use EquinoxWeb, :live_component

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

  def handle_event("update_note", %{"segment_id" => seg_id, "note" => note_params}, socket) do
    IO.puts("Received note update from PianoRoll for segment: #{seg_id}")
    IO.inspect(note_params)
    # TODO: Pass the update up to Equinox.Session.Server to mutate the Project
    {:noreply, socket}
  end

  def handle_event("add_note", %{"segment_id" => seg_id, "note" => note_params}, socket) do
    IO.puts("Received new note from PianoRoll for segment: #{seg_id}")
    IO.inspect(note_params)
    # TODO: Pass the update up to Equinox.Session.Server
    {:noreply, socket}
  end

  def handle_event("delete_note", %{"segment_id" => seg_id, "note_id" => note_id}, socket) do
    IO.puts("Received note deletion from PianoRoll for segment: #{seg_id}, note: #{note_id}")
    # TODO: Pass the update up to Equinox.Session.Server
    {:noreply, socket}
  end
end
