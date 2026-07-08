defmodule EquinoxDomain.Rebase.Patch do
  @moduledoc """
  以 identity 为键的透明补丁。

  当上游重新计算其 identity 序列时，`EquinoxDomain.Rebase.reconcile/2`
  按 `identity` 匹配补丁，决定哪些存活、哪些成为孤儿。

  ## Identity

  `identity :: term()` —— 由上游 adapter 生成。仅在调和时做相等比较，
  Domain 层不解释其内部结构。

  ## Data

  `data :: term()` —— 任意负载。调和过程中原样携带，不做变换。
  """

  @type identity :: term()
  @type t :: %__MODULE__{identity: identity(), data: term()}

  defstruct [:identity, :data]

  @doc "从 identity 和 data 创建新补丁。"
  @spec new(identity(), term()) :: t()
  def new(identity, data), do: %__MODULE__{identity: identity, data: data}

  @doc "批量创建补丁。"
  @spec new_many([{identity(), term()}]) :: [t()]
  def new_many(pairs) when is_list(pairs) do
    Enum.map(pairs, fn {id, data} -> new(id, data) end)
  end
end
