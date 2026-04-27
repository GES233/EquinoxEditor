defmodule EquinoxDomain.Timeline.Tempo do
  @moduledoc false
  alias EquinoxDomain.Timeline.Tick

  defmodule Segment do
    @moduledoc "速度段的行为定义，支持阶梯、线性、甚至曲线。"

    @typedoc "实现速度段的结构体。"
    @type segment :: struct()

    @typedoc "实际运行的时间长度。"
    @type duration :: float()

    @doc "该片段的持续时间。"
    @callback duration_sec(segment) :: duration()

    @doc "该片段从开始到第 `tick_offset` 刻的持续时间。"
    @callback tick_to_sec(segment, tick_offset :: non_neg_integer()) :: duration()
  end

  defmodule Step do
    @moduledoc """
    最简单的速度段定义——阶梯。

    如果全部都是一个阶梯，那么就是恒定速度。
    """

    @behaviour EquinoxDomain.Timeline.Tempo.Segment

    defstruct [:start_tick, :end_tick, :bpm]

    @impl true
    def duration_sec(seg) do
      tick_to_sec(seg, seg.end_tick - seg.start_tick)
    end

    @impl true
    def tick_to_sec(seg, ticks) do
      sec_per_quarter = 60.0 / seg.bpm
      ticks * (sec_per_quarter / Tick.ticks_per_quarter_note())
    end
  end

  # 线性渐变速度
  defmodule Linear, do: nil

  # 应用曲线
  defmodule Curve, do: nil

  # ---- 工具函数 ----
  # 直接应用 Tempo.blabla(segment, ticks)

  @spec tick_to_sec(Segment.segment(), Tick.t()) :: Segment.duration()
  def tick_to_sec(segment, ticks) do
    impl(segment).tick_to_sec(segment, ticks)
  end

  @spec duration_sec(Segment.segment()) :: Segment.duration()
  def duration_sec(segment) do
    impl(segment).duration_sec(segment)
  end

  defp impl(%module{}), do: module
end
