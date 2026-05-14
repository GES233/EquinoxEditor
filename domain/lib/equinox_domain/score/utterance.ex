defmodule EquinoxDomain.Score.Utterance do
  @moduledoc """
  发声单元——由 Slicer 将连续的 Note 归组后的时间窗口。

  Utterance 是 Slicer 的输出、Compiler 的输入。
  声明（Port.Declaration）由 Track 的 active_preset 在编译时提供，
  Utterance 本身不持有声明，只持有归组后的数据。
  """

  alias EquinoxDomain.{Util.ID, Util.Model}
  alias EquinoxDomain.Score.Track

  @typedoc "Utterance 的 ID 类型"
  @type id :: ID.t(Track)

  @type t :: %__MODULE__{
          id: ID.t(),
          track_id: ID.t(Track),
          note_ids: [ID.t()],
          start_tick: non_neg_integer(),
          duration_tick: non_neg_integer()
        }

  use Model,
    keys: [
      :id,
      :track_id,
      note_ids: [],
      start_tick: 0,
      duration_tick: 0
    ],
    id_prefix: "Utterance_"
end
