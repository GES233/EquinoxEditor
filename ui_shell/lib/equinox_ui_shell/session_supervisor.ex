defmodule EquinoxUiShell.SessionSupervisor do
  @moduledoc false

  use Supervisor

  alias Equinox.Session
  alias Equinox.Session.Server
  alias Equinox.Session.Storage

  def start_link({session_id, opts}) do
    Supervisor.start_link(__MODULE__, {session_id, opts}, name: Session.instance_sup(session_id))
  end

  @impl true
  def init({session_id, opts}) do
    task_supervisor_name = Session.task_sup(session_id)
    storage = build_storage(opts)

    children = [
      {OrchidSymbiont.Runtime,
       scope_id: session_id, strict_mode: Keyword.get(opts, :orchid_symbiont_strict, false)},
      {Task.Supervisor, name: task_supervisor_name},
      Server.child_spec(
        session_id: session_id,
        id: {:session_server, session_id},
        name: Session.server(session_id),
        project: Keyword.get(opts, :project),
        storage: storage,
        task_supervisor: task_supervisor_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp build_storage(opts) do
    cond do
      Keyword.has_key?(opts, :storage) ->
        Keyword.get(opts, :storage)

      Keyword.get(opts, :enable_cache, true) ->
        Storage.new()

      true ->
        nil
    end
  end
end
