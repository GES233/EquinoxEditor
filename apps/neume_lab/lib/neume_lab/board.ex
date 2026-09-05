defmodule NeumeLab.Board do
  @moduledoc """
  实验台主面板（`Kino.JS.Live`）：钢琴卷帘、冲突横幅、渲染任务与试听，
  一块面板跑通 facade 契约四步流：改词 → 冲突 → 一键 repatch → 按 pin
  渲染并排试听。

  面板订阅 `Neumu` 工程事件：`project_changed` 触发重拉快照广播，
  `render_changed`/`artifact_ready` 触发重拉任务列表广播；连接时下发
  `%{project_id, snapshot, jobs, voicebanks}` 全量状态。编辑命令直接调
  `Neumu` facade；pin 挂载在服务端一次走完 probe → mount（前端不感知
  两阶段，`stale_pin` 由服务端重新 probe 重试一次兜底）。

  发往客户端的 payload 保持 JSON-safe：快照/声库本身已满足契约
  （`docs/facade-protocol.md`），check 条目的 `reason` 与任务的 `error`
  是结构化 tagged term，在本壳层边界转为 inspect 字符串。
  """

  use Kino.JS, assets_path: "lib/neume_lab/board"
  use Kino.JS.Live

  @doc "为已打开的工程启动实验台面板。"
  @spec new(Neume.RenderJob.project_id()) :: Kino.JS.Live.t()
  def new(project_id), do: Kino.JS.Live.new(__MODULE__, project_id)

  @impl true
  def init(project_id, ctx) do
    :ok = Neumu.subscribe(project_id)

    with {:ok, snapshot} <- Neumu.snapshot(project_id),
         {:ok, jobs} <- Neumu.list_render_jobs(project_id),
         {:ok, voicebanks} <- Neumu.list_voicebanks(project_id) do
      {:ok,
       assign(ctx,
         project_id: project_id,
         snapshot: snapshot,
         jobs: jobs,
         voicebanks: voicebanks
       )}
    else
      {:error, reason} ->
        raise ArgumentError, "无法为工程 #{inspect(project_id)} 启动实验台：#{inspect(reason)}"
    end
  end

  @impl true
  def handle_connect(ctx) do
    {:ok,
     %{
       project_id: ctx.assigns.project_id,
       snapshot: ctx.assigns.snapshot,
       jobs: sanitize_jobs(ctx.assigns.jobs),
       voicebanks: ctx.assigns.voicebanks
     }, ctx}
  end

  # --- Neumu 事件订阅 ---

  @impl true
  def handle_info(
        {:project_changed, project_id, _pin},
        %{assigns: %{project_id: project_id}} = ctx
      ) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    broadcast_event(ctx, "snapshot", snapshot)
    {:noreply, assign(ctx, snapshot: snapshot)}
  end

  def handle_info({:render_changed, _job_id, _status}, ctx), do: refresh_jobs(ctx)
  def handle_info({:artifact_ready, _job_id, _artifact_id, _pin}, ctx), do: refresh_jobs(ctx)
  def handle_info(_message, ctx), do: {:noreply, ctx}

  defp refresh_jobs(ctx) do
    {:ok, jobs} = Neumu.list_render_jobs(ctx.assigns.project_id)
    broadcast_event(ctx, "jobs", sanitize_jobs(jobs))
    {:noreply, assign(ctx, jobs: jobs)}
  end

  # --- 编辑命令 ---

  @impl true
  def handle_event("edit_lyric", %{"track_id" => track_id, "note_id" => note_id} = payload, ctx) do
    command(ctx, "edit_lyric", fn ->
      Neumu.edit_note(project_id(ctx), track_id, note_id, %{lyric: payload["lyric"]})
    end)
  end

  def handle_event("check", _payload, ctx) do
    broadcast_check(ctx)
    {:noreply, ctx}
  end

  def handle_event("repatch", %{"track_id" => track_id, "patch_ids" => patch_ids}, ctx) do
    case Neumu.repatch(project_id(ctx), track_id, patch_ids) do
      {:ok, _pin, results} ->
        broadcast_event(ctx, "repatch_result", %{status: :ok, results: sanitize_reasons(results)})
        # repatch 后权威状态已变，立即补一次 check 刷新冲突横幅。
        broadcast_check(ctx)

      {:error, reason} ->
        broadcast_error(ctx, "repatch", reason)
    end

    {:noreply, ctx}
  end

  def handle_event(
        "mount_duration",
        %{"track_id" => track_id, "note_id" => note_id, "durations" => durations},
        ctx
      ) do
    case validate_durations(durations) do
      {:ok, durations} ->
        command(ctx, "mount_duration", fn -> mount_duration(ctx, track_id, note_id, durations) end)

      :error ->
        broadcast_error(ctx, "mount_duration", {:invalid_durations, durations})
        {:noreply, ctx}
    end
  end

  def handle_event(
        "unmount_pin",
        %{"track_id" => track_id, "note_id" => note_id, "channel" => channel},
        ctx
      )
      when channel in ["pitch", "duration"] do
    command(ctx, "unmount_pin", fn ->
      Neumu.unmount_pin(project_id(ctx), track_id, note_id, String.to_existing_atom(channel))
    end)
  end

  def handle_event("render", payload, ctx) do
    pin = payload["pin"]
    opts = if is_integer(pin), do: [pin: pin], else: []

    command(ctx, "render", fn ->
      case Neumu.submit_render(project_id(ctx), [
             {:renderer, &NeumeLab.SineRenderer.render/1} | opts
           ]) do
        {:ok, job} -> {:ok, job.source_pin}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def handle_event("play", %{"artifact_id" => artifact_id}, ctx) do
    with {:ok, artifact} <- Neumu.artifact(artifact_id),
         {:ok, wav} <- File.read(artifact.path) do
      broadcast_event(ctx, "audio", {:binary, %{artifact_id: artifact_id}, wav})
    else
      {:error, reason} -> broadcast_error(ctx, "play", reason)
    end

    {:noreply, ctx}
  end

  def handle_event("undo", _payload, ctx) do
    command(ctx, "undo", fn -> Neumu.undo(project_id(ctx)) end)
  end

  def handle_event("redo", _payload, ctx) do
    command(ctx, "redo", fn -> Neumu.redo(project_id(ctx)) end)
  end

  # 未知/畸形事件不静默吞掉：回显 command_error，让面板状态条可见。
  def handle_event(event, payload, ctx) do
    broadcast_error(ctx, "unknown_event", {:unknown_event, event, inspect(payload)})
    {:noreply, ctx}
  end

  # 客户端入参校验：[[音素下标, tick 时长], ...]，均为非负整数。
  defp validate_durations(durations) when is_list(durations) do
    if Enum.all?(durations, &valid_duration?/1), do: {:ok, durations}, else: :error
  end

  defp validate_durations(_other), do: :error

  defp valid_duration?([index, ticks])
       when is_integer(index) and index >= 0 and is_integer(ticks) and ticks > 0,
       do: true

  defp valid_duration?(_other), do: false

  # 两阶段挂载收进服务端一次走完；stale 时重新 probe 重试一次。
  defp mount_duration(ctx, track_id, note_id, durations) do
    with {:ok, probe} <- Neumu.probe_pin(project_id(ctx), track_id, note_id),
         {:ok, pin} <-
           Neumu.mount_phoneme_duration(project_id(ctx), track_id, note_id, durations, probe) do
      {:ok, pin}
    else
      {:error, {:stale_pin, _}} ->
        with {:ok, probe} <- Neumu.probe_pin(project_id(ctx), track_id, note_id) do
          Neumu.mount_phoneme_duration(project_id(ctx), track_id, note_id, durations, probe)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 编辑命令统一出口：成功由订阅事件驱动快照刷新；失败广播 command_error。
  defp command(ctx, op, fun) do
    case fun.() do
      {:ok, _pin} -> :ok
      {:error, reason} -> broadcast_error(ctx, op, reason)
    end

    {:noreply, ctx}
  end

  defp broadcast_error(ctx, op, reason) do
    broadcast_event(ctx, "command_error", %{op: op, reason: inspect(reason)})
  end

  defp project_id(ctx), do: ctx.assigns.project_id

  # --- JSON-safe 边界（壳层末端转换：结构化 tagged term → tuple→list） ---

  defp broadcast_check(ctx) do
    case Neumu.check(project_id(ctx)) do
      {:ok, result} -> broadcast_event(ctx, "check_result", sanitize_check(result))
      {:error, reason} -> broadcast_error(ctx, "check", reason)
    end
  end

  defp sanitize_check(%{entries: entries} = result) do
    %{result | entries: sanitize_reasons(entries)}
  end

  defp sanitize_reasons(entries) when is_list(entries) do
    Enum.map(entries, fn
      %{reason: reason} = entry -> %{entry | reason: deep_json_safe(reason)}
      entry -> entry
    end)
  end

  defp sanitize_jobs(jobs) do
    Enum.map(jobs, fn
      %{error: error} = job -> %{job | error: deep_json_safe(error)}
      job -> job
    end)
  end

  # facade 契约里 `reason`/`error` 保持结构化 tagged term（Elixir 机器可判）；
  # 推向浏览器前由壳层降为 JSON-safe 形态：tuple 递归转 list（标签即首元素），
  # 运行时对象转 inspect 字符串，其余原样。
  defp deep_json_safe(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&deep_json_safe/1)

  defp deep_json_safe(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, deep_json_safe(value)} end)

  defp deep_json_safe(list) when is_list(list), do: Enum.map(list, &deep_json_safe/1)

  defp deep_json_safe(term)
       when is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
       do: inspect(term)

  defp deep_json_safe(%_{} = struct), do: inspect(struct)
  defp deep_json_safe(term), do: term

  @impl true
  def terminate(_reason, ctx) do
    Neumu.unsubscribe(ctx.assigns.project_id)
    :ok
  end
end
