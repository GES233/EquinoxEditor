defmodule EquinoxDomain.Score.Utterance do
  # 保存歌词以及音素的对象

  # 还需要确定具体是 sec 还是 tick
  # 我的打算是中间 Slicer 处理时用到 sec ，最后保留 tick
  # 因为该部分除了音符经处理栅格化的音素、音高外还有各种参数曲线

  # 需要进一步梳理
  # @type t :: %__MODULE__{
  #         id: binary(),
  #         notes: [EquinoxDomain.Score.Note.t()],

  #         # 核心发声区间（基于音素绝对时间）
  #         core_start_sec: float(),
  #         core_end_sec: float(),

  #         # 渲染上下文区间（给声学模型预留的 Padding，防止爆音）
  #         context_start_sec: float(),
  #         context_end_sec: float()
  #       }
end
