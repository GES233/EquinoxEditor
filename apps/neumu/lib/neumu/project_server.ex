defmodule Neumu.ProjectServer do
  @moduledoc """
  一个打开工程对应一个 `ProjectServer`。

  持有该工程唯一的 `Neume.MultiTrack` 值（`Coconut.Session` 保持纯值，
  不做 OTP 进程化）。渲染任务经 `Neumu.RenderSupervisor` 在 GenServer 之外
  执行，渲染期间本进程仍可响应查询；进程关闭时在途渲染任务一并终止，
  不泄漏到应用级 `RenderSupervisor`。

  公开事件严格只有三种 payload（见 `Neume.Event`），由订阅机制派发：

  - `{:project_changed, project_id, history_pin}`（本阶段尚无编辑 facade，
    暂不发送）
  - `{:render_changed, job_id, status}`
  - `{:artifact_ready, job_id, artifact_id, source_pin}`
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
           tasks: %{}
         }}

      other ->
        {:stop, {:invalid_multi_track, other}}
    end
  end

  @impl true
  def handle_call({:submit_render, opts}, _from, state) do
    pin = History.current(state.multi_track.session.history).node_id
    job_id = Keyword.get(opts, :job_id, new_job_id())

    if Map.has_key?(state.jobs, job_id) do
      # 已存在的 job_id（在途或终态）一律拒绝，不得覆盖权威 job。
      {:reply, {:error, {:job_already_exists, job_id}}, state}
    else
      with {:ok, job} <- RenderJob.new(job_id, state.project_id, pin),
           {:ok, job} <- RenderJob.start(job) do
        snapshot = state.multi_track
        renderer = Keyword.get(opts, :renderer, state.renderer)

        task =
          Task.Supervisor.async_nolink(state.render_supervisor, fn -> renderer.(snapshot) end)

        state = %{
          state
          | jobs: Map.put(state.jobs, job_id, job),
            tasks:
              Map.put(state.tasks, task.ref, %{job_id: job_id, snapshot: snapshot, pid: task.pid})
        }

        broadcast(state, Event.render_changed(job))
        {:reply, {:ok, job}, state}
      else
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:render_job, job_id}, _from, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :error -> {:reply, {:error, {:job_not_found, job_id}}, state}
    end
  end

  def handle_call(:history_pin, _from, state) do
    {:reply, {:ok, History.current(state.multi_track.session.history).node_id}, state}
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
      state = %{state | jobs: Map.put(state.jobs, job_id, job)}
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

  # 生产默认渲染路径：现有 Neume.MultiTrack render API。
  defp default_renderer(%Neume.MultiTrack{} = multi_track) do
    case Neume.MultiTrack.render(multi_track) do
      {:ok, refreshed, artifact} -> {:ok, refreshed, artifact}
      {:error, _} = error -> error
    end
  end

  defp new_job_id, do: System.unique_integer([:positive, :monotonic])
end
