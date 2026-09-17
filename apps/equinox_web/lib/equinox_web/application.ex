defmodule EquinoxWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: EquinoxWeb.PubSub},
      EquinoxWeb.Endpoint
    ]

    with {:ok, pid} <- Supervisor.start_link(children, strategy: :one_for_one),
         :ok <- maybe_open_demo() do
      {:ok, pid}
    end
  end

  defp maybe_open_demo do
    if Application.get_env(:equinox_web, :demo, false) do
      EquinoxWeb.Demo.open()
    else
      :ok
    end
  end
end
