defmodule Equinox.Domain.Note do
  @moduledoc """
  基于时间的离散事件，比如音符。
  采用 Tick 作为绝对时间单位（避免毫秒浮点数）。
  """

  @type t :: %__MODULE__{
          id: String.t(),
          start_tick: non_neg_integer(),
          duration_tick: pos_integer(),
          # MIDI key (0-127)
          key: integer(),
          lyric: String.t(),
          phoneme: String.t() | nil,
          extra: map()
        }

  defstruct [:id, :start_tick, :duration_tick, :key, :lyric, :phoneme, extra: %{}]

  def new(opts) do
    # Orchid.Snowflake is not available in core Orchid module, use Base.encode16
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    struct!(__MODULE__, Keyword.put_new(opts, :id, id))
  end
end
