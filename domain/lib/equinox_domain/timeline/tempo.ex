defmodule EquinoxDomain.Timeline.Tempo do
  @moduledoc """
  时长工具的入口。
  """
  alias EquinoxDomain.Timeline
  alias EquinoxDomain.Timeline.Tick
  import Tick

  defmodule Event do
    @moduledoc "速度变化事件"

    @type context :: term()
    @type t :: %__MODULE__{
            module: module(),
            context: context()
          }
    defstruct [:module, :context]
  end

  @typedoc "自第 x 刻开始，有了 XXX 速度段。"
  @type tempo_event :: {Tick.numeric_tick(), Event.t()}

  @type tempo_events :: [tempo_event()] | {[tempo_event()], last :: Tick.t()}

  defmodule Segment do
    @moduledoc """
    速度段的行为定义，支持阶梯、线性、甚至曲线。

    不允许时间逆流或停止（无论如何 BPM 一定大于零）；
    开始 Tick 要大于等于 0；
    ……
    """

    @typedoc "实现速度段的结构体。"
    @type segment :: struct()

    @typedoc "实际运行的时间长度。"
    @type duration :: float() | :infinity

    @doc "从事件以及时间线构建出当前的片段。"
    @callback build_from_event(
                start_tick :: Tick.numeric_tick(),
                end_tick :: Tick.t(),
                event :: EquinoxDomain.Timeline.Tempo.Event.context()
              ) :: {:ok, segment()} | {:error, reason :: term()}

    @doc "该片段的持续时间。"
    @callback duration_sec(segment) :: duration()

    @doc "该片段从开始到第 `tick_offset` 刻的持续时间。"
    @callback tick_to_sec(segment, tick_offset :: Tick.numeric_tick()) :: duration()

    @doc "该片段第 X.XX 秒所对应的刻（四舍五入吧，因为这个秒一般就是刻转换过去的）。"
    @callback sec_to_tick(segment, sec_offset :: Timeline.physical_time()) :: Tick.numeric_tick()
  end

  defmodule Step do
    @moduledoc """
    最简单的速度段定义——阶梯。

    如果全部都是一个阶梯，那么就是恒定速度。
    """

    @behaviour EquinoxDomain.Timeline.Tempo.Segment

    defstruct [:start_tick, :end_tick, :bpm]

    @impl true
    def build_from_event(_, _, %{bpm: bpm}) when bpm <= 0,
      do: {:error, {:bpm_is_negative, bpm}}

    def build_from_event(start_tick, end_tick, %{bpm: bpm}),
      do: {:ok, %__MODULE__{start_tick: start_tick, end_tick: end_tick, bpm: bpm}}

    @impl true
    def duration_sec(%{end_tick: end_tick}) when is_dynamic_tick(end_tick), do: :infinity

    def duration_sec(seg) do
      tick_to_sec(seg, seg.end_tick - seg.start_tick)
    end

    @impl true
    def tick_to_sec(seg, ticks) do
      sec_per_quarter = 60.0 / seg.bpm
      ticks * (sec_per_quarter / ticks_per_quarter_note())
    end

    @impl true
    def sec_to_tick(seg, offset_sec) do
      round(offset_sec * (ticks_per_quarter_note() * seg.bpm / 60))
    end
  end

  # 线性渐变速度
  defmodule Linear, do: nil

  # 应用曲线
  defmodule Curve, do: nil

  # ---- 工具函数 ----
  # 可以直接应用 Tempo.blabla(segment_or_module, blabla)

  @doc "根据模块、刻以及上下文构建片段的函数。"
  def build_segment_from_event(_module, start_tick, _, _) when start_tick < 0,
    do: {:error, {:tick_invalid, %{start_tick: start_tick}}}

  def build_segment_from_event(module, start_tick, end_tick, payload)
      when is_dynamic_tick(end_tick),
      do: module.build_from_event(start_tick, end_tick, payload)

  def build_segment_from_event(_module, start_tick, end_tick, _) when start_tick >= end_tick,
    do: {:error, {:tick_invalid, %{start_tick: start_tick, end_tick: end_tick}}}

  def build_segment_from_event(module, start_tick, end_tick, payload),
    do: module.build_from_event(start_tick, end_tick, payload)

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

  @doc "得到该片段自开始某段时间所经过的 Tick 数。"
  @spec sec_to_tick(Segment.segment(), Timeline.physical_time()) :: Segment.duration()
  def sec_to_tick(segment, sec) do
    impl(segment).sec_to_tick(segment, sec)
  end

  defp impl(%module{}), do: module
  defp impl(module) when is_atom(module), do: module
end
