defmodule EquinoxDomain.Util.Pickle do
  @moduledoc "序列化与反序列化的行为。"

  @typedoc "待序列化的结构体或数据"
  @type model :: term()

  @typedoc "可持久化的基本标量。"
  @type scalar :: nil | boolean() | integer() | float() | binary()

  # 一方面作为类似 Registry
  # 另一方面需要提供别的东西，例如外部插件/元数据/外部配置等等
  # Domain 不会涉及
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
    @moduledoc "不需要额外上下文的对象的序列化与反序列化。"

    alias EquinoxDomain.Util.Pickle

    @doc "序列化给定对象（无需额外上下文）。"
    @callback serialize(Pickle.model()) :: {:ok, Pickle.serialized()} | {:error, term()}

    @doc "将被序列化的数据返回到给定对象（无需额外上下文）。"
    @callback deserialize(Pickle.serialized()) :: {:ok, Pickle.model()} | {:error, term()}
  end

  defmodule Plugable do
    @moduledoc "为操作对象可能存在外部的其他实现的情况提供一些便利。"
    # 不能说插件，插件可能会介入生命周期的多个阶段，不是领域模型可以 cope 掉的

    alias EquinoxDomain.Util.Pickle

    # 等到后面定性改成 Literal
    @type scope :: binary()

    @type signature :: binary()

    @typedoc """
    需要说明一下运行时格式:

    `%{"__scope__" => scope(), "__signature__" => signature(), payload}`
    """
    @type serialized :: %{optional(binary()) => Pickle.serialized()}

    @type registry :: %{
      scope() => %{signature() => module()}
    }

    @doc "获得当前模块/实现的标识"
    @callback signature() :: signature()

    defmacro __using__(_opts) do
      quote do
        @behaviour EquinoxDomain.Util.Pickle.Plugable
        @behaviour EquinoxDomain.Util.Pickle.Pure
      end
    end
  end
end
