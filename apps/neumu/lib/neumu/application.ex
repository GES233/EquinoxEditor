defmodule Neumu.Application do
  @moduledoc """
  Neumu OTP 应用：工程会话运行时的监督树根。

  子进程职责：

  - `Neumu.ProjectRegistry` — 按 `project_id` 定位唯一的
    `Neumu.ProjectServer`；
  - `Neumu.EventRegistry` — 按 `project_id` 的重复键注册事件订阅进程；
  - `Neumu.RenderSupervisor` — 渲染任务的 `Task.Supervisor`，渲染在
    ProjectServer 之外执行，不阻塞 GenServer；
  - `Neumu.ArtifactStore` — 运行时制品存储，分配不透明 `artifact_id`；
  - `Neumu.ProjectSupervisor` — 打开工程的 `DynamicSupervisor`。
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Neumu.ProjectRegistry},
      {Registry, keys: :duplicate, name: Neumu.EventRegistry},
      {Task.Supervisor, name: Neumu.RenderSupervisor},
      Neumu.ArtifactStore,
      {DynamicSupervisor, strategy: :one_for_one, name: Neumu.ProjectSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Neumu.Supervisor)
  end
end
