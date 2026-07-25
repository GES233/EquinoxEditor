defmodule EquinoxDomain.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_domain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]]
    ]
  end

  # zongzi 是唯一的允许依赖：同为零依赖纯函数内核库，
  # 提供 Timeline / Anchor / Windowing / Intervention / Score 基础类型真源。
  defp deps do
    [
      {:zongzi, path: "../../zongzi"}
    ]
  end

  def application, do: []
  def cli, do: [preferred_envs: [precommit: :test]]
end
