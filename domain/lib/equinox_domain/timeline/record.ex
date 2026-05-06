defmodule EquinoxDomain.Timeline.Record do
  @moduledoc """
  通用的、基于 Tick/Bar 的 Record 抽象。

  将 Tempo 和 TimeSig 的共同模式提取为统一的 Record 事件模型：

  - 每个 Record 是一个位于特定位置（Tick 或 Bar）的时间线事件
  - Record 列表通过 `RecordMap` 编译为可二分查找的区间元组

  ## 位置语义

  位置是 `non_neg_integer()`，对于 Tempo 表示 Tick 刻，对于 TimeSig 表示 Bar 小节号。
  两者都是非负整数，从 0 开始。
  """

  alias EquinoxDomain.Timeline.Tick

  @typedoc "Record 的位置：Tick 刻或 Bar 小节号，从 0 开始"
  @type position :: non_neg_integer()

  @typedoc "Record 携带的对应值"
  @type value :: term()

  @typedoc "单个时间线的事件"
  @type t :: {position(), value()}

  @typedoc """
  Record 列表。

  可以是有限列表，也可以带上一个动态终点 `{records, last}`。
  当最后一个片段没有明确的结束位置时使用 `Tick.dynamic_tick()` / `:dynamic_tick`。
  """
  @type records :: [t()] | {[t()], last :: Tick.t()}
end
