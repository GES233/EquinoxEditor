defmodule EquinoxDomain.Util.Pickle do
  @moduledoc "序列化与反序列化的行为。"

  @typedoc "待序列化的结构体或数据"
  @type model :: term()

  @typedoc "可持久化的基本标量。"
  @type scalar :: nil | boolean() | integer() | float() | binary()

  @typedoc "可能需要的上下文"
  @type context :: term()

  # 虽然是纯函数但还是以面向 JSON 为考虑
  @typedoc "可序列化结构。"
  @type serialized ::
          scalar()
          | [serialized()]
          | %{optional(binary() | atom()) => serialized()}

  @doc "序列化给定对象。"
  @callback serialize(model(), context()) :: {:ok, serialized()} | {:error, term()}

  @doc "将被序列化的数据返回到给定对象。"
  @callback deserialize(serialized(), context()) :: {:ok, model()} | {:error, term()}

  defmodule Pure do
    @moduledoc "不需要额外上下文的序列化与反序列化。"

    alias EquinoxDomain.Util.Pickle

    @doc "序列化给定对象（无需额外上下文）。"
    @callback serialize(Pickle.model()) :: {:ok, Pickle.serialized()} | {:error, term()}

    @doc "将被序列化的数据返回到给定对象（无需额外上下文）。"
    @callback deserialize(Pickle.serialized()) :: {:ok, Pickle.model()} | {:error, term()}
  end
end
