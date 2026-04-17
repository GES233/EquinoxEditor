defmodule Equinox.Editor.Segment do
  @moduledoc """
  增量生成的最小单元，属于某个 Track。
  持有静态拓扑、用户编辑历史和缓存的运行时引用。
  """

  alias Equinox.Editor.History
  alias Equinox.Kernel.{Graph, Graph.Cluster}

  @type interventions_map :: %{
          Graph.PortRef.t() => OrchidIntervention.intervention_spec()
        }

  @type id :: atom() | String.t()

  @type t :: %__MODULE__{
          id: id(),
          track_id: atom() | String.t() | nil,
          topology_ref: String.t() | nil,
          graph: Graph.t(Orchid.Step.implementation()),
          cluster: Cluster.t(),
          history: History.t(),
          data_interventions: interventions_map(),
          extra: map()
        }

  defstruct [
    :id,
    :track_id,
    :topology_ref,
    graph: %Graph{},
    cluster: %Cluster{},
    history: %History{},
    data_interventions: %{},
    extra: %{}
  ]

  @spec new(id(), Graph.t()) :: t()
  @spec new(id(), Graph.t(), keyword()) :: t()
  def new(id, graph, opts \\ []) do
    cluster_declaration = Keyword.get(opts, :cluster, %Cluster{})
    track_id = Keyword.get(opts, :track_id)
    topology_ref = Keyword.get(opts, :topology_ref)

    %__MODULE__{
      id: id,
      track_id: track_id,
      topology_ref: topology_ref,
      graph: graph,
      cluster: cluster_declaration,
      history: History.new()
    }
  end

  @spec inject_graph_and_interventions(t(), Graph.t(), map(), boolean()) :: t()
  def inject_graph_and_interventions(
        %__MODULE__{} = segment,
        %Graph{} = graph,
        data_interventions,
        clear_history \\ true
      ) do
    history = if clear_history, do: %History{}, else: segment.history

    %{segment | graph: graph, data_interventions: data_interventions, history: history}
  end

  @spec apply_operation(t(), History.Operation.t()) :: t()
  def apply_operation(%__MODULE__{} = segment, operation) do
    %{segment | history: History.push(segment.history, operation)}
  end

  @spec undo(t()) :: {t(), History.Operation.t() | nil}
  def undo(%__MODULE__{} = segment) do
    {his, op} = History.undo(segment.history)
    {%{segment | history: his}, op}
  end

  @spec redo(t()) :: {t(), History.Operation.t() | nil}
  def redo(%__MODULE__{} = segment) do
    {his, op} = History.redo(segment.history)
    {%{segment | history: his}, op}
  end
end
