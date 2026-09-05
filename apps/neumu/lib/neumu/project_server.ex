defmodule Neumu.ProjectServer do
  @moduledoc """
  一个打开工程对应一个 `ProjectServer`。

  持有该工程唯一的 `Neume.MultiTrack` 值（`Coconut.Session` 保持纯值，
  不做 OTP 进程化）。渲染任务经 `Neumu.RenderSupervisor` 在 GenServer 之外
  执行，渲染期间本进程仍可响应查询；进程关闭时在途渲染任务一并终止，
  不泄漏到应用级 `RenderSupervisor`。

  公开事件严格只有三种 payload（见 `Neume.Event`），由订阅机制派发：

  - `{:project_changed, project_id, history_pin}`：编辑命令实际产生
    History 边（含 undo/redo 移动 cursor）后派发一次；无变化的编辑
    （如无改动的 globals 合并）不派发。
  - `{:render_changed, job_id, status}`
  - `{:artifact_ready, job_id, artifact_id, source_pin}`

  所有编辑都经 `{:edit, command}` 在本进程内串行应用到唯一的
  `Neume.MultiTrack` 值上；命令集是封闭分派（见 `apply_edit/2`），
  调用方不能注入任意函数。查询（snapshot/history_pin/job）是只读的，
  不产生 History 边。
  """

  use GenServer

  alias Coconut.Edit.History
  alias Neume.{Event, RenderJob}

  @type state :: %{
          project_id: RenderJob.project_id(),
          multi_track: Neume.MultiTrack.t(),
          renderer: (Neume.MultiTrack.t() -> renderer_result()),
          render_supervisor: Supervisor.supervisor(),
          artifact_store: GenServer.server(),
          event_registry: Registry.registry(),
          jobs: %{RenderJob.id() => RenderJob.t()},
          artifacts: %{RenderJob.id() => Neumu.ArtifactStore.artifact_id()},
          tasks: %{reference() => render_task()}
        }

  @type render_task :: %{
          job_id: RenderJob.id(),
          snapshot: Neume.MultiTrack.t(),
          pid: pid()
        }

  @type renderer_result ::
          {:ok, RenderJob.artifact()}
          | {:ok, Neume.MultiTrack.t(), RenderJob.artifact()}
          | {:error, term()}

  # --- 进程生命周期 ---

  @doc """
  在 `Neumu.ProjectSupervisor` 下启动一个工程进程。

  选项：

  - `:renderer` — 渲染函数，默认走 `Neume.MultiTrack.render/1` 的生产路径；
  - `:render_supervisor` / `:artifact_store` / `:event_registry` — 依赖注入，
    默认使用应用级命名进程。
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: via(project_id))
  end

  @doc "按 `project_id` 定位工程进程的 via tuple。"
  @spec via(RenderJob.project_id()) :: {:via, Registry, {Registry.registry(), term()}}
  def via(project_id), do: {:via, Registry, {Neumu.ProjectRegistry, project_id}}

  @doc "按 `project_id` 查找工程进程 pid；未打开（或已终止待清理）时返回 `nil`。"
  @spec whereis(RenderJob.project_id()) :: pid() | nil
  def whereis(project_id) do
    case Registry.lookup(Neumu.ProjectRegistry, project_id) do
      # Registry 经监视器异步清理，刚终止的进程可能仍在册，需过滤死进程。
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "子进程规格；由 `Neumu.open_project/3` 经 DynamicSupervisor 启动。"
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :project_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # --- GenServer 回调 ---

  @impl true
  def init(opts) do
    # 需要 trap_exit 才能在监督者终止本进程时执行 terminate/2 清理在途渲染。
    Process.flag(:trap_exit, true)

    case Keyword.fetch!(opts, :multi_track) do
      %Neume.MultiTrack{} = multi_track ->
        {:ok,
         %{
           project_id: Keyword.fetch!(opts, :project_id),
           multi_track: multi_track,
           renderer: Keyword.get(opts, :renderer, &default_renderer/1),
           render_supervisor: Keyword.get(opts, :render_supervisor, Neumu.RenderSupervisor),
           artifact_store: Keyword.get(opts, :artifact_store, Neumu.ArtifactStore),
           event_registry: Keyword.get(opts, :event_registry, Neumu.EventRegistry),
           jobs: %{},
           artifacts: %{},
           tasks: %{}
         }}

      other ->
        {:stop, {:invalid_multi_track, other}}
    end
  end

  @impl true
  def handle_call({:submit_render, opts}, _from, state) do
    job_id = Keyword.get(opts, :job_id, new_job_id())

    if Map.has_key?(state.jobs, job_id) do
      # 已存在的 job_id（在途或终态）一律拒绝，不得覆盖权威 job。
      {:reply, {:error, {:job_already_exists, job_id}}, state}
    else
      with {:ok, source_pin, render_target} <-
             render_target(state.multi_track, Keyword.get(opts, :pin)),
           {:ok, job} <- RenderJob.new(job_id, state.project_id, source_pin),
           {:ok, job} <- RenderJob.start(job) do
        renderer = Keyword.get(opts, :renderer, state.renderer)

        task =
          Task.Supervisor.async_nolink(state.render_supervisor, fn -> renderer.(render_target) end)

        state = %{
          state
          | jobs: Map.put(state.jobs, job_id, job),
            tasks:
              Map.put(state.tasks, task.ref, %{
                job_id: job_id,
                snapshot: render_target,
                pid: task.pid
              })
        }

        broadcast(state, Event.render_changed(job))
        {:reply, {:ok, job}, state}
      else
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  # 工程当前可用的声库条目（plain data 投影）；只读查询。
  def handle_call(:list_voicebanks, _from, state) do
    entries =
      state.multi_track.voicebank_registry
      |> Neume.Voicebank.Registry.list()
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          name: entry.name,
          mode: entry.mode,
          engine: entry.signature.engine,
          digest: entry.signature.digest
        }
      end)

    {:reply, {:ok, entries}, state}
  end

  # 渲染任务枚举（含 artifact_id 与 source_pin），供"按 pin 试听对比"。
  def handle_call(:list_render_jobs, _from, state) do
    jobs =
      state.jobs
      |> Enum.sort_by(fn {job_id, _job} -> job_id end)
      |> Enum.map(fn {job_id, job} ->
        %{
          job_id: job_id,
          source_pin: job.source_pin,
          status: job.status,
          artifact_id: Map.get(state.artifacts, job_id),
          error: job.error && Neumu.CheckReport.project_error(job.error)
        }
      end)

    {:reply, {:ok, jobs}, state}
  end

  def handle_call({:render_job, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, {:error, {:job_not_found, job_id}}, state}
    end
  end

  def handle_call(:history_pin, _from, state) do
    {:reply, {:ok, current_pin(state.multi_track)}, state}
  end

  # UI 只读快照：纯投影，不产生 History 边、不派发事件。
  def handle_call(:snapshot, _from, state) do
    snapshot = Neumu.ProjectSnapshot.build(state.multi_track, state.project_id)
    {:reply, {:ok, snapshot}, state}
  end

  # 保存是只读快照的持久化，不改变工程状态，不派发事件。
  def handle_call({:save, path}, _from, state) do
    case Neume.MultiTrack.save(state.multi_track, path) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # 编辑命令串行落账：只有实际产生 History 边（pin 变化）的成功编辑才
  # 派发一次 project_changed；失败编辑不改状态、不派发事件。
  def handle_call({:edit, command}, _from, state) do
    old_pin = current_pin(state.multi_track)

    case apply_edit(state.multi_track, command) do
      {:ok, multi_track} ->
        {state, new_pin} = commit_edit(state, multi_track, old_pin)
        {:reply, {:ok, new_pin}, state}

      {:ok, multi_track, extra} ->
        {state, new_pin} = commit_edit(state, multi_track, old_pin)
        {:reply, {:ok, new_pin, extra}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # 两阶段 pin 挂载的 probe 上下文：把当前权威值与 pin 交给调用方，probe
  # （G2P + 组展开，真声库要调 worker）在本进程之外的调用方进程执行，
  # 期间本进程仍可响应编辑与查询。mount 携 probe 的 pin 回来校验。
  def handle_call(:probe_context, _from, state) do
    {:reply, {:ok, state.multi_track, current_pin(state.multi_track)}, state}
  end

  # 渲染任务正常返回。
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{job_id: job_id, snapshot: snapshot}, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: tasks}
        {:noreply, settle_render(state, job_id, snapshot, result)}
    end
  end

  # 渲染任务崩溃（async_nolink 下以 DOWN 送达）。
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {%{job_id: job_id}, tasks} ->
        state = %{state | tasks: tasks}
        {:noreply, fail_render(state, job_id, {:render_crashed, reason})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # 进程关闭（含 DynamicSupervisor 终止）时杀掉仍在运行的渲染任务，
  # 避免 ProjectServer 消失后 renderer 继续泄漏运行。
  @impl true
  def terminate(_reason, state) do
    for {_ref, %{pid: pid}} <- state.tasks do
      Task.Supervisor.terminate_child(state.render_supervisor, pid)
    end

    :ok
  end

  # --- 渲染结果落账 ---

  defp settle_render(state, job_id, snapshot, result) do
    case result do
      {:ok, %Neume.MultiTrack{} = refreshed, artifact} ->
        # 渲染期间没有编辑时才采纳带回的 runtime（缓存等），避免覆盖新编辑。
        state = maybe_adopt_runtime(state, snapshot, refreshed)
        complete_render(state, job_id, artifact)

      {:ok, artifact} ->
        complete_render(state, job_id, artifact)

      {:error, reason} ->
        fail_render(state, job_id, reason)

      other ->
        fail_render(state, job_id, {:unexpected_render_result, other})
    end
  end

  defp maybe_adopt_runtime(state, snapshot, refreshed) do
    if state.multi_track == snapshot, do: %{state | multi_track: refreshed}, else: state
  end

  defp complete_render(state, job_id, artifact) do
    with {:ok, artifact_id} <- Neumu.ArtifactStore.put(state.artifact_store, artifact),
         {:ok, job} <- RenderJob.complete(Map.fetch!(state.jobs, job_id), artifact) do
      state = %{
        state
        | jobs: Map.put(state.jobs, job_id, job),
          artifacts: Map.put(state.artifacts, job_id, artifact_id)
      }

      broadcast(state, Event.render_changed(job))
      broadcast(state, Event.artifact_ready(job, artifact_id))
      state
    else
      {:error, reason} -> fail_render(state, job_id, reason)
    end
  end

  defp fail_render(state, job_id, reason) do
    case RenderJob.fail(Map.fetch!(state.jobs, job_id), reason) do
      {:ok, job} ->
        state = %{state | jobs: Map.put(state.jobs, job_id, job)}
        broadcast(state, Event.render_changed(job))
        state

      {:error, _} ->
        state
    end
  end

  defp broadcast(state, event) do
    Registry.dispatch(state.event_registry, state.project_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, event)
    end)

    :ok
  end

  # 编辑落账：更新权威值；pin 变化时派发一次 project_changed。
  defp commit_edit(state, multi_track, old_pin) do
    state = %{state | multi_track: multi_track}
    new_pin = current_pin(multi_track)

    if new_pin != old_pin do
      broadcast(state, Event.project_changed(state.project_id, new_pin))
    end

    {state, new_pin}
  end

  defp current_pin(multi_track), do: History.current(multi_track.session.history).node_id

  # 渲染目标：默认当前 cursor；`pin:` 物化对应历史状态（被 squash 或
  # 不存在的 pin 返回 tagged error）。`job.source_pin` 恒等于实际渲染的 pin。
  defp render_target(multi_track, nil) do
    {:ok, current_pin(multi_track), multi_track}
  end

  defp render_target(multi_track, pin) when is_integer(pin) and pin >= 0 do
    case Neume.MultiTrack.at_pin(multi_track, pin) do
      {:ok, target} -> {:ok, pin, target}
      {:error, _} = error -> error
    end
  end

  defp render_target(_multi_track, pin), do: {:error, {:invalid_source_pin, pin}}

  # --- 编辑命令的封闭分派 ---

  defp apply_edit(multi_track, {:insert_note, track_id, note_id, after_id, span, attrs}) do
    Neume.MultiTrack.insert_note(multi_track, track_id, note_id, after_id, span, attrs)
  end

  defp apply_edit(multi_track, {:edit_note, track_id, note_id, changes}) do
    Neume.MultiTrack.edit_note(multi_track, track_id, note_id, changes)
  end

  defp apply_edit(multi_track, {:move_note, track_id, note_id, after_id, span}) do
    Neume.MultiTrack.drag_note(multi_track, track_id, note_id, after_id, span)
  end

  defp apply_edit(multi_track, {:delete_note, track_id, note_id}) do
    Neume.MultiTrack.delete_note(multi_track, track_id, note_id)
  end

  defp apply_edit(multi_track, {:split_note, track_id, note_id, at_tick, new_id}) do
    Neume.MultiTrack.split_note(multi_track, track_id, note_id, at_tick, new_id)
  end

  defp apply_edit(multi_track, {:trim_note, track_id, note_id, new_span}) do
    Neume.MultiTrack.trim_note(multi_track, track_id, note_id, new_span)
  end

  defp apply_edit(multi_track, {:merge_notes, track_id, note_ids}) do
    Neume.MultiTrack.merge_notes(multi_track, track_id, note_ids)
  end

  defp apply_edit(
         multi_track,
         {:drag_note_across_tracks, from_track, note_id, to_track, new_id, after_id, span}
       ) do
    Neume.MultiTrack.drag_note_across_tracks(
      multi_track,
      from_track,
      note_id,
      to_track,
      new_id,
      after_id,
      span
    )
  end

  defp apply_edit(multi_track, {:add_track, track_id, voicebank_id, attrs}) do
    with {:ok, entry} <- fetch_voicebank(multi_track, voicebank_id) do
      Neume.MultiTrack.add_vocal_track(multi_track, track_id, entry, attrs)
    end
  end

  defp apply_edit(multi_track, {:remove_track, track_id}) do
    Neume.MultiTrack.remove_track(multi_track, track_id)
  end

  defp apply_edit(multi_track, {:rename_track, track_id, name}) do
    Neume.MultiTrack.rename_track(multi_track, track_id, name)
  end

  defp apply_edit(multi_track, {:set_time_sigs, events}) do
    Neume.MultiTrack.set_time_sigs(multi_track, events)
  end

  defp apply_edit(multi_track, {:rebind_voicebank, track_id, voicebank_id}) do
    with {:ok, entry} <- fetch_voicebank(multi_track, voicebank_id) do
      Neume.MultiTrack.put_voicebank(multi_track, track_id, entry)
    end
  end

  defp apply_edit(multi_track, {:update_mix, track_id, attrs}) do
    Neume.MultiTrack.put_mix(multi_track, track_id, attrs)
  end

  defp apply_edit(multi_track, {:update_globals, track_id, knobs}) do
    Neume.MultiTrack.update_globals(multi_track, track_id, knobs)
  end

  # 两阶段 pin 挂载：probe 令牌绑定 track/note 且携底料与 pin；pin 校验
  # 由 History 的 stale-write 机制完成（probe 期间被编辑 → stale_pin）。
  defp apply_edit(multi_track, {:mount_pin, track_id, note_id, channel, payload, probe}) do
    with {:ok, opts} <- mount_probe_opts(probe, track_id, note_id) do
      case {channel, payload} do
        {:pitch, {:points, points}} ->
          Neume.MultiTrack.mount_pitch(multi_track, track_id, note_id, points, opts)

        {:pitch, {:curve, curve}} ->
          Neume.MultiTrack.mount_pitch_curve(multi_track, track_id, note_id, curve, opts)

        {:duration, {:durations, durations}} ->
          Neume.MultiTrack.mount_phoneme_duration(multi_track, track_id, note_id, durations, opts)
      end
    end
  end

  defp apply_edit(multi_track, {:repatch, track_id, patch_ids}) do
    Neume.MultiTrack.repatch(multi_track, track_id, patch_ids)
  end

  defp apply_edit(multi_track, {:unmount_pin, track_id, note_id, channel}) do
    Neume.MultiTrack.unmount_pin(multi_track, track_id, note_id, channel)
  end

  defp apply_edit(multi_track, :undo), do: Neume.MultiTrack.undo(multi_track)
  defp apply_edit(multi_track, :redo), do: Neume.MultiTrack.redo(multi_track)

  defp apply_edit(_multi_track, other), do: {:error, {:unknown_edit_command, other}}

  # probe 令牌必须是 `Neumu.probe_pin/3` 的原样返回：绑定同一 track/note，
  # 底料是物化的输入事实 map，pin 是物化时刻的 History cursor。
  defp mount_probe_opts(
         %{track_id: track_id, note_id: note_id, pin: pin, base: base},
         track_id,
         note_id
       )
       when is_integer(pin) and is_map(base),
       do: {:ok, [base: base, pin: pin]}

  defp mount_probe_opts(probe, track_id, note_id),
    do: {:error, {:invalid_pin_probe, track_id, note_id, probe}}

  defp fetch_voicebank(multi_track, voicebank_id) do
    Neume.Voicebank.Registry.fetch(multi_track.voicebank_registry, voicebank_id)
  end

  # 生产默认渲染路径：现有 Neume.MultiTrack render API。
  defp default_renderer(%Neume.MultiTrack{} = multi_track) do
    case Neume.MultiTrack.render(multi_track) do
      {:ok, refreshed, artifact} -> {:ok, refreshed, artifact}
      {:error, _} = error -> error
    end
  end

  defp new_job_id, do: System.unique_integer([:positive, :monotonic])
end
