defmodule EquinoxDomain.Port.Declaration do
  @moduledoc "通用声明——描述一个在特定 scope 上的外部适配器的运行策略。"

  alias EquinoxDomain.Port.{AdapterRef, OperateRef}

  @type shape :: :continuous | :event_sequence

  @type t :: %__MODULE__{
          id: EquinoxDomain.Util.ID.t(),
          scope: {:utterance, binary()} | {:track, binary()} | {:note, binary()},
          target: binary(),
          adapter: AdapterRef.t(),
          shape: shape(),
          operate: OperateRef.t(),
          constraints: %{optional(atom()) => term()},
          overrides: term(),
          fallback: atom() | nil,
          metadata: %{optional(atom()) => term()}
        }

  use EquinoxDomain.Util.Model,
    keys: [
      :id,
      :scope,
      :target,
      :adapter,
      :shape,
      :operate,
      constraints: %{},
      overrides: nil,
      fallback: nil,
      metadata: %{}
    ],
    id_prefix: "AdpDecl_"

  @impl true
  def validate(%__MODULE__{shape: shape})
      when shape not in [:continuous, :event_sequence] do
    {:error, {:invalid_shape, shape}}
  end

  def validate(%__MODULE__{operate: operate})
      when not (is_struct(operate, OperateRef)) do
    {:error, {:invalid_operate, operate}}
  end

  def validate(decl), do: {:ok, decl}
end
