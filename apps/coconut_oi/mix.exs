defmodule CoconutOi.MixProject do
  use Mix.Project

  def project do
    [
      app: :coconut_oi,
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
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:coconut, in_umbrella: true},
      {:oi, "~> 0.8"},
      {:orchid_intervention, "~> 0.2.0"}
    ]
  end
end
