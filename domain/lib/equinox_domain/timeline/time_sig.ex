defmodule EquinoxDomain.Timeline.TimeSig do
  @moduledoc "拍号系统的领域模型"

  alias EquinoxDomain.Timeline.Tick, as: Tk
  # 时间标注/拍号/etc.

  @type standard :: {:standard, numerator :: pos_integer(), denominator :: pos_integer()}
  @type compound :: {:compound, groupings :: [pos_integer()], denominator :: pos_integer()}
  # 散拍子
  @type free :: :san

  @type t :: standard() | compound() | free()

  @doc "获取一个完整小节的 Tick 长度"
  def ticks_per_bar({:standard, num, den}) do
    div(Tk.ticks_per_quarter_note() * 4 * num, den)
  end

  def ticks_per_bar({:compound, groupings, den}) do
    num = Enum.sum(groupings)
    div(Tk.ticks_per_quarter_note() * 4 * num, den)
  end

  def ticks_per_bar(:san), do: nil
end
