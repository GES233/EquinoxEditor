defmodule EquinoxDomain.Util.Pickle do
  @moduledoc "序列化与反序列化的行为。"
  # 先不考虑 options 了

  # 待序列化的结构体或数据
  @type model :: term()

  @typedoc "可持久化的基本标量。"
  @type scalar :: nil | boolean() | integer() | float() | binary()

  @typedoc "可序列化结构。"
  @type serialized ::
          scalar()
          | [serialized()]
          | %{optional(binary() | atom()) => serialized()}

  @callback serialize(model()) :: {:ok, serialized()} | {:error, term()}

  @callback deserialize(serialized()) :: {:ok, model()} | {:error, term()}
end
