defmodule Equinox.Session do
  @moduledoc """
  管理项目运行状态及会话定位。
  """
  import Equinox.Session.Registry

  alias Equinox.Session.Server
  alias Equinox.Session.Storage

  def child_spec({session_id, opts}) do
    task_supervisor_name = Equinox.Session.task_sup(session_id)
    storage = build_storage(opts)

    [
      {OrchidSymbiont.Runtime,
       scope_id: session_id, strict_mode: Keyword.get(opts, :orchid_symbiont_strict, false)},
      {Task.Supervisor, name: task_supervisor_name},
      Server.child_spec(
        session_id: session_id,
        id: {:session_server, session_id},
        name: Equinox.Session.server(session_id),
        project: Keyword.get(opts, :project),
        storage: storage,
        task_supervisor: task_supervisor_name
      )
    ]
  end

  def resolve(session_id, registry \\ Equinox.Session.Registry) do
    case Registry.lookup(registry, server(session_id, :key)) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  def instance_sup(session_id), do: via(session_id, :instance_sup)
  def instance_sup(session_id, :key), do: key(session_id, :instance_sup)
  def task_sup(session_id), do: via(session_id, :task_sup)
  def server(session_id), do: via(session_id, :server)
  def server(session_id, :key), do: key(session_id, :server)

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
