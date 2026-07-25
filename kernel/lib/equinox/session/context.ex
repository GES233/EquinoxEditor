defmodule Equinox.Session.Context do
  @moduledoc """
  `Equinox.Session.Server` 状态容器。
  包含一个 Project 的实时运行状态（而非持久化数据）。

  - `project` — `EquinoxDomain.Score.Project` 聚合根（音符 / 混音 / 元数据）。
  - `graphs` — `%{track_id => Equinox.Kernel.Graph.t()}`，轨级合成图。
    graph 是 Kernel 编译期概念（不进 Domain struct），过渡期存于本字段。
  - `compile_cache` — `%{track_id => {graph, compiled}}`，按轨缓存编译产物，
    供编辑-渲染循环增量复用。
  """

  alias Equinox.Session
  alias Equinox.Kernel.{Blackboard, Compiler, Graph, Runner}
  alias EquinoxDomain.Command.RenderRequest
  alias EquinoxDomain.Score.{Project, Track}

  @type t :: %__MODULE__{
          session_id: atom() | String.t(),
          project: Project.t(),
          graphs: %{term() => Graph.t()},
          compile_cache: Compiler.compile_cache(),
          blackboard: Blackboard.t(),
          task_supervisor: GenServer.name(),
          render_tasks: Task.t() | nil
        }
  defstruct [
    :session_id,
    :project,
    :task_supervisor,
    graphs: %{},
    compile_cache: %{},
    blackboard: nil,
    render_tasks: nil
  ]

  @spec new(atom() | String.t(), Project.t()) :: t()
  def new(session_id, project) do
    %__MODULE__{
      session_id: session_id,
      project: project,
      task_supervisor: Session.task_sup(session_id),
      blackboard: Blackboard.new()
    }
  end

  @doc """
  编译全部轨道并组装一次渲染 dispatch（`Runner.dispatch()`）。

  流程：先把工程 tempo 源事件编译为 `TempoMap`
  （`Project.compiled_tempo_map/2`，tpqn 480）；逐轨 `Track.slice/2`
  （传 `tempo_map` 与 `interventions`，干预 scope 并集参与扩窗），再按轨编译
  合成图（`Compiler.compile_track/3`，结果按轨缓存进 Context）；每个窗口经
  `RenderRequest.from_window/3` 产出一个执行单元
  `{{track_id, window_start_tick}, graph, render_request, compiled}`。
  units 按 `{track_id, window_start_tick}` 排序，保证确定性。

  空窗口轨不出单元；tempo 编译失败且全工程无窗口时仍产出正常空 dispatch，
  任一轨切出窗口则整体报错 `{ctx, {:error, tempo_reason}}`（响亮报错，不做
  静默兜底）；任一 slice/compile/from_window 失败同样 `{ctx, error}`，
  且 ctx 保持不变。
  """
  @spec prepare_dispatch(t()) :: {t(), Runner.dispatch() | {:error, term()}}
  def prepare_dispatch(%__MODULE__{} = ctx) do
    tracks = Enum.sort_by(ctx.project.tracks, fn {track_id, _track} -> track_id end)
    tempo = Project.compiled_tempo_map(ctx.project, tpqn: 480)

    case reduce_tracks(ctx, tracks, tempo) do
      {:ok, units, compile_cache} ->
        dispatch = %{session_id: ctx.session_id, units: units}
        {%{ctx | compile_cache: compile_cache}, dispatch}

      {:error, _reason} = error ->
        {ctx, error}
    end
  end

  # 逐轨 slice + compile，累积 units 与新 compile_cache；任一失败即中断。
  # tempo 是 `{:ok, TempoMap.t()} | {:error, reason}`：编译失败时 slice 仍可
  # 不带 tempo_map 进行（窗口只依赖 tick），真正有窗口产出时才强制要求它。
  defp reduce_tracks(ctx, tracks, tempo) do
    tracks
    |> Enum.reduce_while({:ok, [], %{}}, fn {track_id, track}, {:ok, units_acc, cache_acc} ->
      with {:ok, windows} <- slice_track(track, tempo),
           {:ok, track_units, cache_acc} <-
             compile_units(ctx, track_id, track, windows, cache_acc, tempo) do
        {:cont, {:ok, units_acc ++ track_units, cache_acc}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp slice_track(track, {:ok, tempo_map}),
    do: Track.slice(track, tempo_map: tempo_map, interventions: track.interventions)

  defp slice_track(track, {:error, _reason}),
    do: Track.slice(track, interventions: track.interventions)

  # 空窗口轨不出单元，也不消耗编译缓存（tempo 编译失败此时无关紧要）
  defp compile_units(_ctx, _track_id, _track, [], cache_acc, _tempo), do: {:ok, [], cache_acc}

  defp compile_units(ctx, track_id, track, windows, cache_acc, tempo) do
    graph = Map.get(ctx.graphs, track_id, %Graph{})

    # 有窗口产出就必须有编译态 tempo map：`RenderRequest.from_window/3` 切片
    # tempo_segments 需要它；此处失败整体返回工程 tempo 的编译错误
    with {:ok, tempo_map} <- tempo,
         {:ok, {graph, compiled}, cache_acc} <-
           Compiler.compile_track(track_id, graph, cache_acc),
         {:ok, units} <- build_units(track_id, track, windows, tempo_map, graph, compiled) do
      {:ok, units, cache_acc}
    end
  end

  defp build_units(track_id, track, windows, tempo_map, graph, compiled) do
    windows
    |> Enum.sort_by(& &1.start_tick)
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case RenderRequest.from_window(window, track, tempo_map) do
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
