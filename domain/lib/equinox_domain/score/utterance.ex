defmodule EquinoxDomain.Score.Utterance do
  @moduledoc "由 Slicer 算出的连续发声片段，渲染的最小上下文单位。"
  # 为什么用这个而不是 Phrase/Segment
  # 因为以发音为单位

  @type t :: %__MODULE__{
          id: binary(),
          notes: [EquinoxDomain.Score.Note.t()],

          # 核心发声区间（基于音素绝对时间）
          core_start_sec: float(),
          core_end_sec: float(),

          # 渲染上下文区间（给声学模型预留的 Padding，防止爆音）
          context_start_sec: float(),
          context_end_sec: float()
        }
  use EquinoxDomain.Util.Model,
    keys: [:id, :notes, :core_start_sec, :core_end_sec, :context_start_sec, :context_end_sec],
    id_prefix: "Utterance_"
end
