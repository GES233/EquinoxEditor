defmodule Equinox.Domain.Segment do
  @moduledoc """
  增量生成的最小单元 (VO)。

  持有 Notes 和 Curves （extra interventions），供编译器生成 Orchid Graph。
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
          # 这个 `synth_override` 貌似可以作为
          # 相比于此 Track 的 diff （以 History record 的形式记录）。
          synth_override: map() | nil,
          graph: Graph.t(Orchid.Step.implementation()) | nil,
          cluster: Cluster.t() | nil,
          extra: map()
        }

  defstruct [
    :id,
    :track_id,
    :name,
    offset_tick: 0,
    notes: [],
    curves: %{},
    synth_override: nil,
    graph: nil,
    cluster: nil,
    extra: %{}
  ]

  @spec new(Equinox.Util.Attrs.attributes()) :: t()
  def new(attrs \\ %{}) do
    attrs = Equinox.Util.Attrs.normalize(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, Equinox.Util.Id.generate()),
      track_id: Map.get(attrs, :track_id),
      name: Map.get(attrs, :name, "New Segment"),
      offset_tick: Map.get(attrs, :offset_tick, 0),
      notes: Map.get(attrs, :notes, []),
      curves: Map.get(attrs, :curves, %{}),
      synth_override: Map.get(attrs, :synth_override),
      graph: Map.get(attrs, :graph),
      cluster: Map.get(attrs, :cluster),
      extra: Map.get(attrs, :extra, %{})
    }
  end

  @doc "从 JSON Map 反序列化并构造嵌套结构体"
  def from_attrs(attrs) do
    attrs = Equinox.Util.Attrs.normalize(attrs)

    notes =
      Map.get(attrs, :notes, [])
      |> Enum.map(&Equinox.Domain.Note.new/1)

    attrs
    |> Map.put(:notes, notes)
    |> new()
  end
end

defimpl Jason.Encoder, for: Equinox.Domain.Segment do
  def encode(segment, opts) do
    # 明确指定需要序列化的纯数据字段
    map = %{
      id: segment.id,
      track_id: segment.track_id,
      name: segment.name,
      offset_tick: segment.offset_tick,
      notes: segment.notes,
      curves: segment.curves,
      synth_override: segment.synth_override,
      extra: segment.extra
    }

    Jason.Encode.map(map, opts)
  end
end
