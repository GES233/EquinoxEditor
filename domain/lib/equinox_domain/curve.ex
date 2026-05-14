defmodule EquinoxDomain.Curve do
  @moduledoc """
  曲线工具模块。

  灵感来源于 Cadencii 。

  用一句话描述曲线，就是包括多个 Chunk 的一条 Curve 用于 Track 的特定 Cluster 。
  这里将 Curve 与 Cluster 分离开的原因在于 Cluster
  允许重叠，其经过处理（重叠片段以最新的为准）变成一条 Curve 。

  ## 曲线的来源

  ## 曲线的参数化
  """

  # 提供直线、曲线、手绘工具以及清除/部分清除的工具（type）
  # 最后，也包括将曲线对象栅格化的功能（可能放到 Score 或作为聚合操作）
  # 可能也是作为行为来声明，因为效率真的不如 Rust NIF
end
