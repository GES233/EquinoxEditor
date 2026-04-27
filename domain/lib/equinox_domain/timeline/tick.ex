defmodule EquinoxDomain.Timeline.Tick do
  @behaviour EquinoxDomain.Util.Model.Pickle

  # 刻
  @type t :: non_neg_integer()

  # 按照习惯来
  @ticks_per_quarter_note 480

  def ticks_per_quarter_note, do: @ticks_per_quarter_note

  @impl true
  def serialize(tick) when is_integer(tick) and tick >= 0, do: {:ok, tick}
  def serialize(tick), do: {:error, {:invalid_data, __MODULE__, tick}}

  @impl true
  def deserialize(tick) when is_integer(tick) and tick >= 0, do: {:ok, tick}
  def deserialize(tick), do: {:error, {:invalid_data, __MODULE__, tick}}
end
