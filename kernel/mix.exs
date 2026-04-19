defmodule EquinoxKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_kernel,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Equinox.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:orchid, "~> 0.6.1"},
      {:orchid_symbiont, "~> 0.2.1"},
      {:orchid_stratum, "~> 0.2.0"},
      {:orchid_intervention, "~> 0.1.0"},
      {:jason, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
