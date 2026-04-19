defmodule Equinox.Editor.History do
  @moduledoc """
  操作历史记录，支持撤销/重做。
  """

  defmodule Operation do
    @moduledoc "记录编辑操作。"

    alias Equinox.Kernel.Graph.{Node, Edge, PortRef}

    @type intervention_type :: :input | :override | :offset | :mask | atom()

    @typedoc "DAG 拓扑变更。"
    @type topology_mutation ::
            {:add_node, Node.t()}
            | {:update_node, Node.id(), Node.t() | (Node.t() -> Node.t())}
            | {:remove_node, Node.id()}
            | {:add_edge, Edge.t()}
            | {:remove_edge, Edge.t()}

    @typedoc "数据干预操作。"
    @type data_interventions ::
            {:set_intervention, PortRef.t(), OrchidIntervention.intervention_type(),
             OrchidIntervention.payload()}
            | {:clear_intervention, PortRef.t()}
            | nil

    @type single_op :: topology_mutation() | data_interventions()
    @type t :: single_op() | [single_op()]

    @spec topology?(single_op()) :: boolean()
    def topology?(op)
        when elem(op, 0) in [:add_node, :update_node, :remove_node, :add_edge, :remove_edge],
        do: true

    def topology?(_), do: false
  end

  @type t :: %__MODULE__{
          undo_stack: [Operation.t()],
          redo_stack: [Operation.t()]
        }

  defstruct undo_stack: [], redo_stack: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec push(t(), Operation.t()) :: t()
  def push(%__MODULE__{undo_stack: undo} = history, op) do
    %{history | undo_stack: [op | undo], redo_stack: []}
  end

  @spec undo(t()) :: {t(), Operation.t() | nil}
  def undo(%__MODULE__{undo_stack: []} = history), do: {history, nil}

  def undo(%__MODULE__{undo_stack: [last_op | rest_undo], redo_stack: redo} = history) do
    {%{history | undo_stack: rest_undo, redo_stack: [last_op | redo]}, last_op}
  end

  @spec redo(t()) :: {t(), Operation.t() | nil}
  def redo(%__MODULE__{redo_stack: []} = history), do: {history, nil}

  def redo(%__MODULE__{undo_stack: undo, redo_stack: [next_op | rest_redo]} = history) do
    {%{history | undo_stack: [next_op | undo], redo_stack: rest_redo}, next_op}
  end
end
