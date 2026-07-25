defmodule Equinox.Session.Context do
  @moduledoc """
  `Equinox.Session.Server` 状态容器。
  包含一个 Project 的实时运行状态（而非持久化数据）。
  """

  alias Equinox.Project
  alias Equinox.Session
  alias Equinox.Kernel.{Blackboard, Compiler, Runner}
  alias Equinox.Track

  @type t :: %__MODULE__{
          session_id: atom() | String.t(),
          project: Project.t(),
          compile_cache: Compiler.compile_cache(),
          blackboard: Blackboard.t(),
          task_supervisor: GenServer.name(),
          render_tasks: Task.t() | nil
        }
  defstruct [
    :session_id,
    :project,
    :task_supervisor,
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
  编译全部 Segment 并组装一次渲染 dispatch（`Runner.dispatch()`）。

  编译结果按 Segment 缓存进 Context，供后续编辑-渲染循环增量复用。
  """
  @spec prepare_dispatch(t()) :: {t(), Runner.dispatch() | {:error, term()}}
  def prepare_dispatch(%__MODULE__{} = ctx) do
    all_segments = Enum.flat_map(Project.list_tracks(ctx.project), &Track.list_segments/1)

    compiled_results =
      Enum.map(all_segments, fn seg -> Compiler.compile_segment(seg, ctx.compile_cache) end)

    case Enum.find(compiled_results, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        {ctx, error}

      _ ->
        successful_results =
          Enum.map(compiled_results, fn {:ok, compiled_result} -> compiled_result end)

        dispatch = %{session_id: ctx.session_id, units: successful_results}

        new_ctx = %{
          ctx
          | compile_cache:
              Map.new(successful_results, fn {id, graph, interventions, compiled} ->
                {id, {graph, interventions, compiled}}
              end)
        }

        {new_ctx, dispatch}
    end
  end
end
