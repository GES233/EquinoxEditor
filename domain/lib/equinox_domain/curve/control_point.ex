defmodule EquinoxDomain.Curve.ControlPoint do
  # --------------------------------------------------
  # tick: non_neg_integer  (Chunk.start_tick  + offset)
  # value: float           (parameter value, e.g. cents, ratio)
  #
  # handle_left / handle_right  are MEANS of Bezier
  # nil  -> auto (1/3 rule or mirror)
  # %{tick: integer(), value: float()}  -> offset from anchor
  #
  # CatmullRom / Linear / Step ignore these handles.
  # --------------------------------------------------

  @type handle :: %{tick: integer(), value: float()} | nil

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          value: float(),
          handle_left: handle(),
          handle_right: handle()
        }

  use EquinoxDomain.Util.Object, keys: [:tick, :value, handle_left: nil, handle_right: nil]
end
