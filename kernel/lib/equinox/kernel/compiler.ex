defmodule Equinox.Kernel.Compiler do
  @moduledoc """
  纯函数管线的最终阶段。
  将有效的 DAG 翻译为 `Oi.Compiled`（Oi 编译产物：bundles + 执行计划）。
  """

  alias Equinox.Domain.Segment
  alias Equinox.Kernel.Graph

  @typedoc "PortRef → 干预规格（`%{input: ...}`）。"
  @type interventions_map :: %{
          Graph.PortRef.t() => OrchidIntervention.intervention_spec()
        }

  @typedoc "单个 Segment 的编译产物：生效图、存活干预与 Oi 编译结果。"
  @type compiled_segment ::
          {Segment.id(), Graph.t(), interventions_map(), Oi.Compiled.t()}

  @type compile_cache :: %{
          optional(Segment.id()) => {Graph.t(), interventions_map(), Oi.Compiled.t()}
        }

  @doc "编译单个 Segment 为可执行的 `Oi.Compiled`。"
  @spec compile_segment(Segment.t(), compile_cache()) ::
          {:ok, compiled_segment()}
          | {:error, term()}
  def compile_segment(%Segment{} = segment, cache \\ %{}) do
    case Map.fetch(cache, segment.id) do
      {:ok, {cached_graph, cached_interventions, cached_compiled}} ->
        {:ok, {segment.id, cached_graph, cached_interventions, cached_compiled}}

      :error ->
        do_compile(segment)
    end
  end

  @doc """
  批量编译 Segment 列表为 `Oi.Compiled`。

  拓扑相同（graph 与 cluster 结构相等）的 Segment 共享一次 `Oi.compile/2` 结果。
  """
  @spec compile_segments([Segment.t()], compile_cache()) ::
          {:ok, [compiled_segment()]} | {:error, term()}
  def compile_segments(segments, cache \\ %{})

  def compile_segments(%Segment{} = segment, cache), do: compile_segments([segment], cache)

  def compile_segments(segments, cache) when is_list(segments) and is_map(cache) do
    {cached_segments, uncached_segments} = Enum.split_with(segments, &Map.has_key?(cache, &1.id))

    cached_results =
      Enum.map(cached_segments, fn segment ->
        {:ok, {cached_graph, cached_interventions, cached_compiled}} =
          Map.fetch(cache, segment.id)

        {segment.id, cached_graph, cached_interventions, cached_compiled}
      end)

    resolved_items =
      Enum.map(uncached_segments, fn segment ->
        {effective_graph, interventions} = resolve_effective_state(segment)

        %{segment: segment, graph: effective_graph, interventions: interventions}
      end)

    grouped_by_topology =
      Enum.group_by(resolved_items, &{&1.graph, Map.get(&1.segment, :cluster)})

    Enum.reduce_while(grouped_by_topology, {:ok, cached_results}, fn {{graph, cluster}, items},
                                                                     {:ok, acc} ->
      case compile_graph(graph, cluster) do
        {:ok, compiled} ->
          compiled_segments =
            Enum.map(items, &{&1.segment.id, &1.graph, &1.interventions, compiled})

          {:cont, {:ok, acc ++ compiled_segments}}

        {:error, _reason} = err ->
          {:halt, err}
      end
    end)
  end

  defp do_compile(%Segment{} = segment) do
    {effective_graph, interventions} = resolve_effective_state(segment)

    case compile_graph(effective_graph, Map.get(segment, :cluster)) do
      {:ok, compiled} -> {:ok, {segment.id, effective_graph, interventions, compiled}}
      {:error, _reason} = err -> err
    end
  end

  defp compile_graph(%Graph{} = graph, cluster) do
    oi_cluster =
      case cluster do
        %Graph.Cluster{} = cluster -> Graph.Cluster.to_oi(cluster)
        _ -> %Oi.Topology.Cluster{}
      end

    graph
    |> Graph.to_oi_graph()
    |> Oi.compile(oi_cluster)
  end

  defp resolve_effective_state(%Segment{} = segment) do
    graph = segment.graph || %Graph{}

    {graph, %{}}
  end
end
