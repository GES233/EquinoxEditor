defmodule Equinox.Kernel.GraphBuilder do
  @moduledoc """
  负责将 `Equinox.Kernel.Graph` 转换为 Orchid Recipe 及其关联实体（`RecipeBundle`）。
  """

  alias Equinox.Kernel.{Graph, Graph.PortRef, Graph.Cluster, RecipeBundle}

  @doc "将纯结构图编译为通用的隔离静态 recipe。"
  @spec compile_graph(Graph.t(Orchid.Step.implementation()), Cluster.t()) ::
          {:error, :cycle_detected} | {:ok, [RecipeBundle.t()]}
  def compile_graph(%Graph{} = graph, cluster_declaration \\ %Cluster{}) do
    with {:ok, sorted_node_ids} <- Graph.topological_sort(graph) do
      node_colors = Cluster.paint_graph(sorted_node_ids, graph.edges, cluster_declaration)

      static_recipes =
        sorted_node_ids
        |> Enum.group_by(&Map.get(node_colors, &1, :default_cluster))
        |> Enum.map(fn {cluster_name, node_ids_in_cluster} ->
          build_recipe(cluster_name, node_ids_in_cluster, graph)
        end)

      {:ok, static_recipes}
    end
  end

  defp build_recipe(cluster_name, node_ids, graph) do
    steps =
      node_ids
      |> Enum.map(&Map.fetch!(graph.nodes, &1))
      |> Enum.map(&node_to_step(&1, graph))

    {requires, exports} = calculate_boundaries(node_ids, graph)

    %RecipeBundle{
      recipe: Orchid.Recipe.new(steps, name: cluster_name),
      requires: requires,
      exports: exports,
      node_ids: node_ids
    }
  end

  defp node_to_step(%Graph.Node{} = node, graph) do
    in_edges = Graph.get_in_edges(graph, node.id)

    step_inputs =
      Enum.map(node.inputs, fn port_name ->
        case Enum.find(in_edges, &(&1.to_port == port_name)) do
          nil -> PortRef.to_orchid_key({:port, node.id, port_name})
          edge -> PortRef.to_orchid_key({:port, edge.from_node, edge.from_port})
        end
      end)
      |> case do
        [single] -> single
        other -> other
      end

    step_outputs =
      Enum.map(node.outputs, fn p -> PortRef.to_orchid_key({:port, node.id, p}) end)
      |> case do
        [single] -> single
        other -> other
      end

    {node.container, step_inputs, step_outputs, node.options}
  end

  defp calculate_boundaries(node_ids_in_cluster, graph) do
    cluster_nodes_set = MapSet.new(node_ids_in_cluster)

    external_edges =
      graph.edges
      |> Enum.reject(&(&1.from_node in cluster_nodes_set and &1.to_node in cluster_nodes_set))

    in_keys =
      external_edges
      |> Enum.filter(&(&1.to_node in cluster_nodes_set))
      |> Enum.map(&PortRef.to_orchid_key({:port, &1.from_node, &1.from_port}))

    out_keys =
      external_edges
      |> Enum.filter(&(&1.from_node in cluster_nodes_set))
      |> Enum.map(&PortRef.to_orchid_key({:port, &1.from_node, &1.from_port}))

    dangling_inputs =
      Enum.flat_map(node_ids_in_cluster, &get_dangling_port(&1, graph, :inputs))

    dangling_outputs =
      Enum.flat_map(node_ids_in_cluster, &get_dangling_port(&1, graph, :outputs))

    {Enum.uniq(in_keys ++ dangling_inputs), Enum.uniq(out_keys ++ dangling_outputs)}
  end

  defp get_dangling_port(current_node_id, graph, direction) do
    node = graph.nodes[current_node_id]
    ports = if direction == :outputs, do: node.outputs, else: node.inputs
    match_field = if direction == :outputs, do: :from_port, else: :to_port
    group_func = if direction == :outputs, do: & &1.from_node, else: & &1.to_node

    edges =
      graph.edges
      |> Enum.group_by(group_func)
      |> Map.get(current_node_id, [])

    ports
    |> Enum.reject(fn port -> Enum.any?(edges, &(Map.get(&1, match_field) == port)) end)
    |> Enum.map(fn port -> PortRef.to_orchid_key({:port, node.id, port}) end)
  end
end
