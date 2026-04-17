defmodule EquinoxWeb.EditorLive do
  use EquinoxWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Equinox Editor")}
  end

  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen flex flex-col bg-zinc-900 text-white">
      <div class="p-4 border-b border-zinc-700 font-bold">Equinox M0 Skeleton</div>
      
      <div class="flex-1 flex p-4 gap-4">
        <!-- Left panel: Piano Roll & Arranger -->
        <div class="flex-1 flex flex-col gap-4">
          <!-- phx-update="ignore" is required so LiveView doesn't destroy Svelte's DOM -->
          <div class="flex-1 border border-zinc-700 rounded overflow-hidden" id="piano-roll-island" phx-hook="PianoRollHook" phx-update="ignore"></div>
          <div class="h-48 border border-zinc-700 rounded overflow-hidden" id="arranger-island" phx-hook="ArrangerHook" phx-update="ignore"></div>
        </div>
        
        <!-- Right panel: Node Editor -->
        <div class="w-1/3 border border-zinc-700 rounded overflow-hidden" id="node-editor-island" phx-hook="NodeEditorHook" phx-update="ignore"></div>
      </div>
    </div>
    """
  end
end