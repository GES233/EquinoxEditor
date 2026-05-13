defmodule EquinoxDomain.Port.Resolver.Operate.Delta do
  @moduledoc """
  增量策略：base 与 delta 合并。

  具体的合并逻辑（逐样本/逐事件叠加）取决于 payload 的形状，
  由 Kernel 层的 Resolver 实现。Domain 仅提供 Behaviour 契约。
  """

  @behaviour EquinoxDomain.Port.Resolver.Operate

  @impl true
  def merge(nil, delta), do: {:ok, delta}
  def merge(base, _delta), do: {:ok, base}
end
