defmodule EquinoxDomain.Port.Declaration do
  @moduledoc """
  通用声明——描述一个适配器在特定 scope 上的运行策略。

  `shape` 区分两种数据形态：
  - `:continuous`     — 1D 连续参数 (pitch delta, energy, breathiness)
  - `:event_sequence` — 事件序列 (phoneme timing, note quantization)

  `operate` 遵循模块即声明模式：
  - `:override` → Operate.Override（用户值直接覆盖引擎预测）
  - 自定义模块 → 必须实现 Port.Resolver.Operate behaviour
  """

  alias EquinoxDomain.Port.AdapterRef

  @type shape :: :continuous | :event_sequence

  @type t :: %__MODULE__{
          id: EquinoxDomain.Util.ID.t(),
          scope: {:utterance, binary()} | {:track, binary()} | {:note, binary()},
          adapter: AdapterRef.t(),
          shape: shape(),
          operate: :override | module(),
          constraints: %{optional(atom()) => term()},
          overrides: term(),
          fallback: atom() | nil,
          metadata: %{optional(atom()) => term()}
        }

  use EquinoxDomain.Util.Model,
    keys: [
      :id,
      :scope,
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
  def validate(%__MODULE__{shape: shape} = _decl)
      when shape not in [:continuous, :event_sequence] do
    {:error, {:invalid_shape, shape}}
  end

  def validate(%__MODULE__{operate: operate} = _decl)
      when not (operate == :override or (is_atom(operate) and not is_nil(operate))) do
    {:error, {:invalid_operate, operate}}
  end

  def validate(decl), do: {:ok, decl}
end
