defmodule EquinoxUiShell.SessionHost do
  @moduledoc false

  use DynamicSupervisor

  alias Equinox.Session

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(session_id, opts \\ []) do
    case Registry.lookup(Equinox.Session.Registry, Session.instance_sup(session_id, :key)) do
      [{pid, _}] ->
        {:error, {:already_started, pid}}

      [] ->
        session_supervisor_spec = %{
          id: session_id,
          start: {EquinoxUiShell.SessionSupervisor, :start_link, [{session_id, opts}]}
        }

        DynamicSupervisor.start_child(__MODULE__, session_supervisor_spec)
    end
  end

  def stop_session(session_id) do
    case Registry.lookup(Equinox.Session.Registry, Session.instance_sup(session_id, :key)) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :session_not_found}
    end
  end
end
