defmodule EquinoxDomain.Curve.Chunk do
  # 一条曲线
  # 虽然预计对象会有很多，但因为可被定位的关系，属于 Entity
  use EquinoxDomain.Util.Model,
    keys: [:id, :channel, :type, :payload],
    id_prefix: "CurveChunk_"
end
