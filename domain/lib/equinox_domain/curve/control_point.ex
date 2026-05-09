defmodule EquinoxDomain.Curve.ControlPoint do
  # 控制点
  # tick 为相对于所在 Chunk.start_tick 的偏移

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          value: float()
        }
  use EquinoxDomain.Util.Object, keys: [:tick, :value]
end
