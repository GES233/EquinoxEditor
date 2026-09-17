defmodule EquinoxWeb.ProjectChannel do
  @moduledoc "工作区事件桥：只调用 Neumu facade，不另存工程，不接受任意函数调用。"
  use Phoenix.Channel

  @impl true
  def join("project:" <> project_id, _params, socket) do
    if socket.assigns.project_id == project_id do
      with :ok <- Neumu.subscribe(project_id),
           {:ok, snapshot} <- Neumu.snapshot(project_id) do
        {:ok, %{snapshot: snapshot}, socket}
      else
        {:error, reason} -> {:error, error(reason)}
      end
    else
      {:error, error(:unauthorized)}
    end
  end

  @impl true
  def handle_in("snapshot", _params, socket),
    do: respond(Neumu.snapshot(socket.assigns.project_id), socket)

  def handle_in("voicebanks", _params, socket),
    do: respond(Neumu.list_voicebanks(socket.assigns.project_id), socket)

  def handle_in("edit", params, socket),
    do: respond(edit(socket.assigns.project_id, params), socket)

  def handle_in(_event, _params, socket), do: respond({:error, :unknown_event}, socket)

  @impl true
  def handle_info({:project_changed, project_id, history_pin}, socket) do
    push(socket, "project_changed", %{project_id: project_id, history_pin: history_pin})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp edit(project_id, %{"command" => "undo"}), do: Neumu.undo(project_id)
  defp edit(project_id, %{"command" => "redo"}), do: Neumu.redo(project_id)

  defp edit(project_id, %{
         "command" => "edit_note",
         "track_id" => track_id,
         "note_id" => note_id,
         "changes" => changes
       })
       when is_binary(track_id) and is_binary(note_id) and is_map(changes) do
    with {:ok, attrs} <- note_attrs(changes) do
      Neumu.edit_note(project_id, track_id, note_id, attrs)
    end
  end

  defp edit(project_id, %{
         "command" => "move_note",
         "track_id" => track_id,
         "note_id" => note_id,
         "span" => [start_tick, end_tick]
       })
       when is_binary(track_id) and is_binary(note_id) and is_integer(start_tick) and
              is_integer(end_tick) and start_tick >= 0 and end_tick > start_tick do
    # 首个里程碑只允许单音符横向移动，避免凭 UI 顺序推测多音符重排规则。
    with {:ok, snapshot} <- Neumu.snapshot(project_id),
         %{notes: [%{id: ^note_id}]} <- Enum.find(snapshot.tracks, &(&1.id == track_id)) do
      Neumu.move_note(project_id, track_id, note_id, :head, {start_tick, end_tick})
    else
      {:error, _} = error -> error
      _ -> {:error, :single_note_required}
    end
  end

  defp edit(project_id, %{
         "command" => "rebind_voicebank",
         "track_id" => track_id,
         "voicebank_id" => voicebank_id
       })
       when is_binary(track_id) and is_binary(voicebank_id),
       do: Neumu.rebind_voicebank(project_id, track_id, voicebank_id)

  defp edit(_project_id, _params), do: {:error, :invalid_command}

  defp note_attrs(changes) when map_size(changes) > 0 do
    Enum.reduce_while(changes, {:ok, %{}}, fn
      {"lyric", lyric}, {:ok, acc} when is_binary(lyric) and byte_size(lyric) <= 4096 ->
        {:cont, {:ok, Map.put(acc, :lyric, lyric)}}

      {"pitch", pitch}, {:ok, acc} when is_integer(pitch) and pitch >= 0 and pitch <= 127 ->
        {:cont, {:ok, Map.put(acc, :pitch, pitch)}}

      _, _ ->
        {:halt, {:error, :invalid_note_changes}}
    end)
  end

  defp note_attrs(_changes), do: {:error, :invalid_note_changes}

  defp respond({:ok, value}, socket), do: {:reply, {:ok, %{data: value}}, socket}
  defp respond({:error, reason}, socket), do: {:reply, {:error, error(reason)}, socket}

  defp error(reason), do: %{reason: inspect(reason)}
end
