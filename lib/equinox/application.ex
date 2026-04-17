defmodule Equinox.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EquinoxWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:equinox, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Equinox.PubSub},
      Equinox.Session.Registry,
      {Task.Supervisor, name: Equinox.RenderTaskSupervisor},
      {DynamicSupervisor, name: Equinox.Session.DynamicSupervisor, strategy: :one_for_one},
      Equinox.Kernel.StepRegistry,
      EquinoxWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Equinox.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EquinoxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
