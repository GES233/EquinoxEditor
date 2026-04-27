defmodule EquinoxDomain.Timeline do
  # 时间系统是地基，很重要

  # ┌─────────────────────────────────────────────────┐
  # │  Musical Time（音乐时间）                       │
  # │  "第2小节 第3拍 第240刻"                        │
  # │  单位：Bar:Beat:Tick                            │
  # │  特点：与 tempo 无关，纯粹描述音乐结构          │
  # ├─────────────────────────────────────────────────┤
  # │  Tick（绝对刻）                                 │
  # │  从乐曲开头起算的累计 tick 数                   │
  # │  单位：non_neg_integer                          │
  # │  特点：这是内部存储的主键                       │
  # ├─────────────────────────────────────────────────┤
  # │  Physical Time（物理时间）                      │
  # │  单位：秒 / 采样点                              │
  # │  特点：送给音频引擎的最终坐标                   │
  # └─────────────────────────────────────────────────┘

  @type physical_time :: float()

  defmodule Tick do
    @behaviour EquinoxDomain.Model.Pickle

    # 刻
    @type t :: non_neg_integer()

    # 按照习惯来
    @ticks_per_quarter_note 480

    def ticks_per_quarter_note, do: @ticks_per_quarter_note

    @impl true
    def serialize(tick), do: tick

    @impl true
    def deserialize(tick), do: tick
  end

  defmodule TimeSig do
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
end
