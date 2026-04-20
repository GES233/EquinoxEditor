defmodule Equinox.Session.Server do
  @moduledoc """
  管理会话及项目后台状态。
  """
  use GenServer
  require Logger

  alias Equinox.Session.Context
  alias Equinox.Project
  alias Equinox.Kernel.Dispatcher

  def start_link(opts) do
    with {:ok, session_id} <- Keyword.fetch(opts, :session_id) do
      server_name = Keyword.get(opts, :name, session_id)
      GenServer.start_link(__MODULE__, opts, name: server_name)
    end
  end

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: Keyword.get(opts, :id, {__MODULE__, session_id}),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    project = Keyword.get(opts, :project, Project.new(id: session_id))
    storage = Keyword.get(opts, :storage)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    {:ok, Context.new(session_id, project, storage, task_supervisor)}
  end

  @impl true
  def handle_call({:get_project}, _from, state) do
    {:reply, state.project, state}
  end

  @impl true
  def handle_call({:update_project, new_project}, _from, state) do
    {:reply, :ok, %{state | project: new_project}}
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

  defp cancel_pending_task(%Context{render_tasks: %{pid: pid}, task_supervisor: task_supervisor}) do
    Task.Supervisor.terminate_child(task_supervisor, pid)
  end

  defp start_render_task(%Context{task_supervisor: task_supervisor} = state, plan, opts) do
    Task.Supervisor.async_nolink(
      task_supervisor,
      fn -> Dispatcher.dispatch(plan, state.blackboard, opts) end
    )
  end
end
