defmodule EquinoxDomain.MixProject do
  use Mix.Project

  def project do
    [
      app: :equinox_domain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod
    ]
  end

  def application do
    []
  end
end
