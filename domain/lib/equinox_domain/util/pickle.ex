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
    @moduledoc """
    多实现对象的序列化契约。

    一个 Plugable 对象在序列化后形如：

        %{
          "__scope__" => scope(),
          "__signature__" => signature(),
          # ...实现相关字段
        }

    其中 `scope` 由抽象层模块声明（如 Key、Tempo），
    `signature` 由具体实现模块提供（如 TwelveET、Step）。
    """

    alias EquinoxDomain.Util.Pickle

    @type scope :: binary()
    @type signature :: binary()

    @typedoc "带 scope/signature 标签的 payload"
    @type tagged :: %{required(binary()) => Pickle.serialized()}

    @type registry :: %{scope() => %{signature() => module()}}

    @doc "获得当前实现的 signature"
    @callback signature() :: signature()

    @doc "将实例 dump 为纯数据 map（不含 scope/signature）"
    @callback dump(Pickle.model()) :: {:ok, map()} | {:error, term()}

    @doc "从纯数据 map 构造实例"
    @callback load(map()) :: {:ok, Pickle.model()} | {:error, term()}

    defmacro __using__(_opts) do
      quote do
        @behaviour EquinoxDomain.Util.Pickle.Plugable
      end
    end

    # ---- 分发函数 ----

    @spec lookup(registry(), scope(), signature()) ::
            {:ok, module()} | {:error, {:not_found, scope(), signature()}}
    def lookup(registry, scope, signature) do
      with %{} = table <- Map.get(registry, scope, %{}),
           {:ok, mod} <- Map.fetch(table, signature) do
        {:ok, mod}
      else
        :error -> {:error, {:not_found, scope, signature}}
      end
    end

    @doc """
    分发 dump：调模块的 dump/1，然后贴上 __scope__ 和 __signature__ 标签。
    抽象层模块的 facade 调用此函数。
    """
    @spec dispatch_dump(Pickle.model(), scope(), module()) ::
            {:ok, tagged()} | {:error, term()}
    def dispatch_dump(model, scope, mod) do
      with {:ok, payload} <- mod.dump(model) do
        {:ok,
         payload
         |> Map.put("__scope__", scope)
         |> Map.put("__signature__", mod.signature())}
      end
    end

    @doc """
    分发 load：从 tagged payload 中提取 signature，查 registry 找模块，调 load/1。

    会校验 `__scope__` 是否匹配。
    """
    @spec dispatch_load(tagged(), scope(), registry()) ::
            {:ok, Pickle.model()} | {:error, term()}
    def dispatch_load(payload, scope, registry) do
      case Map.fetch(payload, "__scope__") do
        {:ok, ^scope} ->
          with {:ok, sig} <- Map.fetch(payload, "__signature__"),
               {:ok, mod} <- lookup(registry, scope, sig),
               {:ok, model} <- mod.load(payload) do
            {:ok, model}
          end

        {:ok, other} ->
          {:error, {:scope_mismatch, expected: scope, got: other}}

        :error ->
          {:error, {:missing_scope, payload}}
      end
    end
  end
end
