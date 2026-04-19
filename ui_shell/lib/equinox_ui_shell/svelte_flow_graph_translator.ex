defmodule EquinoxUiShell.SvelteFlowGraphTranslator do
  @moduledoc """
  将 SvelteFlow payload 转换为 `Equinox.Kernel.Graph`。
  """

  @behaviour Equinox.Kernel.GraphTranslator

  alias Equinox.Kernel.{Graph, StepRegistry}

  @impl true
  def to_graph(raw_nodes, raw_edges) do
    build_graph(raw_nodes, raw_edges)
  end

  defp build_graph(raw_nodes, raw_edges) when is_list(raw_nodes) and is_list(raw_edges) do
    graph = Graph.new()

    graph =
      Enum.reduce(raw_nodes, graph, fn raw_node, acc_graph ->
        case build_node(raw_node) do
          {:ok, node} -> Graph.add_node(acc_graph, node)
          {:error, _} -> acc_graph
        end
      end)

    graph =
      Enum.reduce(raw_edges, graph, fn raw_edge, acc_graph ->
        case build_edge(raw_edge) do
          {:ok, edge} -> Graph.add_edge(acc_graph, edge)
          {:error, _} -> acc_graph
        end
      end)

    {:ok, graph}
  end

  defp build_graph(_, _), do: {:ok, Graph.new()}

  defp build_node(raw_node) do
    id = raw_node["id"] || raw_node[:id]
    data = raw_node["data"] || raw_node[:data] || %{}
    module_str = data["module"] || data[:module] || ""

    step_name =
      StepRegistry.list_all()
      |> Enum.find_value(nil, fn {name, spec} ->
        if to_string(spec.module) == module_str, do: name, else: nil
      end)

    step_name = step_name || (data["label"] || data[:label]) |> normalize_step_name()
    properties = data["properties"] || data[:properties] || %{}

    options =
      Enum.map(properties, fn {k, v} ->
        {if(is_binary(k), do: String.to_atom(k), else: k), v}
      end)

    if step_name do
      case StepRegistry.create_node(step_name, Keyword.put(options, :id, id)) do
        {:ok, node} ->
          extra_data = Map.drop(raw_node, ["id", "data", :id, :data])
          {:ok, %{node | extra: extra_data}}

        error ->
          error
      end
    else
      {:error, :unknown_node_type}
    end
  end

  defp build_edge(raw_edge) do
    source = raw_edge["source"] || raw_edge[:source]
    source_handle = raw_edge["sourceHandle"] || raw_edge[:sourceHandle]
    target = raw_edge["target"] || raw_edge[:target]
    target_handle = raw_edge["targetHandle"] || raw_edge[:targetHandle]

    if source && target && source_handle && target_handle do
      {:ok, Graph.Edge.new(source, source_handle, target, target_handle)}
    else
      {:error, :invalid_edge_format}
    end
  end

  defp normalize_step_name(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(" ", "_") |> String.to_atom()
  end

  defp normalize_step_name(name) when is_atom(name), do: name
  defp normalize_step_name(_), do: nil
end
