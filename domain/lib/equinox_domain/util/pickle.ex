defmodule EquinoxDomain.Util.Pickle do
  @moduledoc "序列化与反序列化的行为。"
  # 先不考虑 options 了

  @typedoc "待序列化的结构体或数据"
  @type model :: term()

  @typedoc "可持久化的基本标量。"
  @type scalar :: nil | boolean() | integer() | float() | binary()

  @typedoc "可能需要的上下文"
  @type context :: term()

  @typedoc "可序列化结构。"
  @type serialized ::
          scalar()
          | [serialized()]
          | %{optional(binary() | atom()) => serialized()}

  @callback serialize(model(), context()) :: {:ok, serialized()} | {:error, term()}

  @callback deserialize(serialized(), context()) :: {:ok, model()} | {:error, term()}

  defmodule Pure do
    @moduledoc "不需要额外上下文的序列化与反序列化。"

    alias EquinoxDomain.Util.Pickle

    @callback serialize(Pickle.model()) :: {:ok, Pickle.serialized()} | {:error, term()}

    @callback deserialize(Pickle.serialized()) :: {:ok, Pickle.model()} | {:error, term()}
  end
end
