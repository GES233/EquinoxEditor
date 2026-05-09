defmodule EquinoxDomain.Curve.Chunk do
  # 一条曲线段
  # adapter + container 模式，类似 Key 的 behaviour + Inner protocol
  # container.points[].tick 为相对 start_tick 的偏移

  alias EquinoxDomain.Util.ID

  @type t :: %__MODULE__{
          id: ID.t(),
          adapter: module(),
          container: struct(),
          start_tick: non_neg_integer(),
          end_tick: non_neg_integer(),
          rasterized: term() | nil,
          extra: map()
        }
  use EquinoxDomain.Util.Model,
    keys: [:id, :adapter, :container, :start_tick, :end_tick, rasterized: nil, extra: %{}],
    id_prefix: "CurveChunk_"
end
