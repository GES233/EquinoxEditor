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

  # 提供 Score 基础类型 / Edit.Workspace / Render.Channel / Pickle 的
  # 引擎无关编辑器内核 coconut 是唯一的允许依赖；
  # tamale（rebase 内核）由 coconut 传递引入，
  # override 到本地 path 便于联动调试。
  defp deps do
    [
      {:coconut, path: "../../coconut"},
      {:tamale, path: "../../tamale", override: true}
    ]
  end

  def application, do: []
  def cli, do: [preferred_envs: [precommit: :test]]
end
