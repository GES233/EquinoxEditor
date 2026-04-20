defmodule Equinox.Kernel.Compiler do
  @moduledoc """
  纯函数管线的最终阶段。
  将有效的 DAG 翻译为 Orchid.Recipe 序列。
  """

  alias Equinox.Editor.History
  alias Equinox.Domain.Segment
  alias Equinox.Kernel.{Graph, RecipeBundle}

  @type compiled_segment ::
          {Segment.id(), Graph.t(), RecipeBundle.interventions_map(), [RecipeBundle.t()]}

  @type compile_cache :: %{optional(Segment.id()) => compiled_segment()}

  @doc "编译单个 Segment 为可执行的 RecipeBundle。"
  @spec compile_segment(Segment.t(), compile_cache()) ::
          {:ok, compiled_segment()}
          | {:error, term()}
  def compile_segment(%Segment{} = segment, cache \\ %{}) do
    with :error <- Map.fetch(cache, segment.id),
         {effective_graph, interventions} <- resolve_effective_state(segment),
         cluster <- Map.get(segment, :cluster) || %Graph.Cluster{},
         {:ok, static_recipes} <-
           Equinox.Kernel.GraphBuilder.compile_graph(effective_graph, cluster) do
      bundles =
        RecipeBundle.bind_interventions(
          static_recipes,
          interventions,
          Map.get(segment, :data_interventions, %{})
        )

      {:ok, {segment.id, effective_graph, interventions, bundles}}
    else
      {:ok, {cached_graph, cached_interventions, cached_recipe_bundles}} ->
        {:ok, {segment.id, cached_graph, cached_interventions, cached_recipe_bundles}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc "编译 Segment 列表为可执行的 RecipeBundle。"
  @spec compile_to_recipes([Segment.t()], compile_cache()) ::
          {:ok, [{Segment.id(), [RecipeBundle.t()]}]} | {:error, term()}
  def compile_to_recipes(segments, cache \\ %{})

  def compile_to_recipes(%Segment{} = segment, cache), do: compile_to_recipes([segment], cache)

  def compile_to_recipes(segments, cache) when is_list(segments) and is_map(cache) do
    with {:ok, compiled_segments} <- compile_segments(segments, cache) do
      {:ok,
       Enum.map(compiled_segments, fn {segment_id, _graph, _interventions, bundles} ->
         {segment_id, bundles}
       end)}
    end
  end

  defp compile_segments(segments, cache) do
    {cached_segments, uncached_segments} = Enum.split_with(segments, &Map.has_key?(cache, &1.id))

    cached_results =
      Enum.map(cached_segments, fn segment ->
        {:ok, {cached_graph, cached_interventions, cached_recipe_bundles}} =
          Map.fetch(cache, segment.id)

        {segment.id, cached_graph, cached_interventions, cached_recipe_bundles}
      end)

    resolved_items =
      Enum.map(uncached_segments, fn segment ->
        {effective_graph, interventions} = resolve_effective_state(segment)

        %{segment: segment, graph: effective_graph, interventions: interventions}
      end)

    grouped_by_topology = Enum.group_by(resolved_items, &{&1.graph, &1.segment.cluster})

    apply_bundles = fn item, static_recipes ->
      bundles =
        RecipeBundle.bind_interventions(
          static_recipes,
          item.interventions,
          Map.get(item.segment, :data_interventions, %{})
        )

      {item.segment.id, item.graph, item.interventions, bundles}
    end

    Enum.reduce_while(grouped_by_topology, {:ok, cached_results}, fn {{graph, cluster}, items},
                                                                     {:ok, acc} ->
      case Equinox.Kernel.GraphBuilder.compile_graph(graph, cluster) do
        {:ok, static_recipes} ->
          compiled_segments = Enum.map(items, &apply_bundles.(&1, static_recipes))
          {:cont, {:ok, acc ++ compiled_segments}}

        {:error, _reason} = err ->
          {:halt, err}
      end
    end)
  end

  defp resolve_effective_state(%Segment{} = segment) do
    graph = segment.graph || %Graph{}

    case Map.get(segment, :history) do
      %History{} = history -> History.Resolver.resolve(history, graph)
      _ -> {graph, %{}}
    end
  end
end
