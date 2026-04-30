defmodule EquinoxDomain.Curve.Chunk do
  # 一条曲线
  # 可以理解为用户的「一笔」，也可以理解为运用直线或曲线工具被绘制的线段

  alias EquinoxDomain.Util.ID
  # 虽然预计对象会有很多，但因为可被定位的关系，属于 Entity
  @type t :: %__MODULE__{
    id: ID.t(),
    channel: term(),
    type: module(),
    payload: term()
  }
  use EquinoxDomain.Util.Model,
    keys: [:id, :channel, :type, :payload],
    id_prefix: "CurveChunk_"
end
