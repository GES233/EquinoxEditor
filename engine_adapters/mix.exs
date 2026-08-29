defmodule EquinoxEngineAdapters.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_engine_adapters,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # 引擎实现属 userland（kernel 只定义 EngineAdapter behaviour 的红线不破）：
  # 本项目是仓库内的参考实现，依赖 domain（channel 模块 / RenderRequest）
  # 与 kernel（Voicebank / ChannelSpecs / CurveRaster），不被任何层反向依赖。
  defp deps do
    [
      {:equinox_domain, path: "../domain"},
      {:equinox_kernel, path: "../kernel"},
      {:coconut, path: "../../coconut"},
      {:tamale, "~> 0.1"},
      {:yaml_elixir, "~> 2.9"},
      {:jason, "~> 1.2"}
    ]
  end

  def application do
    [mod: {EquinoxAdapters.Application, []}, extra_applications: [:logger]]
  end

  def cli, do: [preferred_envs: [precommit: :test]]
end
