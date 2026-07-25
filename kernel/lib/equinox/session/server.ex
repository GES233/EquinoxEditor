defmodule Equinox.Session.Server do
  @moduledoc """
  管理会话及项目后台状态。

  init 时通过 `Oi.Runtime.Session.ensure_started/2` 建立会话基础设施
  （symbiont scope / Task.Supervisor / stratum storage），terminate 时对应销毁。

  编辑操作收拢为本模块的命名 client API（call/cast），内部经
  `EquinoxDomain.Score.Project` / `EquinoxDomain.Score.Track` 的纯函数编排，
  不再暴露「取整个 project 改完再推回」的裸消息接口。
  """
  use GenServer
  require Logger

  alias Equinox.Session.Context
  alias Equinox.Kernel.{Graph, Runner}
  alias EquinoxDomain.Score.{Project, Track}
  alias Zongzi.Util.ID

  # ---- Client API ----

  @doc "取会话视图（project + 轨级合成图），供 UI presenter 投影。"
  @spec get_view(GenServer.server()) :: %{project: Project.t(), graphs: %{term() => Graph.t()}}
  def get_view(server), do: GenServer.call(server, :get_view)

  @doc """
  新增轨道。`attrs`（map 或 keyword）缺 `:id` 时自动生成；
  成功回复存入后的 track（`project_id` 已对齐 project.id）。
  """
  @spec add_track(GenServer.server(), map() | keyword()) ::
          {:ok, Track.t()} | {:error, term()}
  def add_track(server, attrs), do: GenServer.call(server, {:add_track, attrs})

  @doc "移除轨道，同时清掉该轨的合成图。"
  @spec remove_track(GenServer.server(), term()) ::
          :ok | {:error, {:track_not_found, term()}}
  def remove_track(server, track_id), do: GenServer.call(server, {:remove_track, track_id})

  @doc "更新轨道混音参数（只取 `:gain` / `:pan` / `:mute` / `:solo`）。"
  @spec update_track_mix(GenServer.server(), term(), map() | keyword()) ::
          {:ok, Track.t()} | {:error, term()}
  def update_track_mix(server, track_id, attrs),
    do: GenServer.call(server, {:update_track_mix, track_id, attrs})

  @doc "写入轨道 UI 状态（存于 `track.metadata[\"ui_state\"][key]`）。"
  @spec update_track_ui_state(GenServer.server(), term(), term(), term()) ::
          {:ok, Track.t()} | {:error, term()}
  def update_track_ui_state(server, track_id, key, value),
    do: GenServer.call(server, {:update_track_ui_state, track_id, key, value})

  @doc """
  整体替换指定窗口内的音符。

  流程：定位 `start_tick == window_start` 的窗口（不存在报
  `{:error, {:window_not_found, window_start}}`）→ 窗口内 seq_ids 逐个删除 →
  逐条插入 `note_attrs_list`（attrs 须已是绝对 tick、key 已是 Key struct，
  本函数不做转换）→ `Track.rebase_interventions/1` → 写回 Project。

  注意：这会销毁窗口内既有干预锚（当前干预恒为空，可接受）。
  """
  @spec replace_window_notes(GenServer.server(), term(), non_neg_integer(), [map() | keyword()]) ::
          {:ok, Track.t()} | {:error, term()}
  def replace_window_notes(server, track_id, window_start, note_attrs_list),
    do: GenServer.call(server, {:replace_window_notes, track_id, window_start, note_attrs_list})

  @doc "更新轨级合成图（Kernel 编译期概念，存于 Session 侧而非 Domain）。"
  @spec update_synth_graph(GenServer.server(), term(), Graph.t()) ::
          :ok | {:error, {:track_not_found, term()}}
  def update_synth_graph(server, track_id, graph),
    do: GenServer.call(server, {:update_synth_graph, track_id, graph})

  @doc "触发一次渲染 dispatch（异步）。"
  @spec dispatch(GenServer.server(), keyword()) :: :ok
  def dispatch(server, opts \\ []), do: GenServer.cast(server, {:dispatch, opts})

  # ---- 启动与生命周期 ----

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
        {:ok, Context.new(session_id, resolve_project(opts))}

      other ->
        {:stop, {:oi_session_start_failed, other}}
    end
  end

  @impl true
  def terminate(_reason, %Context{session_id: session_id}) do
    _ = Oi.Runtime.Session.stop(session_id)
    :ok
  end

  # project opt 传入 %Project{} 时原样使用；缺省（含显式 nil）造默认工程
  defp resolve_project(opts) do
    case Keyword.get(opts, :project) do
      %Project{} = project -> project
      _ -> default_project()
    end
  end

  defp default_project do
    {:ok, project} = Project.new(id: ID.generate_id("Project_"), name: "Untitled Project")
    project
  end

  # ---- 编辑 API 的 handle ----

  @impl true
  def handle_call(:get_view, _from, state) do
    {:reply, %{project: state.project, graphs: state.graphs}, state}
  end

  def handle_call({:add_track, attrs}, _from, state) do
    attrs = attrs |> Map.new() |> Map.put_new_lazy(:id, fn -> ID.generate_id("Track_") end)

    with {:ok, track} <- Track.new(attrs),
         {:ok, project} <- Project.add_track(state.project, track) do
      {:reply, {:ok, Map.fetch!(project.tracks, track.id)}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:remove_track, track_id}, _from, state) do
    case Project.remove_track(state.project, track_id) do
      {:ok, project} ->
        {:reply, :ok, %{state | project: project, graphs: Map.delete(state.graphs, track_id)}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:update_track_mix, track_id, attrs}, _from, state) do
    mix_attrs = attrs |> Map.new() |> Map.take([:gain, :pan, :mute, :solo])

    with {:ok, track} <- Project.get_track(state.project, track_id),
         {:ok, track} <- Track.update(track, mix_attrs),
         {:ok, project} <- Project.update_track(state.project, track_id, track) do
      {:reply, {:ok, track}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:update_track_ui_state, track_id, key, value}, _from, state) do
    with {:ok, track} <- Project.get_track(state.project, track_id),
         {:ok, track} <- put_ui_state(track, key, value),
         {:ok, project} <- Project.update_track(state.project, track_id, track) do
      {:reply, {:ok, track}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:replace_window_notes, track_id, window_start, note_attrs_list}, _from, state) do
    with {:ok, track} <- Project.get_track(state.project, track_id),
         {:ok, windows} <- Track.slice(track),
         {:ok, window} <- fetch_window(windows, window_start),
         {:ok, track} <- delete_window_notes(track, window.seq_ids),
         {:ok, track} <- insert_window_notes(track, note_attrs_list),
         {:ok, track, _rebase_report} <- Track.rebase_interventions(track),
         {:ok, project} <- Project.update_track(state.project, track_id, track) do
      {:reply, {:ok, track}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:update_synth_graph, track_id, graph}, _from, state) do
    case Project.get_track(state.project, track_id) do
      {:ok, _track} ->
        {:reply, :ok, %{state | graphs: Map.put(state.graphs, track_id, graph)}}

      {:error, _} = err ->
        {:reply, err, state}
    end
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

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %Context{render_tasks: %{ref: ref}} = state
      ) do
    if reason != :killed do
      Logger.error("Engine crashed!\n\nReason: #{inspect(reason)}")
    end

    {:noreply, %{state | render_tasks: nil}}
  end

  def handle_info(msg, state) do
    Logger.warning("Caught unknown message:\n\n#{inspect(msg)}")
    {:noreply, state}
  end

  # ---- 内部编排 ----

  defp put_ui_state(track, key, value) do
    ui_state = track.metadata |> Map.get("ui_state", %{}) |> Map.put(key, value)
    Track.update(track, %{metadata: Map.put(track.metadata, "ui_state", ui_state)})
  end

  defp fetch_window(windows, window_start) do
    case Enum.find(windows, &(&1.start_tick == window_start)) do
      nil -> {:error, {:window_not_found, window_start}}
      window -> {:ok, window}
    end
  end

  defp delete_window_notes(track, seq_ids) do
    Enum.reduce_while(seq_ids, {:ok, track}, fn seq_id, {:ok, acc} ->
      case Track.delete_note(acc, seq_id) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp insert_window_notes(track, note_attrs_list) do
    Enum.reduce_while(note_attrs_list, {:ok, track}, fn attrs, {:ok, acc} ->
      case Track.insert_note(acc, attrs) do
        {:ok, acc, _note} -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
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
