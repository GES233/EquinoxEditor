defmodule EquinoxDomain.Score.Utterance do
  # 保存歌词以及音素的对象

  use EquinoxDomain.Util.Model,
    keys: [
      :id,
      :track_id,
      :start_tick,
      :duration_tick,
      # 关联内容
      :note_id_map,
      phonemes: []
    ],
    id_prefix: "Utterance_"
end
