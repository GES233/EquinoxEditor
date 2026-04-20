defmodule Equinox.Session.Context do
  @moduledoc """
  `Equinox.Session.Server` 状态容器。
  包含一个 Project 的实时运行状态（而非持久化数据）。
  """

  alias Equinox.Project
  alias Equinox.Session.Storage
  alias Equinox.Kernel.{Blackboard, Compiler, Graph, Planner, RecipeBundle}
  alias Equinox.Track
  alias Equinox.Editor.Segment

  @type static_bundles_cache :: %{
          Segment.id() => {Graph.t(), RecipeBundle.interventions_map(), [RecipeBundle.t()]}
        }

  @type t :: %__MODULE__{
          session_id: atom() | String.t(),
          project: Project.t(),
          static_bundles_cache: static_bundles_cache(),
          blackboard: Blackboard.t(),
          storage: Storage.t() | nil,
          task_supervisor: pid() | atom(),
          render_tasks: Task.t() | nil
        }
  defstruct [
    :session_id,
    :project,
    :storage,
    :task_supervisor,
    static_bundles_cache: %{},
    blackboard: nil,
    render_tasks: nil
  ]

  @spec new(atom() | String.t(), Project.t(), Storage.t() | nil, pid() | atom()) :: t()
  def new(session_id, project, storage, task_supervisor) do
    %__MODULE__{
      session_id: session_id,
      project: project,
      storage: storage,
      task_supervisor: task_supervisor,
      blackboard: Blackboard.new()
    }
  end

  @spec dispatch_to_plans(t()) :: {t(), Planner.Plan.t() | {:error, term()}}
  def dispatch_to_plans(%__MODULE__{} = ctx) do
    all_segments = Enum.flat_map(Project.list_tracks(ctx.project), &Track.list_segments/1)

    compiled_results =
      Enum.map(all_segments, fn seg -> compile_segment(seg, ctx.static_bundles_cache) end)

    case Enum.find(compiled_results, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        {ctx, error}

      _ ->
        successful_results =
          Enum.map(compiled_results, fn {:ok, compiled_result} -> compiled_result end)

        {:ok, plan} =
          successful_results
          |> Enum.map(fn {id, _, _, bundle} -> {id, bundle} end)
          |> Planner.build()

        new_ctx = %{
          ctx
          | static_bundles_cache:
              Map.new(successful_results, fn {id, graph, intervention, bundle} ->
                {id, {graph, intervention, bundle}}
              end)
        }

        {new_ctx, plan}
    end
  end

  defp compile_segment(%Segment{} = seg, cache) do
    Compiler.compile_segment(seg, cache)
  end
end
