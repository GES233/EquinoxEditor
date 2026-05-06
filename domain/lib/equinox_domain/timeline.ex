defmodule EquinoxDomain.Timeline do
  @moduledoc """
  关于编辑器的时间系统。

  主要包括三类时间系统：

  * 一个是面向用户的时间系统，纯粹描述音乐结构
  * 一个是编辑器内部，基于 Tick
  * 还有一个是面向引擎/下游的时间，也就是物理时间
  """

  @type tick :: EquinoxDomain.Timeline.Tick.t()

  # 物理时间
  @type physical_time :: float()

  # ---- 设计笔记 ----
  # Tempo/TempoMap 以及 TimeSig/TimeSigMap 的共同逻辑已提取为 `Record` / `RecordMap`。
  # 详见 `EquinoxDomain.Timeline.Record` 和 `EquinoxDomain.Timeline.RecordMap`。
end
