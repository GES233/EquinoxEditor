defmodule CoconutOi do
  @moduledoc """
  Coconut 编辑内核到 Oi 渲染管线的内部适配层。

  本应用只翻译 `Coconut.Render.Engine` 边界和 intervention 数据，不拥有
  引擎编译、音素对齐或多轨混音语义。多轨调度、混音与总线由 Neume 的
  Oi graph/steps 表达。参见
  `CoconutOi.OrchidAdapter` (engine behaviour) and
  `CoconutOi.OrchidAdapter.Assemble` (§3.2 aggregation rule).
  """
end
