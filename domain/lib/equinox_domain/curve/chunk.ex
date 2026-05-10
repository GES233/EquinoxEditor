defmodule EquinoxDomain.Curve.Chunk do
  # 一条曲线段
  # adapter + container 模式，类似 Key 的 behaviour + Inner protocol
  # container.points[].tick 为相对 start_tick 的偏移
  # end_tick 通过 Inner.span(container) + start_tick 按需计算，不存储

  alias EquinoxDomain.Util.ID

  @type t :: %__MODULE__{
          id: ID.t(),
          adapter: module(),
          container: struct(),
          start_tick: non_neg_integer(),
          rasterized: term() | nil,
          extra: map()
        }
  use EquinoxDomain.Util.Model,
    keys: [:id, :adapter, :container, :start_tick, rasterized: nil, extra: %{}],
    id_prefix: "CurveChunk_"
end
