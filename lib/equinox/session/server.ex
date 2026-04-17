defmodule Equinox.Session.Server do
  @moduledoc """
  管理会话及项目后台状态。
  """
  use GenServer
  require Logger

  alias Equinox.Session.{Storage, Context}
  alias Equinox.Session
  alias Equinox.Project
  alias Equinox.Kernel.Dispatcher

  def start_link(opts) do
    with {:ok, session_id} <- Keyword.fetch(opts, :session_id) do
      GenServer.start_link(__MODULE__, opts, name: Session.server(session_id))
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    project = Keyword.get(opts, :project, Project.new(id: session_id))
    storage = if Keyword.get(opts, :enable_cache, true), do: Storage.new(), else: nil
    {:ok, Context.new(session_id, project, storage)}
  end

  @impl true
  def handle_cast({:dispatch, dispatch_opts}, %Context{} = state) do
    case Context.dispatch_to_plans(state) do
      {_legacy_state, {:error, _}} = _err ->
        {:noreply, state}

      {%Context{} = new_state, plan} ->
        cancel_pending_task(state)
        task = start_render_task(new_state, plan, dispatch_opts)
        {:noreply, %{new_state | render_tasks: task}}
    end
  end

  @impl true
  def handle_info({ref, {:ok, new_board}}, %Context{render_tasks: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | blackboard: new_board, render_tasks: nil}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %Context{render_tasks: %{ref: ref}} = state
      ) do
    if reason != :killed do
      Logger.error("Engine crashed!\n\nReason: #{inspect(reason)}")
    end

    {:noreply, %{state | render_tasks: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Caught unknown message:\n\n#{inspect(msg)}")
    {:noreply, state}
  end

  defp cancel_pending_task(%Context{render_tasks: nil}), do: :ok

  defp cancel_pending_task(%Context{render_tasks: %{pid: pid}} = state) do
    Task.Supervisor.terminate_child(Session.task_sup(state.session_id), pid)
  end

  defp start_render_task(%Context{} = state, plan, opts) do
    Task.Supervisor.async_nolink(
      Session.task_sup(state.session_id),
      fn -> Dispatcher.dispatch(plan, state.blackboard, opts) end
    )
  end
end
