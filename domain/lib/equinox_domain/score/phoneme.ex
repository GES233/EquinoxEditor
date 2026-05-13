defmodule EquinoxDomain.Score.Phoneme do
  @moduledoc """
  音素值对象，只描述音素符号与类别，不携带最终时域信息。

  在默认流程中，phoneme sequence 可由 phonemization adapter
  从 lyric / language / note context 派生，因此它可以作为 Kernel Projection
  存在，而不必天然成为 Domain fact。

  当用户显式锁定或编辑音素序列时，该编辑应作为
  `Port.Declaration` 的 override 或其他 Domain fact 持久化。

  ## 时长

  Phoneme timing，包括 duration、boundary、preutterance 等，不属于
  Phoneme 本体。它们由 timing declaration、adapter projection、
  user override 和 resolver 共同产生，最终形成 Kernel/Compiler 层的
  Resolved Event Sequence。

  ## Preutterance

  Domain 不再直接存储辅音提前量。
  辅音提前量由 timing adapter / resolver 在 Projection 或 Resolve 阶段计算。
  用户可通过 Declaration constraints 表达策略，例如：

  - consonant_preutter_limit
  - allow_cross_note_boundary
  - min_consonant_duration

  Segment 的 context_start_sec / context_end_sec 只提供渲染所需声学 margin，
  不代表 Domain 中存在实际音素提前时间。
  """


  @type symbol :: String.t()
  @type phoneme_type :: :consonant | :vowel | :silence

  @type t :: %__MODULE__{
          symbol: symbol(),
          type: phoneme_type()
        }

  use EquinoxDomain.Util.Object, keys: [:symbol, :type]
end
