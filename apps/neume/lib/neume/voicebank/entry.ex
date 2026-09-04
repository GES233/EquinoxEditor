defmodule Neume.Voicebank.Entry do
  @moduledoc """
  可选择的声库变体。

  Stock 与 Modified 即使共享同一个原始声库目录，也拥有不同的 `id`、工程签名
  和运行身份。Modified 的摘要同时覆盖原声库、修改 manifest、派生模型内容和
  修改工艺版本。
  """

  alias Neume.Engine.DiffSingerFp
  alias Neume.Voicebank.DiffSinger

  @enforce_keys [:id, :name, :mode, :manifest, :signature]
  defstruct [:id, :name, :mode, :manifest, :fp, :signature]

  @type mode :: :stock | :modified
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          mode: mode(),
          manifest: DiffSinger.t(),
          fp: DiffSingerFp.t() | nil,
          signature: Coconut.Project.voicebank()
        }

  @spec stock(DiffSinger.t()) :: t()
  def stock(%DiffSinger{} = manifest) do
    signature = %{
      name: "#{manifest.name} (Stock)",
      engine: :diffsinger_stock,
      digest: manifest.digest
    }

    %__MODULE__{
      id: id(signature),
      name: signature.name,
      mode: :stock,
      manifest: manifest,
      fp: nil,
      signature: signature
    }
  end

  @spec modified(DiffSinger.t(), DiffSingerFp.t()) :: t()
  def modified(
        %DiffSinger{} = manifest,
        %{manifest_digest: fp_digest, noise_version: version} = fp
      ) do
    digest =
      :crypto.hash(
        :sha256,
        [
          "neume/diffsinger-modified/1\0",
          manifest.digest,
          "\0",
          fp_digest,
          "\0",
          to_string(version)
        ]
      )
      |> Base.encode16(case: :lower)

    signature = %{
      name: "#{manifest.name} (Modified)",
      engine: :diffsinger_modified,
      digest: digest
    }

    %__MODULE__{
      id: id(signature),
      name: signature.name,
      mode: :modified,
      manifest: manifest,
      fp: fp,
      signature: signature
    }
  end

  @spec id(Coconut.Project.voicebank()) :: String.t()
  def id(%{engine: engine, digest: digest}), do: "#{engine}:#{digest}"
end
