defmodule EquinoxDomain.Timeline.TimeSigMap do
  # 整体上和 `EquinoxDomain.Timeline.TempoMap` 比较像。

  # 先不考虑散拍子
  # 散拍子就是 `{:san, Tick.num | Quarter.num }` 了

  alias EquinoxDomain.Timeline.TimeSig

  @type compiled_event :: {pos_integer(), TimeSig.t()}

  @type t :: tuple()

  # def compile(_events) do
  # end
end
