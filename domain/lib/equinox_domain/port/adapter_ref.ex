defmodule EquinoxDomain.Port.AdapterRef do
  @moduledoc """
  适配器引用——可被序列化的适配器标识。

  Kernel 的适配器注册表 (Adapter Registry) 负责将 AdapterRef
  解析为实际的适配器模块。
  """

  @type t :: %__MODULE__{
          scope_key: binary(),
          signature: binary(),
          version: binary() | nil,
          config: %{optional(binary()) => term()}
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :scope_key,
      :signature,
      version: nil,
      config: %{}
    ]
end
