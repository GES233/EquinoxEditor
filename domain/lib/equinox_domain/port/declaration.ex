defmodule EquinoxDomain.Port.Declaration do
  @moduledoc "通用声明——描述一个在特定 scope 上的外部适配器的运行策略。"
  # 虽然涉及整个生命周期，但不需要显式 ID
  # 此前这里有 Adapter ，但被我砍掉了，因为这部分是计算干的活
  # 唯一涉及领域的也就是

  alias EquinoxDomain.Port.{OperateRef, Channel}

  @type shape :: :continuous | :event_sequence

  @type t :: %__MODULE__{
          scope: {:track, binary()} | {:note, binary()},
          target: Channel.channel(),
          shape: shape(),
          operate: OperateRef.t(),
          constraints: %{optional(atom()) => term()},
          fallback: atom() | nil,
          metadata: %{optional(atom()) => term()}
        }

  use EquinoxDomain.Util.Object,
    keys: [
      :scope,
      :target,
      :shape,
      :operate,
      constraints: %{},
      fallback: nil,
      metadata: %{}
    ]

  @impl true
  def validate(%__MODULE__{shape: shape})
      when shape not in [:continuous, :event_sequence] do
    {:error, {:invalid_shape, shape}}
  end

  def validate(%__MODULE__{operate: operate})
      when not is_struct(operate, OperateRef) do
    {:error, {:invalid_operate, operate}}
  end

  def validate(decl), do: {:ok, decl}
end
