defmodule Equinox.Kernel.SvelteFlowTranslator do
  @moduledoc """
  负责将前端 SvelteFlow 的纯数据结构 (nodes, edges JSON arrays) 转换为 `Equinox.Kernel.Graph`。
  """

  alias Equinox.Kernel.{Graph, StepRegistry}

  @doc """
  将 SvelteFlow 传来的 Nodes/Edges 原生 JSON 转换为 Graph 结构体。
  由于我们要把所有的位置和展示信息存储到 Node.extra 中，此方法用于前端反序列化。
  """
  @spec from_svelte_payload(list(map()), list(map())) :: {:ok, Graph.t()} | {:error, term()}
  def from_svelte_payload(raw_nodes, raw_edges) do
    build_graph(raw_nodes, raw_edges)
  end

  defp build_graph(raw_nodes, raw_edges) when is_list(raw_nodes) and is_list(raw_edges) do
    graph = Graph.new()

    # 1. 转换 Nodes
    graph =
      Enum.reduce(raw_nodes, graph, fn raw_node, acc_graph ->
        case build_node(raw_node) do
          {:ok, node} -> Graph.add_node(acc_graph, node)
          # 忽略未注册的未知节点
          {:error, _} -> acc_graph
        end
      end)

    # 2. 转换 Edges
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

    # 优先使用 module 作为 step_name
    module_str = data["module"] || data[:module] || ""

    step_name =
      StepRegistry.list_all()
      |> Enum.find_value(nil, fn {name, spec} ->
        if to_string(spec.module) == module_str, do: name, else: nil
      end)

    # 退路：根据 label 找 (仅作冗余)
    step_name = step_name || (data["label"] || data[:label]) |> normalize_step_name()

    properties = data["properties"] || data[:properties] || %{}

    # 转换 Properties 的 keys 为 atom，配合 Keyword list 要求
    options =
      Enum.map(properties, fn {k, v} ->
        {if(is_binary(k), do: String.to_atom(k), else: k), v}
      end)

    if step_name do
      case StepRegistry.create_node(step_name, Keyword.put(options, :id, id)) do
        {:ok, node} ->
          # 存储所有额外的 SvelteFlow 属性到 extra
          extra_data = Map.drop(raw_node, ["id", "data", :id, :data])
          node_with_extra = %{node | extra: extra_data}
          {:ok, node_with_extra}

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
