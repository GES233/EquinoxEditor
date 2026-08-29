defmodule EquinoxRepo.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      config_path: "config/config.exs",
      version: "0.1.0",
      deps: [
        {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
