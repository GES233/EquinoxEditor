defmodule EquinoxDomain.Score.Utterance do
  # 保存歌词以及音素的对象

  # 我本来的计划是引入「音节」对象
  # 但那样会增加复杂度
  # 因此先搁置
  # 直接建立音符和音素（包括时长等信息）的映射

  alias EquinoxDomain.{Util.ID, Util.Model}
  alias EquinoxDomain.Score.{Track, Note, Phoneme}

  @type t :: %__MODULE__{
          id: ID.t(),
          track_id: ID.t(Track),
          note_phoneme_map: %{ID.t(Note) => Phoneme.t()}
        }
  use Model,
    keys: [
      :id,
      :track_id,
      # 关联内容
      # Note.id 与音素的对应表
      :note_phoneme_map
      # phonemes: []
    ],
    id_prefix: "Utterance_"

  # ---- 编辑 ----

  # ---- 序列化 ----
end
