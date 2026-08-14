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
  """

  alias Coconut.Edit.History
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
          render_tasks: Task.t() | nil
        }
  defstruct [
    :session_id,
    :project,
    :history,
    :task_supervisor,
    graphs: %{},
    compile_cache: %{},
    blackboard: nil,
    render_tasks: nil
  ]

  @spec new(atom() | String.t(), Project.t()) :: t()
  def new(session_id, %Project{} = project) do
    %__MODULE__{
      session_id: session_id,
      project: project,
      history: History.new(project.workspace),
      task_supervisor: Session.task_sup(session_id),
      blackboard: Blackboard.new()
    }
  end

  @doc """
  History 写后回同步：把 `History.current(hist).workspace` 挂回
  `project.workspace`（`tracks_meta` 等侧表留在 Project 上，不受影响）。
  """
  @spec sync_workspace(t()) :: t()
  def sync_workspace(%__MODULE__{history: hist, project: project} = ctx) do
    %{ctx | project: %{project | workspace: History.current(hist).workspace}}
  end

  @doc """
  编译全部轨道并组装一次渲染 dispatch（`Runner.dispatch()`）。

  流程：工程 tempo 轨编译为 `TempoMap`（`Project.tempo_map/1`，tpqn 取自
  workspace）；逐轨 `EquinoxDomain.Score.Track.slice/3`（传 workspace tpqn
  与 Metric 锚 patch 推导的 `extra_spans`，干预 scope 并集参与扩窗），再按轨
  编译合成图（`Compiler.compile_track/3`，结果按轨缓存进 Context）；每个窗口
  经 `RenderRequest.from_window/3` 产出一个执行单元
  `{{track_id, window_start_tick}, graph, render_request, compiled}`。
  units 按 `{track_id, window_start_tick}` 排序，保证确定性。

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
      {:ok, units, compile_cache} ->
        dispatch = %{session_id: ctx.session_id, units: units}
        {%{ctx | compile_cache: compile_cache}, dispatch}

      {:error, _reason} = error ->
        {ctx, error}
    end
  end

  # 逐轨 slice + compile，累积 units 与新 compile_cache；任一失败即中断。
  # tempo 是 `{:ok, TempoMap.t()} | {:error, reason}`：编译失败时 slice 仍可
  # 进行（窗口只依赖 tick），真正有窗口产出时才强制要求它。
  defp reduce_tracks(ctx, track_ids, tempo) do
    Enum.reduce_while(track_ids, {:ok, [], %{}}, fn track_id, {:ok, units_acc, cache_acc} ->
      with {:ok, windows} <- slice_track(ctx.project, track_id),
           {:ok, track_units, cache_acc} <-
             compile_units(ctx, track_id, windows, cache_acc, tempo) do
        {:cont, {:ok, units_acc ++ track_units, cache_acc}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # 分窗投影：tpqn 取自 workspace；`extra_spans` 由轨上 Metric 锚 patch 的
  # tick 区间推导（旧「干预 scope 撑窗」语义，Ordinal/Relative 锚挂在音符上
  # 不扩窗）。非整数有理数端点不进 Windowing（tick 网格只认整数）。
  defp slice_track(%Project{} = project, track_id) do
    with {:ok, track} <- Project.fetch_track(project, track_id) do
      Track.slice(project, track_id,
        tpqn: project.workspace.tpqn,
        extra_spans: metric_anchor_spans(track.patches)
      )
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
