defmodule Equinox.Session.Server do
  @moduledoc """
  管理会话及项目后台状态。

  init 时通过 `Oi.Runtime.Session.ensure_started/2` 建立会话基础设施
  （symbiont scope / Task.Supervisor / stratum storage），terminate 时对应销毁。

  编辑操作收拢为本模块的命名 client API（call/cast）。写路径统一经
  `Coconut.Edit.History`（`Context.history`，唯一写入口）：轨道结构走
  `Coconut.Edit.Command`，音符整窗替换走 `Coconut.Edit.Diff` 反推的 op 批次，
  patch 挂载走 `Command.attach_patches`；混音 / UI 状态等 equinox 侧表
  （`tracks_meta`）不进 History、不可 undo。GenServer 本身不含业务逻辑，
  只做编排与状态回同步（`Context.sync_workspace/1`）。
  """
  use GenServer
  require Logger

  alias Coconut.Edit.{Command, Diff, History}
  alias Coconut.Edit.Track, as: CoconutTrack
  alias Coconut.Edit.Track.{Audio, Vocal}
  alias Coconut.Util.ID
  alias Equinox.Session.Context
  alias Equinox.Kernel.{Graph, Runner}
  alias EquinoxDomain.Command.AdoptRequest
  alias EquinoxDomain.Score.{Project, Track, TrackMeta}

  # ---- Client API ----

  @doc "取会话视图（project + 轨级合成图），供 UI presenter 投影。"
  @spec get_view(GenServer.server()) :: %{project: Project.t(), graphs: %{term() => Graph.t()}}
  def get_view(server), do: GenServer.call(server, :get_view)

  @doc """
  新增轨道（经 `History.run(Command.add_track(...))`，可 undo）。

  `attrs`（map 或 keyword）缺 `:id` 时自动生成；`:type` 映射 coconut
  轨型模块——`:external_audio`（或 `"external_audio"`）→
  `Coconut.Edit.Track.Audio`（帧域音频轨），其余 / 缺省 →
  `Coconut.Edit.Track.Vocal`；混音键（`:gain` / `:pan` / `:mute` / `:solo`）
  进 `TrackMeta` 侧表。成功回复构造好的 `Coconut.Edit.Track`
  （含铸造后的 id），并初始化该轨的 `TrackMeta` 侧表项。
  """
  @spec add_track(GenServer.server(), map() | keyword()) ::
          {:ok, CoconutTrack.t()} | {:error, term()}
  def add_track(server, attrs), do: GenServer.call(server, {:add_track, attrs})

  @doc "移除轨道（经 History，可 undo），同时清掉该轨的合成图与元数据侧表。"
  @spec remove_track(GenServer.server(), term()) :: :ok | {:error, term()}
  def remove_track(server, track_id), do: GenServer.call(server, {:remove_track, track_id})

  @doc "更新轨道混音参数（只取 `:gain` / `:pan` / `:mute` / `:solo`；侧表写，不进 History）。"
  @spec update_track_mix(GenServer.server(), term(), map() | keyword()) ::
          {:ok, TrackMeta.t()} | {:error, term()}
  def update_track_mix(server, track_id, attrs),
    do: GenServer.call(server, {:update_track_mix, track_id, attrs})

  @doc "写入轨道 UI 状态（`TrackMeta.ui_state[key]`；侧表写，不进 History）。"
  @spec update_track_ui_state(GenServer.server(), term(), term(), term()) ::
          {:ok, TrackMeta.t()} | {:error, term()}
  def update_track_ui_state(server, track_id, key, value),
    do: GenServer.call(server, {:update_track_ui_state, track_id, key, value})

  @doc """
  整体替换指定窗口内的音符（一条 History 边，可 undo）。

  流程：定位 `start_tick == window_start` 的窗口（不存在报
  `{:error, {:window_not_found, window_start}}`）→ 以「窗外音符原样 +
  窗口目标音符」组装全轨目标序列，`Coconut.Edit.Diff.diff/2` 反推 op 批次
  （span+内容完全一致的音符保留原 id，锚其上的 patch 随之存活；
  被删除/替换的音符 id 消亡，其 patch 判死进墓地）→ 经
  `History.run(Command.batch(...))` 落盘 → 排干死 patch 墓地并日志上浮。

  `note_attrs_list` 的 attrs 须含 `:start_tick` / `:duration_tick`
  （绝对 tick）与 `:key`（Key struct 或 midi 数值），其余键进 Note metadata。
  """
  @spec replace_window_notes(GenServer.server(), term(), non_neg_integer(), [map() | keyword()]) ::
          {:ok, CoconutTrack.t()} | {:error, term()}
  def replace_window_notes(server, track_id, window_start, note_attrs_list),
    do: GenServer.call(server, {:replace_window_notes, track_id, window_start, note_attrs_list})

  @doc "更新轨级合成图（Kernel 编译期概念，存于 Session 侧而非 Domain）。"
  @spec update_synth_graph(GenServer.server(), term(), Graph.t()) ::
          :ok | {:error, {:unknown_track, term()}}
  def update_synth_graph(server, track_id, graph),
    do: GenServer.call(server, {:update_synth_graph, track_id, graph})

  @doc """
  采纳引擎产出为轨道 patch（`AdoptRequest` 流程：`build_patch/3` 纯构造
  （base digest 由 channel 模块对当前 workspace 投影算出）→
  `History.run(Command.attach_patches(...))` 挂载）。

  `attrs` 须含 `:channel`（`Coconut.Render.Channel` 实现模块）、`:payload`，
  锚二选一：`:anchor`（`AdoptRequest.anchor_spec()`）或 `:seq_id`
  （音符 id，便捷形，展开为 `{:ordinal, [note_id]}`）；可带 `:id`
  （缺省自动铸造）。成功回复 `{:ok, track, patch}`（patch 已挂载）。
  """
  @spec adopt_intervention(GenServer.server(), term(), map() | keyword()) ::
          {:ok, CoconutTrack.t(), Coconut.Edit.Patch.t()} | {:error, term()}
  def adopt_intervention(server, track_id, attrs),
    do: GenServer.call(server, {:adopt_intervention, track_id, attrs})

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
    {:ok, project} = Project.new(id: ID.generate_id("Project_"))
    project
  end

  # ---- 编辑 API 的 handle ----

  @impl true
  def handle_call(:get_view, _from, state) do
    {:reply, %{project: state.project, graphs: state.graphs}, state}
  end

  def handle_call({:add_track, attrs}, _from, state) do
    {track_type, attrs} = attrs |> Map.new() |> pop_track_type()
    attrs = Map.put(attrs, :module, track_module(track_type))
    mix_attrs = Map.take(attrs, [:gain, :pan, :mute, :solo])

    with {:ok, %Command{payload: %CoconutTrack{} = track} = command} <- Command.add_track(attrs),
         {:ok, meta} <- TrackMeta.new(mix_attrs),
         {:ok, state} <- run_history(state, command) do
      project = %{state.project | tracks_meta: Map.put(state.project.tracks_meta, track.id, meta)}
      {:reply, {:ok, track}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:remove_track, track_id}, _from, state) do
    case run_history(state, Command.remove_track(track_id)) do
      {:ok, state} ->
        project = %{state.project | tracks_meta: Map.delete(state.project.tracks_meta, track_id)}
        state = %{state | project: project, graphs: Map.delete(state.graphs, track_id)}
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:update_track_mix, track_id, attrs}, _from, state) do
    mix_attrs = attrs |> Map.new() |> Map.take([:gain, :pan, :mute, :solo])

    with {:ok, meta} <- Project.track_meta(state.project, track_id),
         {:ok, meta} <- TrackMeta.update(meta, mix_attrs),
         {:ok, project} <- Project.put_track_meta(state.project, track_id, meta) do
      {:reply, {:ok, meta}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:update_track_ui_state, track_id, key, value}, _from, state) do
    with {:ok, meta} <- Project.track_meta(state.project, track_id),
         {:ok, meta} <- TrackMeta.update(meta, ui_state: Map.put(meta.ui_state, key, value)),
         {:ok, project} <- Project.put_track_meta(state.project, track_id, meta) do
      {:reply, {:ok, meta}, %{state | project: project}}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:replace_window_notes, track_id, window_start, note_attrs_list}, _from, state) do
    with {:ok, track} <- Project.fetch_track(state.project, track_id),
         {:ok, windows} <- Track.slice(state.project, track_id),
         {:ok, window} <- fetch_window(windows, window_start),
         {:ok, ops, side_changes} <- diff_window(track, window, note_attrs_list),
         {:ok, state} <- apply_window_ops(state, track_id, ops, side_changes) do
      {:ok, updated} = Project.fetch_track(state.project, track_id)
      {:reply, {:ok, updated}, state}
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:update_synth_graph, track_id, graph}, _from, state) do
    case Project.fetch_track(state.project, track_id) do
      {:ok, _track} ->
        {:reply, :ok, %{state | graphs: Map.put(state.graphs, track_id, graph)}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:adopt_intervention, track_id, attrs}, _from, state) do
    with {:ok, channel_module, patch_attrs} <- adopt_attrs(track_id, attrs),
         {:ok, patch} <-
           AdoptRequest.build_patch(state.project.workspace, channel_module, patch_attrs),
         {:ok, state} <- run_history(state, Command.attach_patches([patch])),
         {:ok, track} <- Project.fetch_track(state.project, track_id),
         {:ok, mounted} <- fetch_mounted_patch(track, patch.id) do
      {:reply, {:ok, track, mounted}, state}
    else
      {:error, _} = err -> {:reply, err, state}
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

  # 调用方的轨道类型 → coconut 轨型模块：`:external_audio`（或字符串形）映射
  # `Track.Audio`（帧域），其余 / 缺省一律 `Track.Vocal`。`:type` 不是
  # `Coconut.Edit.Track` 的字段，须在 `Track.new/1` 归一化丢弃前取出。
  defp pop_track_type(attrs) do
    {type, attrs} = Map.pop(attrs, :type)
    {string_type, attrs} = Map.pop(attrs, "type")
    {type || string_type, attrs}
  end

  defp track_module(type) when type in [:external_audio, "external_audio"], do: Audio
  defp track_module(_other), do: Vocal

  # History 写入口统一收尾：写入 → 排干死 patch 墓地（日志上浮，等价旧
  # rebase 冲突上浮通道；当前无 UI 订阅方，先记录不丢弃）→ workspace 回挂
  # project（tracks_meta 侧表不动）。
  defp run_history(%Context{} = state, %Command{} = command) do
    with {:ok, hist} <- History.run(state.history, command) do
      {dead, hist} = History.take_dead_patches(hist)
      log_dead_patches(dead)
      {:ok, Context.sync_workspace(%{state | history: hist})}
    end
  end

  defp log_dead_patches([]), do: :ok

  defp log_dead_patches(dead) do
    Logger.warning("Edit killed #{length(dead)} patch(es):\n\n#{inspect(dead)}")
  end

  defp fetch_window(windows, window_start) do
    case Enum.find(windows, &(&1.start_tick == window_start)) do
      nil -> {:error, {:window_not_found, window_start}}
      window -> {:ok, window}
    end
  end

  # 整窗替换的 Diff 输入：窗外音符（span + 内容原样保留）+ 窗口目标音符，
  # 按 span 起点排序为目标序列。内容完全一致者保 id（patch 存活），其余
  # Delete+Insert（锚死进墓地，由 run_history 上浮）。
  defp diff_window(%CoconutTrack{} = track, window, note_attrs_list) do
    kept =
      track
      |> CoconutTrack.view()
      |> Enum.reject(fn {id, _note, _span} -> id in window.note_ids end)
      |> Enum.map(fn {_id, note, span} -> {span, note_content_attrs(note)} end)

    with {:ok, news} <- map_note_attrs(note_attrs_list) do
      target = Enum.sort_by(kept ++ news, fn {{start_tick, _end}, _attrs} -> start_tick end)
      Diff.diff(track, target)
    end
  end

  # Note struct → cast_element 词汇（`:pitch` / `:lyric` / `:annotation` +
  # metadata 平铺），与 `Track.Vocal.edit_element/2` 的组装方式一致
  defp note_content_attrs(note) do
    %{pitch: note.key, lyric: note.lyric, annotation: note.annotation}
    |> Map.merge(note.metadata)
  end

  defp map_note_attrs(note_attrs_list) do
    Enum.reduce_while(note_attrs_list, {:ok, []}, fn attrs, {:ok, acc} ->
      case window_note_element(attrs) do
        {:ok, element} -> {:cont, {:ok, [element | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, elements} -> {:ok, Enum.reverse(elements)}
      {:error, _} = err -> err
    end
  end

  # UI 音符 attrs（`:start_tick` / `:duration_tick` / `:key` + 其余 metadata）
  # → Diff 目标元素 `{span, content_attrs}`（`:key` 归入 cast 词汇 `:pitch`）
  defp window_note_element(attrs) do
    attrs = Map.new(attrs)
    {start_tick, attrs} = Map.pop(attrs, :start_tick)
    {duration_tick, attrs} = Map.pop(attrs, :duration_tick)
    {key, attrs} = Map.pop(attrs, :key)

    if is_integer(start_tick) and is_integer(duration_tick) and duration_tick > 0 do
      {:ok, {{start_tick, start_tick + duration_tick}, Map.put(attrs, :pitch, key)}}
    else
      {:error, {:invalid_note_attrs, attrs}}
    end
  end

  # 无变化（Diff 空 op + 空侧改）不写 History，避免空 undo 边；
  # 纯内容编辑（如歌词）无 op 但有元素 upsert，仍须落盘
  defp apply_window_ops(state, _track_id, [], %{elements: e, span_snapshot: s})
       when map_size(e) == 0 and map_size(s) == 0,
       do: {:ok, state}

  defp apply_window_ops(state, track_id, ops, side_changes) do
    run_history(state, Command.batch([{track_id, ops, side_changes}], "ReplaceWindowNotes"))
  end

  # adopt attrs 归一：`:channel` 模块必填；`:anchor` 直用，`:seq_id` 展开为
  # 单音符 Ordinal 锚；`:id` 缺省预铸（挂载后按 id 取回 patch 回复调用方）
  defp adopt_attrs(track_id, attrs) do
    attrs = Map.new(attrs)

    with {:ok, channel_module} <- fetch_channel_module(attrs),
         {:ok, anchor_spec} <- fetch_anchor_spec(attrs),
         {:ok, payload} <- fetch_payload(attrs) do
      patch_attrs = %{
        id: Map.get(attrs, :id) || ID.generate_id("Patch_"),
        track_id: track_id,
        anchor: anchor_spec,
        payload: payload
      }

      {:ok, channel_module, patch_attrs}
    end
  end

  defp fetch_channel_module(attrs) do
    case Map.fetch(attrs, :channel) do
      {:ok, module} when is_atom(module) -> {:ok, module}
      {:ok, other} -> {:error, {:invalid_channel_module, other}}
      :error -> {:error, {:missing_adopt_attr, :channel}}
    end
  end

  defp fetch_anchor_spec(attrs) do
    case Map.fetch(attrs, :anchor) do
      {:ok, anchor_spec} ->
        {:ok, anchor_spec}

      :error ->
        case Map.fetch(attrs, :seq_id) do
          {:ok, note_id} -> {:ok, {:ordinal, [note_id]}}
          :error -> {:error, {:missing_adopt_attr, :anchor}}
        end
    end
  end

  defp fetch_payload(attrs) do
    case Map.fetch(attrs, :payload) do
      {:ok, payload} -> {:ok, payload}
      :error -> {:error, {:missing_adopt_attr, :payload}}
    end
  end

  defp fetch_mounted_patch(%CoconutTrack{} = track, patch_id) do
    case Enum.find(track.patches, &(&1.id == patch_id)) do
      nil -> {:error, {:patch_not_mounted, patch_id}}
      patch -> {:ok, patch}
    end
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
