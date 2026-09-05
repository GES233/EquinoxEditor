defmodule Neumu.RefClient do
  @moduledoc """
  瘦客户端参考实现——facade 契约（`docs/facade-protocol.md`）的活规范，
  也是未来 JS 前端的协议步骤规范。

  纪律只有三条：

  1. 客户端持有的是**镜像**：`snapshot` + `pin` 来自服务器投影，本地编辑
     （如卷帘上的拖拽预览）只是缓存，不许发明语义；
  2. 手势落笔才提交；编辑类回复 `{:ok, pin}` 后镜像失效，按事件
     （`project_changed`）或显式 `sync!/1` 重新拉取快照；
  3. pin 族手势（两阶段 mount）遇到 `{:error, {:stale_pin, _}}` 时
     重新 probe 后按最新镜像重放（`mount/3` 的 `with_retry`）。
  """

  alias Neumu.ProjectServer

  @type t :: %{
          project_id: Neume.RenderJob.project_id(),
          snapshot: map(),
          pin: Neumu.history_pin()
        }

  @doc "订阅并拉取初始快照。"
  @spec open(Neume.RenderJob.project_id()) :: {:ok, t()} | {:error, term()}
  def open(project_id) do
    if ProjectServer.whereis(project_id) == nil do
      {:error, {:unknown_project, project_id}}
    else
      :ok = Neumu.subscribe(project_id)
      {:ok, snapshot} = Neumu.snapshot(project_id)
      {:ok, %{project_id: project_id, snapshot: snapshot, pin: snapshot.history_pin}}
    end
  end

  @doc "重新拉取快照（收到 `project_changed` 后调用）。"
  @spec sync(t()) :: {:ok, t()}
  def sync(%{project_id: project_id} = client) do
    {:ok, snapshot} = Neumu.snapshot(project_id)
    {:ok, %{client | snapshot: snapshot, pin: snapshot.history_pin}}
  end

  @doc """
  提交一个编辑手势（`fun` 为零元函数，返回 facade 回复）。

  - `{:ok, pin}` 且 pin 前进 → 同步镜像，返回 `{:ok, client}`；
  - 无变化编辑（pin 不动）→ 镜像不变；
  - `{:error, {:stale_pin, _}}` → 先同步，返回 `{:stale, client}`，
    由调用方决定是否重放；
  - 其他 tagged error → 原样返回，镜像不变。
  """
  @spec dispatch(t(), (-> term())) :: {:ok, t()} | {:stale, t()} | {{:error, term()}, t()}
  def dispatch(client, fun) do
    case fun.() do
      {:ok, pin} when pin != client.pin ->
        {:ok, client} = sync(client)
        {:ok, client}

      {:ok, _pin} ->
        {:ok, client}

      {:error, {:stale_pin, _}} ->
        {:ok, client} = sync(client)
        {:stale, client}

      {:error, _} = error ->
        {error, client}
    end
  end

  @doc """
  两阶段 pin 挂载：`mount_fun` 收到 probe 结果并发起 mount；遇
  `stale_pin` 自动重新 probe 并重放一次（演示协议的重试约定；仍失败则
  原样返回错误）。
  """
  @spec mount(t(), term(), term(), (map() -> {:ok, term()} | {:error, term()})) ::
          {:ok, t()} | {{:error, term()}, t()}
  def mount(client, track_id, note_id, mount_fun) do
    {:ok, probe} = Neumu.probe_pin(client.project_id, track_id, note_id)

    case dispatch(client, fn -> mount_fun.(probe) end) do
      {:stale, client} ->
        {:ok, fresh} = Neumu.probe_pin(client.project_id, track_id, note_id)
        dispatch(client, fn -> mount_fun.(fresh) end)

      other ->
        other
    end
  end
end
