defmodule EquinoxWeb.UserSocket do
  use Phoenix.Socket

  channel("project:*", EquinoxWeb.ProjectChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(EquinoxWeb.Endpoint, "project", token, max_age: 86_400) do
      {:ok, project_id} -> {:ok, assign(socket, :project_id, project_id)}
      {:error, _} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
