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

    opts = [strategy: :one_for_one, name: Equinox.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register built-in steps
    register_builtin_steps()

    result
  end

  defp register_builtin_steps do
    alias Equinox.Kernel.StepRegistry
    
    # Synth nodes
    StepRegistry.register(:phonemizer, %{
      module: Equinox.Steps.Phonemizer,
      inputs: [:notes],
      outputs: [:linguistic],
      options: []
    })

    StepRegistry.register(:acoustic_model, %{
      module: Equinox.Steps.AcousticModel,
      inputs: [:notes, :linguistic],
      outputs: [:mel],
      options: []
    })

    StepRegistry.register(:vocoder, %{
      module: Equinox.Steps.Vocoder,
      inputs: [:mel],
      outputs: [:audio],
      options: []
    })

    # Arranger nodes
    StepRegistry.register(:track_input, %{
      module: Equinox.Steps.TrackInput,
      inputs: [:audio],
      outputs: [:track_out],
      options: [offset_tick: 0, volume: 1.0]
    })

    StepRegistry.register(:mixer, %{
      module: Equinox.Steps.Mixer,
      inputs: [:tracks], # 可以接受多个输入，Orchid 支持 List
      outputs: [:mixed],
      options: []
    })

    StepRegistry.register(:master_output, %{
      module: Equinox.Steps.Output,
      inputs: [:mixed],
      outputs: [:master_out],
      options: []
    })
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EquinoxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
