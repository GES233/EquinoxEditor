defmodule EquinoxDomain.Curve.Adapter do
  @moduledoc """
  实现新的曲线适配器。

  ## 示例

      defmodule Foo do
        # 一般都存在状态
        use EquinoxDomain.Curve.Adapter, keys: ...

        defimpl Inner, for: __MODULE__ do
          def control_points(foo), do: ...
          def span(foo), do: ...
          def rasterize(foo, tick_seq), do: ...
        end
      end

  ## 可编辑的曲线

      # 比方说控制点可变之类的
      # 整体平移（随着特定音符片段）
      # 什么什么的

  ## 栅格化的实现

  这里主要是用于参数的曲线在根据 Tempo 得到的 `tick_seq` 的采样点作为栅格化的单位/依据。

  所以这也是考虑 `EquinoxDomain.Curve.Adapter.Inner.span/1` 协议的一个原因了。

  同时也要考虑只要一部分曲线拿来序列化的情况。

  关于这个名字，因为下游引擎所需要的一般是**基于物理时间的栅格化**的数据，
  所以我们还是把「栅格化」这个名字顺延过来了。
  """

  alias EquinoxDomain.Curve.ControlPoint

  # ---- 如果这里需要一些业务函数的话，放在这 ----

  defprotocol Inner do
    @doc "返回容器内的控制点列表，单位是 tick 。"
    @spec control_points(term()) :: [ControlPoint.t()]
    def control_points(container)

    @doc "返回曲线的时间跨度（最后一个控制点的 tick 偏移）。空曲线返回 0。"
    @spec span(term()) :: non_neg_integer()
    def span(container)

    @doc "按给定 tick 序列采样，返回 float-32-native 二进制。tick_seq 可以是 list 或 Range。"
    # Erlang float-32-native is used in bit syntax to read or write 32-bit (single-precision)
    # IEEE 754 floating-point numbers using the CPU's native endianness.
    @spec rasterize(term(), Enumerable.t(non_neg_integer())) :: binary()
    def rasterize(container, tick_seq)
    # 后续 NIF 替换
  end

  defmacro __using__(opts) do
    # 顺应 EquinoxDomain.Util.Object 模块
    keys = Keyword.fetch!(opts, :keys)

    quote do
      use EquinoxDomain.Util.Object, keys: unquote(keys)
      # @behaviour EquinoxDomain.Curve.Adapter
      alias EquinoxDomain.Curve.{Adapter.Inner, ControlPoint}
      @after_compile EquinoxDomain.Curve.Adapter
    end
  end

  def __after_compile__(env, _bytecode) do
    Protocol.assert_impl!(EquinoxDomain.Curve.Adapter.Inner, env.module)
  rescue
    ArgumentError ->
      IO.warn(
        "#{inspect(env.module)} uses Curve.Adapter but not implement Inner protocol",
        Macro.Env.stacktrace(env)
      )
  end
end
