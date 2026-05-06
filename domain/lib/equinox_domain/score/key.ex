defmodule EquinoxDomain.Score.Key do
  # 调式/音高

  # 为非十二平均律预留
  @type t :: integer() | term()

  # ---- 关于非十二平均律 ----
  # 有可能一首曲子变成 non-12ET 又回来吗？
  # 变调是会有的，但是在 MIDI-like interface 上是不可见的

  # ---- 序列化相关 ----
  # 这里需要相关模块作为 context
  # 不行就 fallback 到十二平均律
end
