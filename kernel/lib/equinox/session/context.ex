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

  每轨先跑 `Track.slice/1` 窗口投影，再按轨编译合成图
  （`Compiler.compile_track/3`，结果按轨缓存进 Context）；每个窗口产出一个
  执行单元 `{{track_id, window_start_tick}, graph, %{}, compiled}`。
  units 按 `{track_id, window_start_tick}` 排序，保证确定性。

  空窗口轨不出单元；任一 slice/compile 失败则整体返回 `{ctx, error}`，
  且 ctx 保持不变。
  """
  @spec prepare_dispatch(t()) :: {t(), Runner.dispatch() | {:error, term()}}
  def prepare_dispatch(%__MODULE__{} = ctx) do
    tracks = Enum.sort_by(ctx.project.tracks, fn {track_id, _track} -> track_id end)

    case reduce_tracks(ctx, tracks) do
      {:ok, units, compile_cache} ->
        dispatch = %{session_id: ctx.session_id, units: units}
        {%{ctx | compile_cache: compile_cache}, dispatch}

      {:error, _reason} = error ->
        {ctx, error}
    end
  end

  # 逐轨 slice + compile，累积 units 与新 compile_cache；任一失败即中断
  defp reduce_tracks(ctx, tracks) do
    tracks
    |> Enum.reduce_while({:ok, [], %{}}, fn {track_id, track}, {:ok, units_acc, cache_acc} ->
      with {:ok, windows} <- Track.slice(track),
           {:ok, track_units, cache_acc} <- compile_units(ctx, track_id, windows, cache_acc) do
        {:cont, {:ok, units_acc ++ track_units, cache_acc}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, units, cache} -> {:ok, units, cache}
      {:error, _reason} = err -> err
    end
  end

  # 空窗口轨不出单元，也不消耗编译缓存
  defp compile_units(_ctx, _track_id, [], cache_acc), do: {:ok, [], cache_acc}

  defp compile_units(ctx, track_id, windows, cache_acc) do
    graph = Map.get(ctx.graphs, track_id, %Graph{})

    case Compiler.compile_track(track_id, graph, cache_acc) do
      {:ok, {graph, compiled}, cache_acc} ->
        units =
          windows
          |> Enum.sort_by(& &1.start_tick)
          |> Enum.map(fn window -> {{track_id, window.start_tick}, graph, %{}, compiled} end)

        {:ok, units, cache_acc}

      {:error, _reason} = err ->
        err
    end
  end
end
