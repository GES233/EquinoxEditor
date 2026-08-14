defmodule EquinoxDomain.Score.Phoneme do
  @moduledoc """
  音素值对象，只描述音素符号与类别，不携带最终时域信息。

  在默认流程中，phoneme sequence 可由 phonemization adapter
  从 lyric / language / note context 派生，因此它作为引擎投影
  存在，而不必天然成为 Domain fact。

  当用户显式锁定或编辑音素序列 / 音素时序时，该编辑以
  `Coconut.Edit.Patch`（锚 + `Tamale.Patch` digest 校验）持久化在
  轨道上；时序编辑的 channel 实现为
  `EquinoxDomain.Port.Channels.PhonemeTiming`。

  ## 时长

  Phoneme timing，包括 duration、boundary、preutterance 等，不属于
  Phoneme 本体。它们由引擎投影产生基值，用户修改以 delta payload
  挂载，最终在渲染 check 阶段经 `Tamale.Patch.resolve/2` 判定有效性后
  作为渲染输入。

  ## Preutterance

  Domain 不再直接存储辅音提前量。

  辅音提前量由模型投影与用户干涉在 resolve 阶段计算。
  策略性约束未来由 channel 的 constraints 表达，例如：

  - consonant_preutter_limit
  - allow_cross_note_boundary
  - min_consonant_duration

  Segment 的 context_start_sec / context_end_sec 只提供渲染所需声学 margin，
  不代表 Domain 中存在实际音素提前时间。
  """

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  @type symbol :: String.t()
  @type phoneme_type :: :consonant | :vowel | :silence

  @type t :: %__MODULE__{
          symbol: symbol(),
          type: phoneme_type()
        }

  @keys [:symbol, :type]
  defstruct @keys

  @doc "创建音素；`:symbol` / `:type` 必填。"
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      struct(__MODULE__, normalized) |> validate()
    end
  end

  @doc "更新音素字段，重新校验。"
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = phoneme, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      struct(phoneme, normalized) |> validate()
    end
  end

  @doc "校验：`symbol` 非空字符串，`type` 为 `:consonant | :vowel | :silence`。"
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{symbol: symbol, type: type} = phoneme) do
    cond do
      not (is_binary(symbol) and symbol != "") ->
        {:error, {:invalid_phoneme_symbol, symbol}}

      type not in [:consonant, :vowel, :silence] ->
        {:error, {:invalid_phoneme_type, type}}

      true ->
        {:ok, phoneme}
    end
  end
end
