defmodule EquinoxDomain.Score.Phoneme do
  @moduledoc """
  音素值对象，只描述音素符号与类别，不携带最终时域信息。

  在默认流程中，phoneme sequence 可由 phonemization adapter
  从 lyric / language / note context 派生，因此它作为引擎投影
  存在，而不必天然成为 Domain fact。

  当用户显式锁定或编辑音素序列 / 音素时序时，该编辑以
  zongzi Intervention 持久化（note 结构锚 + Declaration 生命周期，
  见 zongzi intervention-semantics）；时序编辑的 channel 实现为
  `EquinoxDomain.Port.Declarations.PhonemeTiming`。

  ## 时长

  Phoneme timing，包括 duration、boundary、preutterance 等，不属于
  Phoneme 本体。它们由引擎投影产生基值，用户修改以 intervention
  delta 挂载，最终在引擎 check 阶段经 `Declaration.resolve/2`
  决议为渲染输入。

  ## Preutterance

  Domain 不再直接存储辅音提前量。

  辅音提前量由模型投影与用户干涉在 Declaration resolve 阶段计算。
  策略性约束未来由 channel Declaration 的 constraints 表达，例如：

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

  use Zongzi.Util.Object, keys: [:symbol, :type]
end
