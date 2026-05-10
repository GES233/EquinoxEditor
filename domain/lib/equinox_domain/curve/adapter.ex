defmodule EquinoxDomain.Curve.Adapter do
  @moduledoc """
  实现新的曲线适配器。

  ### 示例

      defmodule Foo do
        use EquinoxDomain.Curve.Adapter

        @impl true
        def new(attrs), do: ...

        defimpl Inner, for: __MODULE__ do
          def control_points(foo), do: ...
          def span(foo), do: ...
          def rasterize(foo, tick_seq), do: ...
        end
      end
  """

  alias EquinoxDomain.Curve.ControlPoint

  @callback new(attrs :: map()) :: struct()

  defprotocol Inner do
    @doc "返回容器内的控制点列表，单位是 tick 。"
    @spec control_points(term()) :: [ControlPoint.t()]
    def control_points(container)

    @doc "返回曲线的时间跨度（最后一个控制点的 tick 偏移）。空曲线返回 0。"
    @spec span(term()) :: non_neg_integer()
    def span(container)

    @doc "按给定 tick 序列采样，返回 float-32-native 二进制。tick_seq 可以是 list 或 Range。"
    # 后续 NIF 替换
    @spec rasterize(term(), Enumerable.t(non_neg_integer())) :: binary()
    def rasterize(container, tick_seq)
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour EquinoxDomain.Curve.Adapter
      alias EquinoxDomain.Curve.{Adapter.Inner, ControlPoint}
    end
  end
end
