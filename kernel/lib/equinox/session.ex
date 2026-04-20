defmodule Equinox.Session do
  @moduledoc """
  管理项目运行状态及会话定位。
  """
  import Equinox.Session.Registry

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
end
