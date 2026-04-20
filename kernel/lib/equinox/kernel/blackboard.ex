defmodule Equinox.Kernel.Blackboard do
  @moduledoc """
  增量生成结果的运行时内存视图。
  作为 Worker 和底层存储之间的读写接口。
  """

  alias Equinox.Domain.Segment

  @type addr :: {Segment.id(), Orchid.Step.io_key()}

  @type t :: %__MODULE__{
          memory: %{addr() => Orchid.Param.t() | any()}
        }

  defstruct memory: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{memory: %{}}

  @spec put(t(), %{addr() => term()}) :: t()
  def put(%__MODULE__{} = board, new_data) when is_map(new_data) do
    %{board | memory: Map.merge(board.memory, new_data)}
  end

  @spec fetch_contents(t(), [addr()]) :: %{addr() => term()}
  def fetch_contents(%__MODULE__{memory: mem}, required_keys) do
    required_keys
    |> Enum.map(fn key -> {key, Map.get(mem, key)} end)
    |> Enum.into(%{})
  end

  @spec fetch_via_segment(t(), Segment.id()) :: %{addr() => term()}
  def fetch_via_segment(%__MODULE__{memory: mem} = blackboard, segment_id) do
    mem
    |> Map.keys()
    |> Enum.filter(fn {sid, _} -> sid == segment_id end)
    |> then(&fetch_contents(blackboard, &1))
  end
end
