defmodule EquinoxDomain.Curve.Adapter do
  # 曲线适配器 behaviour + Inner protocol
  # 参考 EquinoxDomain.Score.Key 的 behaviour + Key.Inner 模式

  alias EquinoxDomain.Curve.ControlPoint

  @callback new(attrs :: map()) :: struct()

  defprotocol Inner do
    @doc "返回容器内的控制点列表，单位是 tick 。"
    @spec control_points(term()) :: [ControlPoint.t()]
    def control_points(container)

    @doc "栅格化到二进制样本"
    # 后续 NIF 替换
    @spec rasterize(term(), non_neg_integer(), non_neg_integer(), pos_integer()) :: binary()
    def rasterize(container, start_tick, end_tick, stride)
  end
end
