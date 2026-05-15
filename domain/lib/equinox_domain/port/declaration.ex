defmodule EquinoxDomain.Port.Declaration do
  @moduledoc "通用声明——描述一个在特定 scope 上的外部适配器的运行策略。"
  # 虽然涉及整个生命周期，但不需要显式 ID

  alias EquinoxDomain.Port.{AdapterRef, OperateRef, Channel}

  @type shape :: :continuous | :event_sequence

  @type t :: %__MODULE__{
          scope: {:track, binary()} | {:note, binary()},
          target: Channel.channel(),
          adapter: AdapterRef.t(),
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
      :adapter,
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
