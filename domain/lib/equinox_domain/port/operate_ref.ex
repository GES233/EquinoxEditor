defmodule EquinoxDomain.Port.OperateRef do
  @moduledoc """
  可序列化的 resolver/operate 策略引用。
  Domain 只保存 operate 的稳定标识。
  Kernel Registry 负责解析为具体实现。
  """
  @type t :: %__MODULE__{
          signature: binary(),
          version: binary() | nil,
          config: %{optional(binary()) => term()}
        }
  use EquinoxDomain.Util.Object,
    keys: [
      :signature,
      version: nil,
      config: %{}
    ]
end
