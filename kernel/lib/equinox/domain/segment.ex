defmodule Equinox.Domain.Segment do
  @moduledoc """
  【冻结】遗留类型，Phase 2 将由 EquinoxDomain/zongzi 类型取代，禁止新增依赖。
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
          graph: Graph.t() | nil,
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
end
