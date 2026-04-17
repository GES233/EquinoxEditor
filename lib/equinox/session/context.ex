defmodule Equinox.Session.Context do
  @moduledoc """
  `Equinox.Session.Server` 状态容器。
  包含一个 Project 的实时运行状态（而非持久化数据）。
  """

  alias Equinox.Project
  alias Equinox.Session.Storage
  alias Equinox.Kernel.Graph
  alias Equinox.Editor.{Track, Segment}
  alias Equinox.Kernel.{Blackboard, Planner, RecipeBundle}

  @type static_bundles_cache :: %{
          Segment.id() => {Graph.t(), RecipeBundle.interventions_map(), [RecipeBundle.t()]}
        }

  @type t :: %__MODULE__{
          session_id: atom() | String.t(),
          project: Project.t(),
          static_bundles_cache: static_bundles_cache(),
          blackboard: Blackboard.t(),
          storage: Storage.t() | nil,
          render_tasks: Task.t() | nil
        }
  defstruct [
    :session_id,
    :project,
    :storage,
    static_bundles_cache: %{},
    blackboard: nil,
    render_tasks: nil
  ]

  @spec new(atom() | String.t(), Project.t(), Storage.t() | nil) :: t()
  def new(session_id, project, storage) do
    %__MODULE__{
      session_id: session_id,
      project: project,
      storage: storage,
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
        {:ok, plan} =
          compiled_results
          |> Enum.map(fn {id, _, _, bundle} -> {id, bundle} end)
          |> Planner.build()

        new_ctx = %{
          ctx
          | static_bundles_cache:
              Map.new(compiled_results, fn {id, graph, intervention, bundle} ->
                {id, {graph, intervention, bundle}}
              end)
        }

        {new_ctx, plan}
    end
  end

  defp compile_segment(%Segment{} = seg, cache) do
    # History resolution is moving to Project/Editor level.
    # For now, we assume the Segment's graph is already the effective graph.
    # We will pass empty interventions until we fully integrate the Domain.Note/Curve translator.
    effective_graph = seg.graph || %Equinox.Kernel.Graph{}
    interventions = %{}

    with :error <- Map.fetch(cache, seg.id),
         {:error, _} = err <-
           Equinox.Kernel.GraphBuilder.compile_graph(
             effective_graph,
             seg.cluster || %Equinox.Kernel.Graph.Cluster{}
           ) do
      err
    else
      {:ok, {cached_graph, cached_interventions, cached_recipe_bundles}} ->
        {seg.id, cached_graph, cached_interventions, cached_recipe_bundles}

      {:ok, recipe_bundles} ->
        recipe_bundle = RecipeBundle.bind_interventions(recipe_bundles, interventions)
        {seg.id, effective_graph, interventions, recipe_bundle}
    end
  end
end
