defmodule EquinoxUIShell.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EquinoxWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:equinox_ui_shell, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Equinox.PubSub},
      EquinoxUIShell.SessionHost,
      EquinoxWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: EquinoxUIShell.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    EquinoxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
