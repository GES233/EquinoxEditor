defmodule Neumu do
  @moduledoc """
  Neumu application service：Neume 引擎之上的工程会话与渲染任务入口。

  每个打开的工程由一个 `Neumu.ProjectServer` 持有唯一的
  `Neume.MultiTrack` 值；渲染经 `Neumu.RenderSupervisor` 异步执行，
  制品存入 `Neumu.ArtifactStore` 并分配不透明 `artifact_id`。

  订阅者只收到三种事件 payload（见 `Neume.Event`），事件只携带重新查询
  权威状态所需的 identity。
  """

  alias Neume.RenderJob

  @type artifact_id :: Neumu.ArtifactStore.artifact_id()

  @doc """
  打开工程并启动对应的 `Neumu.ProjectServer`。

  `multi_track` 必须是已经 `Neume.MultiTrack.open/2` 好的工程值；本服务
  不复制 Neume 的打开/声库解析语义。`:renderer` 等选项透传给
  `Neumu.ProjectServer.start_link/1`。`project_id` 为 `nil` 时返回
  `{:error, {:invalid_project_id, nil}}`。
  """
  @spec open_project(RenderJob.project_id(), Neume.MultiTrack.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def open_project(project_id, multi_track, opts \\ [])

  def open_project(nil, %Neume.MultiTrack{}, _opts) do
    {:error, {:invalid_project_id, nil}}
  end

  def open_project(project_id, %Neume.MultiTrack{} = multi_track, opts) do
    opts = opts |> Keyword.put(:project_id, project_id) |> Keyword.put(:multi_track, multi_track)

    case DynamicSupervisor.start_child(Neumu.ProjectSupervisor, {Neumu.ProjectServer, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, {:project_already_open, project_id}}

      {:error, _} = error ->
        error
    end
  end

  @doc "关闭工程并终止其 ProjectServer；未打开时返回 tagged error。"
  @spec close_project(RenderJob.project_id()) :: :ok | {:error, term()}
  def close_project(project_id) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> DynamicSupervisor.terminate_child(Neumu.ProjectSupervisor, pid)
    end
  end

  @doc """
  提交一次渲染。

  捕获当前 Coconut History cursor node id 作为 `source_pin` 创建
  `Neume.RenderJob`，任务在 ProjectServer 之外执行。返回处于 `:running`
  状态的权威 job。选项：

  - `:renderer` — 覆盖本次渲染的渲染函数（测试注入用）；
  - `:job_id` — 指定任务 id，默认生成唯一整数；该工程内已存在同名
    job（在途或终态）时返回 `{:error, {:job_already_exists, job_id}}`，
    不覆盖权威 job。
  """
  @spec submit_render(RenderJob.project_id(), keyword()) ::
          {:ok, RenderJob.t()} | {:error, term()}
  def submit_render(project_id, opts \\ []) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> GenServer.call(pid, {:submit_render, opts})
    end
  end

  @doc """
  按 `job_id` 查询该工程内的权威 job 状态。

  未找到时返回 `{:error, {:job_not_found, job_id}}`。
  """
  @spec render_job(RenderJob.project_id(), RenderJob.id()) ::
          {:ok, RenderJob.t()} | {:error, term()}
  def render_job(project_id, job_id) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> GenServer.call(pid, {:render_job, job_id})
    end
  end

  @doc "查询工程当前的 History cursor node id（版本钉）。"
  @spec history_pin(RenderJob.project_id()) :: {:ok, non_neg_integer()} | {:error, term()}
  def history_pin(project_id) do
    case Neumu.ProjectServer.whereis(project_id) do
      nil -> {:error, {:unknown_project, project_id}}
      pid -> GenServer.call(pid, :history_pin)
    end
  end

  @doc "按 `artifact_id` 查询运行时制品。"
  @spec artifact(artifact_id()) ::
          {:ok, RenderJob.artifact()} | {:error, Neumu.ArtifactStore.not_found()}
  def artifact(artifact_id), do: Neumu.ArtifactStore.fetch(artifact_id)

  @doc """
  订阅工程事件；当前进程将收到该工程的三种事件 payload。

  订阅幂等：同一进程重复订阅只登记一次，每个事件只投递一次。
  工程未打开时也允许订阅，事件只在工程存活期间派发。
  """
  @spec subscribe(RenderJob.project_id()) :: :ok
  def subscribe(project_id) do
    unless subscribed?(project_id) do
      {:ok, _} = Registry.register(Neumu.EventRegistry, project_id, [])
    end

    :ok
  end

  # 当前进程是否已订阅该工程。
  defp subscribed?(project_id) do
    Neumu.EventRegistry
    |> Registry.lookup(project_id)
    |> Enum.any?(fn {pid, _value} -> pid == self() end)
  end

  @doc "退订工程事件。"
  @spec unsubscribe(RenderJob.project_id()) :: :ok
  def unsubscribe(project_id) do
    :ok = Registry.unregister(Neumu.EventRegistry, project_id)
    :ok
  end
end
