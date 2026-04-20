defmodule EquinoxUiShell.SessionSupervisor do
  @moduledoc false

  use Supervisor

  alias Equinox.Session

  def start_link({session_id, opts}) do
    Supervisor.start_link(__MODULE__, {session_id, opts}, name: Session.instance_sup(session_id))
  end

  @impl true
  def init({session_id, opts}) do
    Supervisor.init(Session.child_spec({session_id, opts}), strategy: :one_for_all)
  end
end
