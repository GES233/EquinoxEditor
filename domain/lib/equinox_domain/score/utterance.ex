defmodule EquinoxDomain.Score.Utterance do
  @moduledoc """
  发声单元——由 Slicer 将连续的 Note 归组后的时间窗口。

  Utterance 通过 declarations 声明其依赖的引擎适配器
  （如 G2P、duration prediction），实际的 note-phoneme 映射
  由 Kernel 层的 Port 投影在运行时产生。
  """

  alias EquinoxDomain.{Util.ID, Util.Model}
  alias EquinoxDomain.Score.Track
  alias EquinoxDomain.Port.Declaration

  @type t :: %__MODULE__{
          id: ID.t(),
          track_id: ID.t(Track),
          declarations: %{binary() => Declaration.t()}
        }

  use Model,
    keys: [
      :id,
      :track_id,
      declarations: %{}
    ],
    id_prefix: "Utterance_"
end
