defmodule EquinoxDomain.Timeline do
  @moduledoc """
  关于编辑器的时间系统。

  主要包括三类时间系统：

  * 一个是面向用户的时间系统，纯粹描述音乐结构
  * 一个是编辑器内部，基于 Tick
  * 还有一个是面向引擎/下游的时间
  """

  # 时间系统是地基，很重要

  @type tick :: EquinoxDomain.Timeline.Tick.t()
  @type physical_time :: float()
end
