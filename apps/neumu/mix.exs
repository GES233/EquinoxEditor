defmodule Neumu.MixProject do
  use Mix.Project

  def project do
    [
      app: :neumu,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Neumu.Application, []}
    ]
  end

  defp deps do
    [
      {:coconut, in_umbrella: true},
      {:neume, in_umbrella: true}
    ]
  end
end
