defmodule EquinoxDomain.Curve.Cluster do
  @moduledoc """
  一系列曲线组成的通道，是承载单个轨道内同类参数的容器。

  通道的名称就是其 `name` ，也是 Track.curve_clusters 的对应键。

  一般的讲，总会是后面修改的覆盖前面的（依照 z-order）。
  """

  @type t :: %__MODULE__{
          name: atom() | binary(),
          chunks: [EquinoxDomain.Curve.Chunk.t()],
          extra: map()
        }
  use EquinoxDomain.Util.Object, keys: [:name, chunks: [], extra: %{}]

  # 这个模块作为聚合根吧
  # 最需要聚合的部分是栅格化的部分
  # 我们需要获得从 Utterance 得到的片段
  # 再结合 TempoMap 本体以及「基于物理时间长度的 grid_width」
  # 得到片段与栅格化数据的序列
  # 形如 %{{start_tick, end_tick} => [data_seq]}
end
