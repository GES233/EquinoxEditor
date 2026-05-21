defmodule EquinoxDomain.Port.Declaration do
  # To Agent:
  # 说来惭愧这个模块我一直没看懂，所以就先不管 ADR 直接开始写了
  @moduledoc "存放在特定范围上的外部参数适配器的运行策略的存放容器以及。"
  # 虽然涉及整个生命周期，但不需要显式 ID
  # 唯一涉及领域的也就是保管模块了

  alias EquinoxDomain.Port.Channel

  @type shape :: :continuous | :event_sequence

  @type t :: %__MODULE__{
          scope: {:track, binary()} | {:note, binary()},
          target: Channel.channel(),
          shape: shape(),
          operate: term(),
          constraints: %{optional(atom()) => term()},
          metadata: %{optional(atom()) => term()}
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :scope,
      :target,
      :shape,
      :operate,
      constraints: %{},
      metadata: %{}
    ]

  # 先不管
  @impl true
  def validate(decl), do: {:ok, decl}
end
