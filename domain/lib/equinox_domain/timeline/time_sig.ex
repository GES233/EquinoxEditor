defmodule EquinoxDomain.Timeline.TimeSig do
  @moduledoc "拍号系统的领域模型"

  alias EquinoxDomain.Timeline.Tick, as: Tk
  # 时间标注/拍号/etc.

  @type standard :: {:standard, numerator :: pos_integer(), denominator :: pos_integer()}
  @type compound :: {:compound, groupings :: [pos_integer()], denominator :: pos_integer()}
  # 散拍子
  @type free :: :san

  # 不从零开始
  @type bar :: pos_integer()

  @type t :: standard() | compound() | free()

  @typedoc "速度变化事件"
  @type time_sig_event :: {bar(), t()}

  @type time_sig_events :: [time_sig_event()] | {[time_sig_event()], last :: bar()}

  @doc "获取一个完整小节的 Tick 长度"
  def ticks_per_bar({:standard, num, den}), do: div(total_notes(num), den)
  def ticks_per_bar({:compound, groupings, den}), do: div(total_notes(Enum.sum(groupings)), den)
  def ticks_per_bar(:san), do: nil

  defp total_notes(num), do: Tk.ticks_per_quarter_note() * 4 * num
end
