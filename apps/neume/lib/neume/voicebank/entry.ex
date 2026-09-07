defmodule Neume.Voicebank.Entry do
  @moduledoc """
  可选择的声库运行时 entry。

  `signature` 是唯一进入 Coconut 工程文件的声库身份；`provider`、`runtime`、
  `manifest` 与 `fp` 都是可由签名和本机 registry 重建的运行时信息。
  """

  @enforce_keys [:id, :name, :provider, :runtime, :signature]
  defstruct [:id, :name, :provider, :runtime, :mode, :manifest, :fp, :signature]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          provider: module(),
          runtime: module(),
          mode: atom() | nil,
          manifest: term(),
          fp: term(),
          signature: Coconut.Project.voicebank()
        }

  @spec id(Coconut.Project.voicebank()) :: String.t()
  def id(%{engine: engine, digest: digest}), do: "#{engine}:#{digest}"
end
