defmodule EquinoxDomain.Note do
  @moduledoc """
  有关音符的领域模型。
  """
  import EquinoxDomain.Helpers

  @keys [:id, :start_tick, :duration_tick, :key, :lyric, :slice_flag, :annotation, :extra]
  defstruct @keys

  def new(attrs) do
    attrs
    |> normalize_attrs(@keys)
    |> Map.pop(:id, dynamic_id())
    |> then(fn {id, attrs} -> struct!(%__MODULE__{}, Map.merge(attrs, %{id: id})) end)
  end
end
