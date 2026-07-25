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
      # 保持相对路径的原因是一旦发现 zongzi 问题后便于修改
      # 待经过验证后用 hex version
      # {:zongzi, "~> 0.3"}
    ]
  end

  def application, do: []
  def cli, do: [preferred_envs: [precommit: :test]]
end
