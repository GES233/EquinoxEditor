defmodule EquinoxDomain.Note do
  @moduledoc """
  有关音符的领域模型。
  """
  @keys [:id, :start_tick, :duration_tick, :key, :lyric, :slice_flag, :annotation, :extra]
  defstruct @keys

  def new(attrs) do
    attrs
    |> EquinoxDomain.Helpers.normalize_attrs(@keys)
    |> then(&struct!(%__MODULE__{}, &1))
  end
end
