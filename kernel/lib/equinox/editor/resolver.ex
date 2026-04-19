defmodule Equinox.Editor.History.Resolver do
  @moduledoc """
  将事件溯源历史折叠到基础图上。
  分离纯结构变更和数据干预以进行性能优化。
  """

  alias Equinox.Kernel.Graph
  alias Equinox.Editor.{History, History.Operation}

  @type effective_state :: {
          Graph.t(),
          %{Graph.PortRef.t() => {Operation.intervention_type(), any()}}
        }

  @doc """
  按时间顺序将所有历史记录叠加到 `base_graph` 上。
  输出 Compiler 和 Orchid 需要的有效状态。
  """
  @spec resolve(History.t(), Graph.t()) :: effective_state()
  def resolve(%History{} = history, graph) do
    {topology_ops, data_ops} =
      history.undo_stack
      |> List.flatten()
      |> Enum.split_with(&Operation.topology?/1)

    effective_graph = apply_topology(graph, topology_ops)
    interventions = apply_interventions(data_ops)

    {effective_graph, interventions}
  end

  defp apply_topology(%Graph{} = base_graph, topology_ops) do
    topology_ops
    |> Enum.reverse()
    |> Enum.reduce(base_graph, &do_apply_topology/2)
  end

  defp do_apply_topology({:add_node, node}, graph), do: Graph.add_node(graph, node)

  defp do_apply_topology({:update_node, node_id, new_node}, graph),
    do: Graph.update_node(graph, node_id, new_node)

  defp do_apply_topology({:remove_node, node_id}, graph), do: Graph.remove_node(graph, node_id)
  defp do_apply_topology({:add_edge, edge}, graph), do: Graph.add_edge(graph, edge)
  defp do_apply_topology({:remove_edge, edge}, graph), do: Graph.remove_edge(graph, edge)

  defp apply_interventions(data_ops) do
    data_ops
    |> Enum.reverse()
    |> Enum.reduce(%{}, &do_apply_intervention/2)
  end

  defp do_apply_intervention({:set_intervention, port_ref, type, value}, acc) do
    Map.update(acc, port_ref, {type, value}, fn _old -> {type, value} end)
  end

  defp do_apply_intervention({:clear_intervention, port_ref}, acc) do
    Map.delete(acc, port_ref)
  end
end
