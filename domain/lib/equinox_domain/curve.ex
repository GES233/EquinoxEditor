defmodule EquinoxDomain.Curve do
  # 曲线工具
  # 因为曲线参数是 Equinox 的一个特色（灵感来源于 Cadencii）
  # 所以作为一个单独的模块

  # 原则上讲，一个 Curve 用于 Track

  # 一方面，提供默认值（基于 behaviour）
  # 另一方面，提供直线、曲线、手绘工具以及清除/部分清楚的工具
  # 最后，也包括将曲线对象栅格化的功能（可能放到 Score 或作为聚合操作）
end
