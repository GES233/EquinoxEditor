defmodule EquinoxDomain.Score.Phoneme do
  @moduledoc """
  音素模型——纯身份载体。

  Phoneme 仅携带 symbol 与 type，不包含时域信息。
  时长与偏移由 Engine 预测，通过 Port 投影层流入 Kernel 解析器，
  最终以 TimedEvent 的形式进入 Resolved Input。

  音素本身由 G2P 适配器产出，不作为 Domain 事实持久化，
  除非用户通过 Adoption Command 将其锁定为 Declaration 的 override。

  ## 辅音提前量 (Consonant Preutterance)

  旧 `note_offset`（可为负，表示辅音相对于所属音符起点的偏移）
  已从此 Domain 模型移除。辅音提前量现在由 duration adapter
  在 Projection 阶段计算，以 `TimedEvent{at: negative_tick}`
  的形式进入 Resolved Input。约束（最大提前量、是否允许跨 note 边界）
  存在 `Port.Declaration.constraints` 中（如 `consonant_preutter_limit`）。

  渲染层面：Segment 的 `context_start_sec` / `context_end_sec` 提供
  声学 padding，确保辅音发声区间被覆盖。
  """

  @type symbol :: String.t()
  @type phoneme_type :: :consonant | :vowel | :silence

  @type t :: %__MODULE__{
          symbol: symbol(),
          type: phoneme_type()
        }

  use EquinoxDomain.Util.Object, keys: [:symbol, :type]
end
