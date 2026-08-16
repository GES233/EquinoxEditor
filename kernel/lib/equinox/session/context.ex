defmodule Equinox.Session.Context do
  @moduledoc """
  `Equinox.Session.Server` 状态容器。
  包含一个 Project 的实时运行状态（而非持久化数据）。

  - `project` — `EquinoxDomain.Score.Project` 查询投影（workspace + 侧表）。
    只读快照：每次 History 写后由 `sync_workspace/1` 回挂
    `History.current(hist).workspace`，`tracks_meta` 侧表留在 Project 上。
  - `history` — `Coconut.Edit.History`，全部音符 / patch / 轨道结构写
    的**唯一入口**（undo/redo 地基）。
  - `graphs` — `%{track_id => Equinox.Kernel.Graph.t()}`，轨级合成图。
    graph 是 Kernel 编译期概念（不进 Domain struct），过渡期存于本字段。
  - `compile_cache` — `%{track_id => {graph, compiled}}`，按轨缓存编译产物，
    供编辑-渲染循环增量复用。
  - `engines` — `%{voicebank_id => {EngineAdapter 模块, config}}` 声库注册表
    （userland 注入，config 对 kernel 不透明）；`default_engine` 为
    voicebank_id 缺省轨的回落。per-track 粒度：每轨经
    `TrackMeta.voicebank_id` 解析自己的 `{adapter, config}`。
  - `notifications` — 会话内易失的上浮通知队列（如 `{:dead_patches, [...]}`），
    由 Host/UI 经 `Server.take_notifications/1` 取走（取出即清空）；不落盘，
    与 History 的会话级语义一致。
  """

  alias Coconut.Edit.History
  alias Coconut.Edit.Track, as: CoconutTrack
  alias Equinox.Session
  alias Equinox.Kernel.{Blackboard, Compiler, Graph, Runner}
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Score.{Project, Track}

  @type t :: %__MODULE__{
          session_id: atom() | String.t(),
          project: Project.t(),
          history: History.t(),
          graphs: %{term() => Graph.t()},
          compile_cache: Compiler.compile_cache(),
          blackboard: Blackboard.t(),
          task_supervisor: GenServer.name(),
          render_tasks: Task.t() | nil,
          engines: %{term() => {module(), term()}},
          default_engine: nil | {module(), term()},
          notifications: [term()]
        }
  defstruct [
    :session_id,
    :project,
    :history,
    :task_supervisor,
    :default_engine,
    graphs: %{},
    compile_cache: %{},
    blackboard: nil,
    render_tasks: nil,
    engines: %{},
    notifications: []
  ]

  @spec new(atom() | String.t(), Project.t(), keyword()) :: t()
  def new(session_id, %Project{} = project, opts \\ []) do
    %__MODULE__{
      session_id: session_id,
      project: project,
      history: History.new(project.workspace),
      task_supervisor: Session.task_sup(session_id),
      blackboard: Blackboard.new(),
      engines: opts |> Keyword.get(:engines, %{}) |> Map.new(),
      default_engine: Keyword.get(opts, :default_engine)
    }
  end

  @doc """
  按轨解析引擎适配器（per-track 粒度）：`TrackMeta.voicebank_id` →
  `engines` 注册表；`voicebank_id` 缺省回落 `default_engine`（可为 nil，
  表示该轨无 Adapter 供给，Runner 回落 `Configurator.channels`）。
  未知声库 id 响亮报错。
  """
  @spec engine_for(t(), term()) ::
          {:ok, {module(), term()} | nil} | {:error, {:unknown_voicebank, term()}}
  def engine_for(%__MODULE__{} = ctx, track_id) do
    with {:ok, meta} <- Project.track_meta(ctx.project, track_id) do
      case meta.voicebank_id do
        nil ->
          {:ok, ctx.default_engine}

        voicebank_id ->
          case Map.fetch(ctx.engines, voicebank_id) do
            {:ok, {mod, cfg}} when is_atom(mod) -> {:ok, {mod, cfg}}
            :error -> {:error, {:unknown_voicebank, voicebank_id}}
          end
      end
    end
  end

  @doc """
  History 写后回同步：把 `History.current(hist).workspace` 挂回
  `project.workspace`（`tracks_meta` 等侧表留在 Project 上，不受影响）。
  """
  @spec sync_workspace(t()) :: t()
  def sync_workspace(%__MODULE__{history: hist, project: project} = ctx) do
    %{ctx | project: %{project | workspace: History.current(hist).workspace}}
  end

  @doc "追加上浮通知（如写时 transport 杀死的 patch）到会话通知队列。"
  @spec append_notifications(t(), [term()]) :: t()
  def append_notifications(%__MODULE__{} = ctx, list) when is_list(list),
    do: %{ctx | notifications: ctx.notifications ++ list}

  @doc "取出全部上浮通知并清空队列（Host/UI 轮询出口）。"
  @spec take_notifications(t()) :: {[term()], t()}
  def take_notifications(%__MODULE__{} = ctx),
    do: {ctx.notifications, %{ctx | notifications: []}}

  @doc """
  编译全部轨道并组装一次渲染 dispatch（`Runner.dispatch()`）。

  流程：工程 tempo 轨编译为 `TempoMap`（`Project.tempo_map/1`，tpqn 取自
  workspace）；逐轨 `EquinoxDomain.Score.Track.slice/3`（传 workspace tpqn
  与 Metric 锚 patch 推导的 `extra_spans`，干预 scope 并集参与扩窗），再按轨
  编译合成图（`Compiler.compile_track/3`，结果按轨缓存进 Context）；每个窗口
  经 `RenderRequest.from_window/3` 产出一个执行单元
  `{{track_id, window_start_tick}, graph, render_request, compiled}`。
  units 按 `{track_id, window_start_tick}` 排序，保证确定性。

  同时按轨解析引擎适配器（`engine_for/2`，per-track 粒度），把 Adapter
  派生的 channel specs 挂进 dispatch 的 `track_channels`
  （`%{track_id => %{channel => spec}}`）；无 Adapter 供给的轨不出条目，
  Runner 回落 `Configurator.channels`。globals 校验规则同路径按轨派生
  （`track_global_rules`），旋钮值取自 `TrackMeta.globals` 侧表
  （`track_globals`，空表不出条目）。未知声库 id 整体报错
  `{ctx, {:error, {:unknown_voicebank, _}}}`（响亮失败，ctx 不变）。

  空窗口轨不出单元；tempo 编译失败且全工程无窗口时仍产出正常空 dispatch，
  任一轨切出窗口则整体报错 `{ctx, {:error, tempo_reason}}`（响亮报错，不做
  静默兜底）；任一 slice/compile/from_window 失败同样 `{ctx, error}`，
  且 ctx 保持不变。
  """
  @spec prepare_dispatch(t()) :: {t(), Runner.dispatch() | {:error, term()}}
  def prepare_dispatch(%__MODULE__{} = ctx) do
    track_ids = ctx.project.tracks_meta |> Map.keys() |> Enum.sort()
    tempo = Project.tempo_map(ctx.project)

    case reduce_tracks(ctx, track_ids, tempo) do
      {:ok, units, compile_cache, track_channels, track_global_rules} ->
        dispatch = %{
          session_id: ctx.session_id,
          units: units,
          track_channels: track_channels,
          track_global_rules: track_global_rules,
          track_globals: track_globals(ctx.project)
        }

        {%{ctx | compile_cache: compile_cache}, dispatch}

      {:error, _reason} = error ->
        {ctx, error}
    end
  end

  # per-track 引擎旋钮值（TrackMeta.globals 侧表，空表不出条目）；
  # 校验规则在 reduce_tracks 里按轨由 Adapter 派生（track_global_rules）
  defp track_globals(%Project{} = project) do
    for {track_id, meta} <- project.tracks_meta, map_size(meta.globals) > 0, into: %{} do
      {track_id, meta.globals}
    end
  end

  # 逐轨解析引擎 + slice + compile，累积 units / 新 compile_cache /
  # track_channels / track_global_rules；任一失败即中断。
  # tempo 是 `{:ok, TempoMap.t()} | {:error, reason}`：编译失败时 slice 仍可
  # 进行（窗口只依赖 tick），真正有窗口产出时才强制要求它。
  defp reduce_tracks(ctx, track_ids, tempo) do
    Enum.reduce_while(track_ids, {:ok, [], %{}, %{}, %{}}, fn track_id,
                                                              {:ok, units_acc, cache_acc,
                                                               channels_acc, rules_acc} ->
      with {:ok, engine} <- engine_for(ctx, track_id),
           {:ok, windows} <- slice_track(ctx.project, track_id),
           {:ok, track_units, cache_acc} <-
             compile_units(ctx, track_id, windows, cache_acc, tempo) do
        {:cont,
         {:ok, units_acc ++ track_units, cache_acc,
          put_track_channels(channels_acc, track_id, engine),
          put_global_rules(rules_acc, track_id, engine)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # 无 Adapter 供给的轨不出 track_channels 条目（Runner 回落 conf.channels）
  defp put_track_channels(acc, _track_id, nil), do: acc

  defp put_track_channels(acc, track_id, {adapter, config}),
    do: Map.put(acc, track_id, adapter.channels(config))

  # globals 校验规则同纪律：无 Adapter 供给的轨不出条目（Runner 回落
  # conf.global_rules；nil 即不门控）
  defp put_global_rules(acc, _track_id, nil), do: acc

  defp put_global_rules(acc, track_id, {adapter, config}),
    do: Map.put(acc, track_id, adapter.globals(config))

  # 分窗投影：tpqn 取自 workspace；`extra_spans` 由轨上 Metric 锚 patch 的
  # tick 区间推导（旧「干预 scope 撑窗」语义，Ordinal/Relative 锚挂在音符上
  # 不扩窗）。非整数有理数端点不进 Windowing（tick 网格只认整数）。
  # 非 tick 域轨（Audio 帧域）不出渲染窗口——帧域渲染尚未接入，跳过。
  defp slice_track(%Project{} = project, track_id) do
    with {:ok, track} <- Project.fetch_track(project, track_id) do
      if CoconutTrack.coord_domain(track) == :tick do
        Track.slice(project, track_id,
          tpqn: project.workspace.tpqn,
          extra_spans: metric_anchor_spans(track.patches)
        )
      else
        {:ok, []}
      end
    end
  end

  defp metric_anchor_spans(patches) do
    Enum.flat_map(patches, fn
      %{anchor: %Tamale.Anchor.Metric{from: from, to: to}}
      when is_integer(from) and is_integer(to) ->
        [{from, to}]

      _other ->
        []
    end)
  end

  # 空窗口轨不出单元，也不消耗编译缓存（tempo 编译失败此时无关紧要）
  defp compile_units(_ctx, _track_id, [], cache_acc, _tempo), do: {:ok, [], cache_acc}

  defp compile_units(ctx, track_id, windows, cache_acc, tempo) do
    graph = Map.get(ctx.graphs, track_id, %Graph{})

    # 有窗口产出就必须有编译态 tempo map：`RenderRequest.from_window/3` 切片
    # tempo_segments 需要它；此处失败整体返回工程 tempo 的编译错误
    with {:ok, tempo_map} <- tempo,
         {:ok, {graph, compiled}, cache_acc} <-
           Compiler.compile_track(track_id, graph, cache_acc),
         {:ok, units} <- build_units(ctx.project, track_id, windows, tempo_map, graph, compiled) do
      {:ok, units, cache_acc}
    end
  end

  defp build_units(project, track_id, windows, tempo_map, graph, compiled) do
    windows
    |> Enum.sort_by(& &1.start_tick)
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case RenderRequest.from_window(project, window, tempo_map) do
        {:ok, request} ->
          {:cont, {:ok, [{{track_id, window.start_tick}, graph, request, compiled} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, units} -> {:ok, Enum.reverse(units)}
      {:error, _} = err -> err
    end
  end
end
