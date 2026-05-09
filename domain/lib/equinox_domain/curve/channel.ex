defmodule EquinoxDomain.Curve.Channel do
  # 曲线通道
  # Track.curve_channels 的 value，key 为 name（atom）
  # chunks 列表顺序即 z-order：后面的覆盖前面的（重叠区域）

  @type t :: %__MODULE__{
          name: atom(),
          chunks: [EquinoxDomain.Curve.Chunk.t()],
          extra: map()
        }
  use EquinoxDomain.Util.Object, keys: [:name, chunks: [], extra: %{}]
end
