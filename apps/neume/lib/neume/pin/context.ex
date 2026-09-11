defmodule Neume.Pin.Context do
  @moduledoc """
  pin 语义回调的裁决上下文（`design-2026-09-pin-carriers` §4）。

  - `:voicebank_identity`——声库身份分量：全量内容摘要 `:digest`
    （legacy 底料用）与字典级 phonology 摘要 `:phonology_digest`
    （批次 C，`Pin<Ph>`/`Pin<Co>` 的 v2 底料用）；无声库（mock 管线）
    时为 `nil`。
  - `:phonology`——Neume 的稳定语音学表征，不是 runtime worker 的展开
    结果；本批次不提供（`nil`）。
  - `:legacy_probe`——仅供旧 duration 下标兼容的 probe 物化序列
    （`Neume.Identity.note_phonemes()`）；v2 schema 不得依赖它。
  - `:legacy_bases`——批量裁决时整轨预计算的 legacy 底料
    （`%{note_id => Neume.Identity.input_base()}`），供 `base/4` 复用，
    避免逐 patch 重算整轨；`nil` 时 legacy base 回退现场推导。
  """

  @enforce_keys [:track, :track_id]
  defstruct [
    :track,
    :track_id,
    :voicebank_identity,
    phonology: nil,
    legacy_probe: nil,
    legacy_bases: nil
  ]

  @type t :: %__MODULE__{
          track: Coconut.Edit.Track.t(),
          track_id: Coconut.Edit.Track.track_id(),
          voicebank_identity: %{digest: String.t(), phonology_digest: String.t() | nil} | nil,
          phonology: term() | nil,
          legacy_probe: Neume.Identity.note_phonemes() | nil,
          legacy_bases: %{term() => Neume.Identity.input_base()} | nil
        }

  @doc """
  构造裁决上下文。`voicebank_digest` 为 `nil`（无声库）时
  `voicebank_identity` 为 `nil`；`opts[:phonology_digest]` 挂字典级
  phonology 摘要（runtime 经 `Neume.Runtime.phonology_digest/1` 提供），
  `opts[:legacy_probe]` 挂 probe 物化序列，`opts[:legacy_bases]` 挂整轨
  预计算的 legacy 底料。
  """
  @spec new(Coconut.Edit.Track.t(), Coconut.Edit.Track.track_id(), String.t() | nil, keyword()) ::
          t()
  def new(track, track_id, voicebank_digest, opts \\ []) do
    %__MODULE__{
      track: track,
      track_id: track_id,
      voicebank_identity: identity(voicebank_digest, Keyword.get(opts, :phonology_digest)),
      legacy_probe: Keyword.get(opts, :legacy_probe),
      legacy_bases: Keyword.get(opts, :legacy_bases)
    }
  end

  defp identity(nil, _phonology_digest), do: nil

  defp identity(digest, phonology_digest),
    do: %{digest: digest, phonology_digest: phonology_digest}

  @doc "声库内容摘要分量；无声库时为 `nil`。"
  @spec voicebank_digest(t()) :: String.t() | nil
  def voicebank_digest(%__MODULE__{voicebank_identity: nil}), do: nil
  def voicebank_digest(%__MODULE__{voicebank_identity: identity}), do: identity[:digest]

  @doc "字典级 phonology 摘要分量；无声库或 runtime 未提供时为 `nil`。"
  @spec phonology_digest(t()) :: String.t() | nil
  def phonology_digest(%__MODULE__{voicebank_identity: nil}), do: nil

  def phonology_digest(%__MODULE__{voicebank_identity: identity}),
    do: identity[:phonology_digest]
end
