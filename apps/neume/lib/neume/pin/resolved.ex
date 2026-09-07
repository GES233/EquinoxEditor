defmodule Neume.Pin.Resolved do
  @moduledoc """
  裁决侧构造的 engine-independent pin（`design-2026-09-pin-carriers` §4）。

  由 Neume 在裁决阶段从存活 patch 直接构造（不经 Oi assemble 数据反推），
  交给 runtime 的 `Neume.Runtime.lower_pins/4` 降为执行输入。只携带
  channel、descriptor、anchor 与已挂载 payload；不含 Tamale digest 或
  History 状态。字段集在第二个真实 runtime 出现前不冻结。
  """

  alias Neume.Pin.Descriptor

  @enforce_keys [:channel, :descriptor, :anchor, :payload]
  defstruct [:channel, :descriptor, :anchor, :payload]

  @type t :: %__MODULE__{
          channel: atom(),
          descriptor: Descriptor.t(),
          anchor: Tamale.Anchor.t(),
          payload: term()
        }
end
