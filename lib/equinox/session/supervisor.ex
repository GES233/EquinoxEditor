defmodule Equinox.Session.Supervisor do
  @moduledoc false
  use Supervisor
  alias Equinox.Session

  def start_link(session_id, opts) do
    Supervisor.start_link(__MODULE__, {session_id, opts}, name: Session.instance_sup(session_id))
  end

  @impl true
  def init({session_id, opts}) do
    children = [
      {OrchidSymbiont.Runtime,
       scope_id: session_id, strict_mode: Keyword.get(opts, :orchid_symbiont_strict, false)},
      {Task.Supervisor, name: Session.task_sup(session_id)},
      {Equinox.Session.Server, Keyword.put(opts, :session_id, session_id)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
