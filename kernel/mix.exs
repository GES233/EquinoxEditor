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
      deps: deps(),
      test_coverage: [
        ignore_modules: [
          ~r/.*Step.*/,
          ~r/Jason.Encoder.*/
        ]
      ]
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
      ## 领域模型
      {:equinox_domain, path: "../domain"},
      ## Orchid 生态
      {:orchid, "~> 0.6"},
      {:orchid_symbiont, "~> 0.2"},
      {:orchid_stratum, "~> 0.2"},
      {:orchid_intervention, "~> 0.1"},
      ## NIF
      # Rust? Zig?
      ## 序列化
      {:jason, "~> 1.2"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
