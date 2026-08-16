defmodule Equinox.Session do
  @moduledoc """
  管理项目运行状态及会话定位。

  会话基础设施（symbiont scope / Task.Supervisor / stratum storage）
  由 `Oi.Runtime.Session` 托管；本模块只保留 Server 的组装与命名门面。
  """
  import Equinox.Session.Registry

  alias Equinox.Session.Server

  def child_spec({session_id, opts}) do
    [
      Server.child_spec(
        session_id: session_id,
        id: {:session_server, session_id},
        name: Equinox.Session.server(session_id),
        project: Keyword.get(opts, :project),
        engines: Keyword.get(opts, :engines, %{}),
        default_engine: Keyword.get(opts, :default_engine),
        orchid_symbiont_strict: Keyword.get(opts, :orchid_symbiont_strict, false)
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
  def task_sup(session_id), do: Oi.Runtime.Session.tasks_tuple(session_id)
  def server(session_id), do: via(session_id, :server)
  def server(session_id, :key), do: key(session_id, :server)
end
