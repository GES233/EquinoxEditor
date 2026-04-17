defmodule Equinox.Editor.Segment do
  @moduledoc """
  增量生成的最小单元 (Pure Data)。
  持有 Notes 和 Curves，供编译器生成 Orchid Graph。
  如果作为特殊 Override，可选持有 graph 结构（但序列化时会忽略）。
  """

  alias Equinox.Kernel.{Graph, Graph.Cluster}

  @type id :: atom() | String.t()

  @type t :: %__MODULE__{
          id: id(),
          track_id: atom() | String.t() | nil,
          name: String.t(),
          offset_tick: non_neg_integer(),
          notes: [Equinox.Domain.Note.t()],
          curves: map(),
          graph: Graph.t(Orchid.Step.implementation()) | nil,
          cluster: Cluster.t() | nil,
          extra: map()
        }

  # 这里不使用 @derive，而是使用 defimpl 手动丢弃 graph 和 cluster
  defstruct [
    :id,
    :track_id,
    name: "New Segment",
    offset_tick: 0,
    notes: [],
    curves: %{},
    graph: nil,
    cluster: nil,
    extra: %{}
  ]

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      track_id: Map.get(attrs, :track_id),
      name: Map.get(attrs, :name, "New Segment"),
      offset_tick: Map.get(attrs, :offset_tick, 0),
      notes: Map.get(attrs, :notes, []),
      curves: Map.get(attrs, :curves, %{}),
      graph: Map.get(attrs, :graph),
      cluster: Map.get(attrs, :cluster),
      extra: Map.get(attrs, :extra, %{})
    }
  end

  @doc "从 JSON Map 反序列化并构造嵌套结构体"
  def from_attrs(attrs) do
    attrs = normalize_keys(attrs)

    notes =
      Map.get(attrs, :notes, [])
      |> Enum.map(&Equinox.Domain.Note.new/1)

    attrs
    |> Map.put(:notes, notes)
    |> new()
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp normalize_keys(map_or_kw) do
    map_or_kw
    |> Enum.into(%{})
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end
end

defimpl Jason.Encoder, for: Equinox.Editor.Segment do
  def encode(segment, opts) do
    # 明确指定需要序列化的纯数据字段
    map = %{
      id: segment.id,
      track_id: segment.track_id,
      name: segment.name,
      offset_tick: segment.offset_tick,
      notes: segment.notes,
      curves: segment.curves,
      extra: segment.extra
    }
    Jason.Encode.map(map, opts)
  end
end
