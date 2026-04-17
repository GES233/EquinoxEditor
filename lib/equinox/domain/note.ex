defmodule Equinox.Domain.Note do
  @moduledoc """
  离散音符事件 (Pure Data)。
  采用 Tick 作为绝对时间单位。
  """

  @type id :: String.t()

  @type t :: %__MODULE__{
          id: id(),
          start_tick: non_neg_integer(),
          duration_tick: pos_integer(),
          key: integer(),
          lyric: String.t(),
          phoneme: String.t() | nil,
          extra: map()
        }

  @derive {Jason.Encoder, only: [:id, :start_tick, :duration_tick, :key, :lyric, :phoneme, :extra]}
  defstruct [:id, :start_tick, :duration_tick, :key, :lyric, :phoneme, extra: %{}]

  def new(attrs \\ %{}) do
    attrs = normalize_keys(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      start_tick: Map.get(attrs, :start_tick, 0),
      duration_tick: Map.get(attrs, :duration_tick, 480),
      key: Map.get(attrs, :key, 60),
      lyric: Map.get(attrs, :lyric, "la"),
      phoneme: Map.get(attrs, :phoneme),
      extra: Map.get(attrs, :extra, %{})
    }
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
