defmodule Equinox.Session do
  @moduledoc """
  管理项目运行状态及会话树。
  """
  import Equinox.Session.Registry

  def start(session_id, opts \\ []) do
    case Registry.lookup(Equinox.Session.Registry, instance_sup(session_id, :key)) do
      [{pid, _}] ->
        {:error, {:already_started, pid}}

      [] ->
        session_supervisor_spec = %{
          id: session_id,
          start: {Equinox.Session.Supervisor, :start_link, [session_id, opts]}
        }

        DynamicSupervisor.start_child(Equinox.Session.DynamicSupervisor, session_supervisor_spec)
    end
  end

  def stop(session_id) do
    case Registry.lookup(Equinox.Session.Registry, instance_sup(session_id, :key)) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Equinox.Session.DynamicSupervisor, pid)
      [] -> {:error, :session_not_found}
    end
  end

  def resolve(session_id) do
    case Registry.lookup(Equinox.Session.Registry, server(session_id, :key)) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  def instance_sup(session_id), do: via(session_id, :instance_sup)
  def instance_sup(session_id, :key), do: key(session_id, :instance_sup)
  def task_sup(session_id), do: via(session_id, :task_sup)
  def server(session_id), do: via(session_id, :server)
  def server(session_id, :key), do: key(session_id, :server)
end
