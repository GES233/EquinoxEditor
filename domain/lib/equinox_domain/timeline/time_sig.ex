defmodule EquinoxDomain.Timeline.TimeSig do
  @moduledoc """
  拍号系统的领域模型。

  也就是面向用户的表示时间。
  """

  alias EquinoxDomain.Timeline.Tick, as: Tk

  @type standard ::
          {numerator :: pos_integer(), denominator :: pos_integer()}
          | {:standard, numerator :: pos_integer(), denominator :: pos_integer()}
  @type compound :: {:compound, groupings :: [pos_integer()], denominator :: pos_integer()}
  # 散拍子
  @type free :: :san

  # 小节不从零开始
  @type bar :: pos_integer()

  @type t :: standard() | compound() | free()

  @typedoc "节拍变化事件"
  @type time_sig_event :: {bar(), t()}

  @type time_sig_events :: [time_sig_event()] | {[time_sig_event()], last :: bar()}

  @doc "获取一个完整小节的 Tick 长度"
  def ticks_per_bar({num, den}) when is_integer(num) and is_integer(den),
    do: ticks_per_bar({:standard, num, den})

  def ticks_per_bar({:standard, num, den}), do: div(total_notes(num), den)
  def ticks_per_bar({:compound, groupings, den}), do: div(total_notes(Enum.sum(groupings)), den)
  def ticks_per_bar(:san), do: nil

  # Note: 这个是 Gemini 的思路，我可能更倾向于「以 xxx 为一拍，每小节有 xxx 拍」的思路
  # 我其实不知道这个的思路是什么原理
  # get_ticks_per_beat(den), do: div(4, den) * tpqn
  defp total_notes(num), do: Tk.ticks_per_quarter_note() * 4 * num
end
