defmodule EquinoxDomain.Timeline.Tick do
  @moduledoc "刻是编辑器的时间单位。"

  @type numeric_tick :: non_neg_integer()

  # 可能包含结束的片段是 last(最后一个音符结束, 最后的音频结束, 用户声明)
  # 但在这里先留空
  @type dynamic_tick :: :dynamic_tick

  @type t :: numeric_tick() | dynamic_tick()

  # 按照习惯来
  @ticks_per_quarter_note 480

  def get_dynamic_tick, do: :dynamic_tick

  defguard is_dynamic_tick(maybe_tick) when maybe_tick == :dynamic_tick
  defguard is_numeric_tick(maybe_tick) when is_integer(maybe_tick) and maybe_tick >= 0
  defguard is_tick(maybe_tick) when is_dynamic_tick(maybe_tick) or is_numeric_tick(maybe_tick)

  def ticks_per_quarter_note, do: @ticks_per_quarter_note

  # ---- 序列化相关 ----

  @behaviour EquinoxDomain.Util.Model.Pickle

  @impl true
  def serialize(tick) when is_dynamic_tick(tick), do: {:ok, "dynamic tick"}
  def serialize(tick) when is_numeric_tick(tick), do: {:ok, tick}
  def serialize(tick), do: {:error, {:invalid_data, __MODULE__, tick}}

  @impl true
  def deserialize("dynamic tick"), do: {:ok, :dynamic_tick}
  def deserialize(tick) when is_numeric_tick(tick), do: {:ok, tick}
  def deserialize(tick), do: {:error, {:invalid_data, __MODULE__, tick}}
end
