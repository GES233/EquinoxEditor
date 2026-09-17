defmodule EquinoxWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [
        {:neumu, in_umbrella: true},
        {:phoenix, "~> 1.8.0"},
        {:bandit, "~> 1.8"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {EquinoxWeb.Application, []}]
  end
end
