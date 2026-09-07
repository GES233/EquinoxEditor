defmodule Neume.Pin.Descriptor do
  @moduledoc """
  pin payload 的自描述（`design-2026-09-pin-carriers` §4/§5）。

  Tamale patch 只持有 `base_digest` 与 payload，无法从 digest 反推旧
  base schema；因此 carrier、payload schema 与 base schema 必须由
  payload 分派得出（`Neume.Pin.Semantics.describe/1`），不能挂在
  channel 模块级——同一个 `:pitch` channel 在迁移期同时承载 legacy
  list / `pitch_curve_v1` 与未来的 `score_pitch_v2`。
  """

  @enforce_keys [:payload_schema, :base_schema, :carrier]
  defstruct [:payload_schema, :base_schema, :carrier]

  @typedoc "carrier 分类：payload 引用哪个领域对象（谱面 `S` / 语音学 `Ph` / 对应关系 `Co`）。"
  @type carrier :: :score | :phonology | :correspondence

  @type t :: %__MODULE__{
          payload_schema: String.t(),
          base_schema: String.t(),
          carrier: carrier()
        }
end
