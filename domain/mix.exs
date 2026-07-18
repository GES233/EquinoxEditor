defmodule EquinoxDomain.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_domain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: [precommit: ["compile --warnings-as-errors", "format", "test"]]
    ]
  end

  defp deps do
    [
      {:zongzi, git: "https://github.com/SynapticStrings/Zongzi.git", branch: "main"}
    ]
  end

  def application, do: []

  def cli, do: [preferred_envs: [precommit: :test]]
end
