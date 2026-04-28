defmodule EquinoxDomain.Timeline.Tempo do
  @moduledoc "时长工具的入口。"
  alias EquinoxDomain.Timeline.Tick

  defmodule Event do
    @moduledoc "速度变化事件"

    @type t :: %__MODULE__{
            module: module(),
            context: term()
          }
    defstruct [:module, :context]
  end

  @typedoc "自第 x 刻开始，有了 XXX 速度段。"
  @type tempo_event :: {Tick.t(), Event.t()}

  # 可能包含结束的片段 last(最后一个音符结束, 最后的音频结束, 用户声明)
  @type tempo_events :: [tempo_event()] | {[tempo_event()], last :: Tick.t()}

  defmodule Segment do
    @moduledoc "速度段的行为定义，支持阶梯、线性、甚至曲线。"

    @typedoc "实现速度段的结构体。"
    @type segment :: struct()

    @typedoc "实际运行的时间长度。"
    @type duration :: float()

    @doc "从事件以及时间线构建出当前的片段。"
    @callback build_from_event(
                start_tick :: Tick.t(),
                end_tick :: Tick.t(),
                event :: EquinoxDomain.Timeline.Tempo.Event.t()
              ) :: segment()

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
    def build_from_event(start_tick, end_tick, %{bpm: bpm}) do
      %__MODULE__{start_tick: start_tick, end_tick: end_tick, bpm: bpm}
    end

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
  # 可以直接应用 Tempo.blabla(segment, ticks)

  @doc "得到该片段自开始到 tick 刻的持续时间。"
  @spec tick_to_sec(Segment.segment(), Tick.t()) :: Segment.duration()
  def tick_to_sec(segment, tick) do
    impl(segment).tick_to_sec(segment, tick)
  end

  @doc "得到该片段的持续时间。"
  @spec duration_sec(Segment.segment()) :: Segment.duration()
  def duration_sec(segment) do
    impl(segment).duration_sec(segment)
  end

  defp impl(%module{}), do: module
end
