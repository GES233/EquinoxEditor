defmodule EquinoxDomain.Score.Utterance do
  # 保存歌词以及音素的对象

  # 我本来的计划是引入「音节」对象
  # 但那样会增加复杂度
  # 因此先搁置
  # 直接建立音符和音素（包括时长等信息）的映射

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
