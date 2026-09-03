defmodule Neume.MixProject do
  use Mix.Project

  def project do
    [
      app: :neume,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:coconut, "~> 0.2.0", path: "../../../coconut", override: true},
      {:coconut_oi, "~> 0.1.0", path: "../../../coconut_oi"},
      # coconut_oi 0.1 仍声明 Oi 0.7；Neume 统一使用已验证兼容的本地 Oi 0.8。
      {:oi, "~> 0.8.0", path: "../../../ElixirOrchid/oi", override: true}
    ]
  end
end
