defmodule EquinoxDomain.Port.Resolver.Operate.Replace do
  @moduledoc """
  范围替换策略：用 override 覆盖指定范围，范围外保留 base。

  与 Override 的区别：Override 完全忽略 base，
  Replace 在覆盖范围外用 base 作为 fallback。
  """

  @behaviour EquinoxDomain.Port.Resolver.Operate

  @impl true
  def merge(_base, override), do: {:ok, override}
end
