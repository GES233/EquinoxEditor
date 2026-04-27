defmodule EquinoxDomain.Timeline.TempoMap do
  @moduledoc """
  返回编译后的速度映射表。

  结构形如：

      [
        %{start_tick: 0, end_tick: 1920, start_sec: 0.0, strategy: %Step{bpm: 120}},
        %{start_tick: 1920, end_tick: 2400, start_sec: 2.0, strategy: %Linear{...}},
        ...
      ]
  """

  alias EquinoxDomain.{Timeline, Timeline.Tick}
  alias EquinoxDomain.Timeline.Tempo.Segment, as: TempoSegment

  @type event :: %{
          start_tick: Tick.t(),
          end_tick: Tick.t(),
          start_sec: Timeline.physical_time(),
          strategy: TempoSegment.segment()
        }

  @type t :: [event()]

  @doc "当速度事件发生变化时，重新编译时间线"
  def compile(_tempo_events) do
    # 遍历事件，累加各个 segment 的 duration_sec，
    # 填充每个 segment 的 start_sec 绝对物理时间戳。
  end

  def tick_to_sec(_compiled_map, _target_tick) do
    # 1. 使用二分查找在 compiled_map 中找到 target_tick 所在的 segment
    # 2. offset_ticks = target_tick - segment.start_tick
    # 3. offset_sec = SegmentStrategy.tick_to_sec(segment.strategy, offset_ticks)
    # 4. return segment.start_sec + offset_sec
  end

  # 反向查询
  def sec_to_tick(_compiled_map, _target_sec) do
    # ...
  end
end
