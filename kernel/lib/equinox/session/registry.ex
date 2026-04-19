defmodule Equinox.Session.Registry do
  @moduledoc false

  def child_spec(_init_arg) do
    [keys: :unique, name: __MODULE__]
    |> Registry.child_spec()
    |> Supervisor.child_spec(id: __MODULE__)
  end

  def via(session_id, role \\ nil), do: {:via, Registry, {__MODULE__, key(session_id, role)}}
  def key(session_id, nil), do: session_id
  def key(session_id, role), do: {session_id, role}
end
