defmodule EquinoxDomain.Port.Resolver.Operate.Override do
  @moduledoc """
  覆盖策略：直接返回 override，完全忽略 base。

  对应 Declaration.operate 的 `:override` 快捷方式。
  """

  @behaviour EquinoxDomain.Port.Resolver.Operate

  @impl true
  def merge(_base, override), do: {:ok, override}
end
