defmodule Equinox.Session.Server do
  @moduledoc """
  管理会话及项目后台状态。

  init 时通过 `Oi.Runtime.Session.ensure_started/2` 建立会话基础设施
  （symbiont scope / Task.Supervisor / stratum storage），terminate 时对应销毁。
  """
  use GenServer
  require Logger

  alias Equinox.Session.Context
  alias Equinox.Project
  alias Equinox.Kernel.Runner

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

    oi_opts = [orchid_symbiont_strict: Keyword.get(opts, :orchid_symbiont_strict, false)]

    case Oi.Runtime.Session.ensure_started(session_id, oi_opts) do
      {:ok, _pid} ->
        # trap_exit 使监督者 shutdown 也会触发 terminate/2，保证 Oi 会话被销毁
        Process.flag(:trap_exit, true)
        project = Keyword.get(opts, :project, Project.new(id: session_id))
        {:ok, Context.new(session_id, project)}

      other ->
        {:stop, {:oi_session_start_failed, other}}
    end
  end

  @impl true
  def terminate(_reason, %Context{session_id: session_id}) do
    _ = Oi.Runtime.Session.stop(session_id)
    :ok
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
    case Context.prepare_dispatch(state) do
      {_state, {:error, reason}} ->
        Logger.error("Dispatch preparation failed!\n\nReason: #{inspect(reason)}")
        {:noreply, state}

      {%Context{} = new_state, dispatch} ->
        cancel_pending_task(state)
        task = start_render_task(new_state, dispatch, dispatch_opts)
        {:noreply, %{new_state | render_tasks: task}}
    end
  end

  @impl true
  def handle_info({ref, result}, %Context{render_tasks: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, new_board} ->
        {:noreply, %{state | blackboard: new_board, render_tasks: nil}}

      {:error, reason} ->
        Logger.error("Render task failed!\n\nReason: #{inspect(reason)}")
        {:noreply, %{state | render_tasks: nil}}
    end
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

  defp start_render_task(%Context{task_supervisor: task_supervisor} = state, dispatch, opts) do
    Task.Supervisor.async_nolink(
      task_supervisor,
      fn -> Runner.run(dispatch, state.blackboard, opts) end
    )
  end
end
