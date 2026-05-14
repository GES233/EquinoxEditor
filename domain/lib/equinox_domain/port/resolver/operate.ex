defmodule EquinoxDomain.Port.Resolver.Operate do
  @moduledoc "声明特定参数频道下模型数据与用户修改的解析策略。"

  @typedoc "解析器处理的负载——具体形状取决于 Declaration.shape"
  @type payload :: term()

  @doc "获得可被序列化的标识。"
  @callback signature() :: binary()

  @doc "合并 base 与 delta/override，返回解析后的 payload。"
  @callback merge(base :: payload() | nil, delta_or_override :: payload()) ::
              {:ok, payload()} | {:error, term()}
end
