defmodule EquinoxAdapters.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # sidecar 进程注册表（按 model_root 去重）+ 托管 supervisor
      {Registry, keys: :unique, name: EquinoxAdapters.SidecarRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: EquinoxAdapters.SidecarSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EquinoxAdapters.Supervisor)
  end
end
