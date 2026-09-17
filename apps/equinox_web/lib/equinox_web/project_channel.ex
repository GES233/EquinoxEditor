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

  # 模型检查不能堵住 Channel 的编辑和快照消息；每个连接最多一个检查。
  def handle_in("check", _params, socket) do
    if socket.assigns[:check_task] do
      respond({:error, :check_in_progress}, socket)
    else
      project_id = socket.assigns.project_id

      task =
        Task.Supervisor.async_nolink(EquinoxWeb.QuerySupervisor, fn -> Neumu.check(project_id) end)

      {:noreply, assign(socket, :check_task, {task, socket_ref(socket)})}
    end
  end

  def handle_in("preflight_pin", %{"track_id" => track_id, "note_id" => note_id}, socket)
      when is_binary(track_id) and is_binary(note_id),
      do: respond(Neumu.preflight_pin(socket.assigns.project_id, track_id, note_id), socket)

  def handle_in("edit", params, socket),
    do: respond(edit(socket.assigns.project_id, params), socket)

  def handle_in(_event, _params, socket), do: respond({:error, :unknown_event}, socket)

  @impl true
  def handle_info({ref, result}, %{assigns: %{check_task: {%Task{ref: ref}, reply_ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    Phoenix.Channel.reply(reply_ref, wire_reply(result))
    {:noreply, assign(socket, :check_task, nil)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{check_task: {%Task{ref: ref}, reply_ref}}} = socket
      ) do
    Phoenix.Channel.reply(reply_ref, {:error, error({:check_failed, reason})})
    {:noreply, assign(socket, :check_task, nil)}
  end

  def handle_info({:project_changed, project_id, history_pin}, socket) do
    push(socket, "project_changed", %{project_id: project_id, history_pin: history_pin})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:check_task] do
      {%Task{pid: pid}, _} -> Task.Supervisor.terminate_child(EquinoxWeb.QuerySupervisor, pid)
      _ -> :ok
    end
  end

  defp edit(project_id, %{
         "command" => "mount_pitch",
         "track_id" => track_id,
         "note_id" => note_id,
         "points" => points,
         "token" => token
       })
       when is_binary(track_id) and is_binary(note_id) do
    with :ok <- validate_points(points),
         {:ok, token} <- decode_token(token) do
      Neumu.mount_pitch(project_id, track_id, note_id, points, token)
    end
  end

  defp edit(project_id, %{
         "command" => "replace_pitch",
         "track_id" => track_id,
         "patch_id" => patch_id,
         "points" => points
       })
       when is_binary(track_id) and is_binary(patch_id) do
    with :ok <- validate_points(points) do
      Neumu.replace_pin(project_id, track_id, patch_id, %{
        schema: "score_pitch_v2",
        coordinates: "note_tick",
        values: points
      })
    end
  end

  defp edit(project_id, %{"command" => "repatch", "track_id" => track_id, "patch_ids" => ids})
       when is_binary(track_id) and is_list(ids) and length(ids) > 0 and length(ids) <= 64 do
    if Enum.all?(ids, &is_binary/1),
      do: Neumu.repatch(project_id, track_id, ids),
      else: {:error, :invalid_patch_ids}
  end

  defp edit(project_id, %{
         "command" => "unmount_pitch",
         "track_id" => track_id,
         "note_id" => note_id
       })
       when is_binary(track_id) and is_binary(note_id),
       do: Neumu.unmount_pin(project_id, track_id, note_id, :pitch)

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

  defp validate_points(points)
       when is_list(points) and length(points) > 0 and length(points) <= 64 do
    valid =
      Enum.all?(points, fn
        [tick, midi]
        when is_integer(tick) and tick >= 0 and tick <= 1_000_000_000 and is_number(midi) and
               midi >= 0 and midi <= 127 ->
          true

        _ ->
          false
      end)

    if valid and
         Enum.all?(Enum.chunk_every(points, 2, 1, :discard), fn [[a, _], [b, _]] -> a < b end),
       do: :ok,
       else: {:error, :invalid_pitch_points}
  end

  defp validate_points(_), do: {:error, :invalid_pitch_points}

  defp decode_token(%{"track_id" => track_id, "note_id" => note_id, "history_pin" => pin} = token)
       when map_size(token) == 3 and is_binary(track_id) and is_binary(note_id) and
              is_integer(pin),
       do: {:ok, %{track_id: track_id, note_id: note_id, history_pin: pin}}

  defp decode_token(_), do: {:error, :invalid_pin_token}

  defp respond(result, socket), do: {:reply, wire_reply(result), socket}

  defp wire_reply({:ok, pin, results}) when is_list(results),
    do: {:ok, %{data: %{history_pin: pin, results: json_safe(results)}}}

  defp wire_reply({:ok, pin, result}),
    do: {:ok, %{data: %{history_pin: pin, result: json_safe(result)}}}

  defp wire_reply({:ok, value}), do: {:ok, %{data: json_safe(value)}}
  defp wire_reply({:error, reason}), do: {:error, error(reason)}

  # facade 的 reason 保留 tagged tuple，浏览器边界才递归转 list。
  defp json_safe(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)

  defp json_safe(value), do: value

  defp error(reason), do: %{reason: inspect(reason)}
end
