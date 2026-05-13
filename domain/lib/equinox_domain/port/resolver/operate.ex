defmodule EquinoxDomain.Port.Resolver.Operate do
  @moduledoc """
  声明解析策略。

  模块即声明——传入 Declaration.operate 的模块原子必须实现此 Behaviour。
  内置快捷方式 `:override` 通过 resolve_module/1 映射到 Operate.Override。

  ## 与 OrchidIntervention.Operate 的关系

  本模块与 `OrchidIntervention.Operate` 共享同一个 `merge/2` 契约。
  OrchidIntervention 额外定义了 `short_circuit?/0` 和 `data_enable/0`，
  属于 DAG 运行时调度层，Domain 层不需要。
  """

  @typedoc "解析器处理的负载——具体形状取决于 Declaration.shape"
  @type payload :: term()

  # @doc "获得可被序列化的标识。"
  # @calbback signature() :: binary()

  @doc "合并 base 与 delta/override，返回解析后的 payload。"
  @callback merge(base :: payload() | nil, delta_or_override :: payload()) ::
              {:ok, payload()} | {:error, term()}
end
