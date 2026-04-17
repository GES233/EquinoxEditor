defmodule Equinox.Kernel.Graph do
  @moduledoc """
  DAG 的纯数学表示。
  提供 Node / Edge / PortRef / Cluster 数据结构、环检测和拓扑排序。
  """

  defmodule Node do
    @moduledoc "DAG 中计算步骤的纯数据表示。"

    @type id :: atom() | String.t()
    @type node_port :: atom() | binary()

    @type t(type) :: %__MODULE__{
            id: id(),
            container: type,
            inputs: [node_port()],
            outputs: [node_port()],
            options: keyword(),
            extra: map()
          }
    @type t() :: t(term())

    defstruct [:id, :container, inputs: [], outputs: [], options: [], extra: %{}]
  end

  defmodule Edge do
    @moduledoc "有向边，表示两个节点端口之间的数据流。"

    @type t :: %__MODULE__{
            from_node: Node.id(),
            from_port: Node.node_port(),
            to_node: Node.id(),
            to_port: Node.node_port()
          }

    defstruct [:from_node, :from_port, :to_node, :to_port]

    @spec new(Node.id(), Node.node_port(), Node.id(), Node.node_port()) :: t()
    def new(from_node, from_port, to_node, to_port) do
      %__MODULE__{
        from_node: from_node,
        from_port: from_port,
        to_node: to_node,
        to_port: to_port
      }
    end
  end

  defmodule PortRef do
    @moduledoc "基于节点/端口表示的容器，用于动态生成 Orchid key。"

    @type t :: {:port, node :: Node.id(), Node.node_port()}

    @spec to_orchid_key(t()) :: String.t()
    def to_orchid_key({:port, node, port}) do
      to_string(node) <> "|" <> parse_port(port)
    end

    defp parse_port(p) when is_binary(p), do: p
    defp parse_port(p) when is_atom(p), do: Atom.to_string(p)
  end

  defmodule Cluster do
    @moduledoc """
    根据用户选择和依赖关系进行集群划分，
    实现资源密集型服务的隔离，将并行任务转换为串行+并行混合过程。
    """

    alias Equinox.Kernel.Graph.{Node, Edge}

    @type cluster_name :: atom() | String.t() | [cluster_name()]

    @type t :: %__MODULE__{
            node_colors: %{Node.id() => cluster_name()},
            merge_groups: [{cluster_name() | MapSet.t(cluster_name()), cluster_name()}]
          }

    defstruct node_colors: %{}, merge_groups: []

    @spec paint_graph([Node.id()], MapSet.t(Edge.t()), t()) :: %{Node.id() => cluster_name()}
    def paint_graph(sorted_nodes, edges, %__MODULE__{} = clusters) do
      sorted_nodes
      |> Enum.reduce(%{}, fn node_id, color_map ->
        explicit_color =
          case Map.get(clusters.node_colors, node_id) do
            nil -> get_upstream_colors(node_id, edges, color_map)
            explicit_color -> explicit_color
          end

        Map.put(color_map, node_id, explicit_color)
      end)
      |> Enum.map(fn {k, v} ->
        {k,
         case v do
           v when is_list(v) -> Enum.sort(v)
           v -> v
         end}
      end)
      |> Enum.into(%{})
    end

    defp get_upstream_colors(node_id, edges, color_map) do
      upstream =
        edges
        |> Enum.filter(&(&1.to_node == node_id))
        |> Enum.map(&Map.get(color_map, &1.from_node, :default_cluster))
        |> List.flatten()
        |> Enum.uniq()

      case upstream do
        [] -> :default_cluster
        [single] -> single
        multiple -> multiple
      end
    end
  end

  @type t(container_type) :: %__MODULE__{
          nodes: %{Node.id() => Node.t(container_type)},
          edges: MapSet.t(Edge.t()),
          in_edges: %{Node.id() => [Edge.t()]},
          out_edges: %{Node.id() => [Edge.t()]}
        }
  @type t() :: t(term())

  defstruct nodes: %{}, edges: MapSet.new(), in_edges: %{}, out_edges: %{}

  def new do
    %__MODULE__{
      nodes: %{},
      edges: MapSet.new(),
      in_edges: %{},
      out_edges: %{}
    }
  end

  @spec same?(t(), t()) :: boolean()
  def same?(graph1, graph2), do: graph1 == graph2

  @spec add_node(t(), Node.t()) :: t()
  def add_node(%__MODULE__{nodes: old_nodes} = graph, %Node{id: node_id} = node) do
    %{
      graph
      | nodes: Map.put(old_nodes, node_id, node),
        in_edges: Map.put_new(graph.in_edges, node_id, []),
        out_edges: Map.put_new(graph.out_edges, node_id, [])
    }
  end

  @spec remove_node(t(), Node.id()) :: t()
  def remove_node(%__MODULE__{nodes: nodes} = graph, node_id) do
    case nodes[node_id] do
      nil ->
        graph

      _ ->
        in_edges_to_remove = Map.get(graph.in_edges, node_id, [])
        out_edges_to_remove = Map.get(graph.out_edges, node_id, [])
        edges_to_remove = in_edges_to_remove ++ out_edges_to_remove

        new_edges = Enum.reduce(edges_to_remove, graph.edges, &MapSet.delete(&2, &1))

        new_in_edges =
          Enum.reduce(out_edges_to_remove, graph.in_edges, fn edge, acc ->
            Map.update!(acc, edge.to_node, &List.delete(&1, edge))
          end)
          |> Map.delete(node_id)

        new_out_edges =
          Enum.reduce(in_edges_to_remove, graph.out_edges, fn edge, acc ->
            Map.update!(acc, edge.from_node, &List.delete(&1, edge))
          end)
          |> Map.delete(node_id)

        %{
          graph
          | nodes: Map.delete(graph.nodes, node_id),
            edges: new_edges,
            in_edges: new_in_edges,
            out_edges: new_out_edges
        }
    end
  end

  @spec update_node(t(), Node.id(), Node.t() | (Node.t() -> Node.t())) :: t()
  def update_node(%__MODULE__{nodes: nodes} = graph, node_id, new_node) do
    case nodes[node_id] do
      nil ->
        graph

      %Node{} = old_node ->
        updated =
          case new_node do
            new_node when is_function(new_node, 1) -> new_node.(old_node)
            _ -> new_node
          end

        %{graph | nodes: Map.put(nodes, node_id, updated)}
    end
  end

  @spec add_edge(t(), Edge.t()) :: t()
  def add_edge(%__MODULE__{} = graph, edge) do
    cond do
      edge.from_node == edge.to_node ->
        graph

      MapSet.member?(graph.edges, edge) ->
        graph

      true ->
        %{
          graph
          | edges: MapSet.put(graph.edges, edge),
            in_edges: Map.update(graph.in_edges, edge.to_node, [edge], &[edge | &1]),
            out_edges: Map.update(graph.out_edges, edge.from_node, [edge], &[edge | &1])
        }
    end
  end

  @spec remove_edge(t(), Edge.t()) :: t()
  def remove_edge(%__MODULE__{edges: edges} = graph, edge) do
    %{
      graph
      | edges: MapSet.delete(edges, edge),
        in_edges: Map.update(graph.in_edges, edge.to_node, [], &List.delete(&1, edge)),
        out_edges: Map.update(graph.out_edges, edge.from_node, [], &List.delete(&1, edge))
    }
  end

  @spec get_in_edges(t(), Node.id()) :: [Edge.t()]
  def get_in_edges(%__MODULE__{} = graph, node_id) do
    Map.get(graph.in_edges, node_id, [])
  end

  @spec get_out_edges(t(), Node.id()) :: [Edge.t()]
  def get_out_edges(%__MODULE__{} = graph, node_id) do
    Map.get(graph.out_edges, node_id, [])
  end

  @spec topological_sort(t()) :: {:ok, [Node.id()]} | {:error, :cycle_detected}
  def topological_sort(%__MODULE__{} = graph) do
    in_degrees =
      Map.new(graph.nodes, fn {id, _node} ->
        {id, length(Map.get(graph.in_edges, id, []))}
      end)

    zero_in_degree_nodes =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _degree} -> id end)

    do_topo_sort(zero_in_degree_nodes, in_degrees, graph.out_edges, map_size(graph.nodes), [])
  end

  defp do_topo_sort([], _in_degrees, _out_edges, total_nodes, sorted_acc) do
    if length(sorted_acc) == total_nodes do
      {:ok, Enum.reverse(sorted_acc)}
    else
      {:error, :cycle_detected}
    end
  end

  defp do_topo_sort([node_id | rest_zero_nodes], in_degrees, out_edges, total, sorted_acc) do
    edges = Map.get(out_edges, node_id, [])

    {new_in_degrees, new_zero_nodes} =
      Enum.reduce(edges, {in_degrees, rest_zero_nodes}, fn edge, {deg_acc, zero_acc} ->
        to_node = edge.to_node
        new_deg = deg_acc[to_node] - 1
        deg_acc = Map.put(deg_acc, to_node, new_deg)

        case new_deg do
          0 -> {deg_acc, [to_node | zero_acc]}
          _ -> {deg_acc, zero_acc}
        end
      end)

    do_topo_sort(new_zero_nodes, new_in_degrees, out_edges, total, [node_id | sorted_acc])
  end
end
