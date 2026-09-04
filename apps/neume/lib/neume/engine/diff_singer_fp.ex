defmodule Neume.Engine.DiffSingerFp do
  @moduledoc """
  DiffSinger Pure-FP 本地派生模型的构建与 manifest 加载。

  手术把 ONNX 图内无 seed 的随机算子改成显式输入；原声库始终只读，
  派生模型写入 `tmp/onnx_fp/`。派生物能否分发仍由具体声库许可证决定。
  """

  @noise_version 1
  @model_keys ~w(pitch_predict variance acoustic vocoder)

  @type t :: %{
          manifest_path: Path.t(),
          manifest_digest: String.t(),
          models: map(),
          noise: map(),
          noise_version: pos_integer()
        }

  @spec noise_version() :: pos_integer()
  def noise_version, do: @noise_version

  @spec for_voicebank(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_voicebank(root, opts \\ []) do
    dir = Keyword.get(opts, :dir, default_dir(root, opts[:voicebank_digest]))
    path = Path.join(dir, "fp_manifest.json")

    cond do
      File.regular?(path) -> load_manifest(path)
      Keyword.get(opts, :build?, true) -> build(root, dir, path, opts)
      true -> {:error, {:fp_manifest_missing, path}}
    end
  end

  @spec load_manifest(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_manifest(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(bytes),
         :ok <- validate_manifest(manifest, path) do
      {:ok,
       %{
         manifest_path: Path.expand(path),
         manifest_digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         models: Map.new(manifest, fn {key, entry} -> {key, entry["path"]} end),
         noise: Map.new(manifest, fn {key, entry} -> {key, entry["noise"]} end),
         noise_version: @noise_version
       }}
    else
      {:ok, other} -> {:error, {:invalid_fp_manifest, path, other}}
      {:error, _} = error -> error
    end
  end

  defp build(root, dir, path, opts) do
    [python | python_args] = Keyword.get(opts, :python, ["python"])
    script = Application.app_dir(:neume, "priv/fp/freeze_noise.py")

    args = python_args ++ [script, Path.expand(root), "--out", Path.expand(dir)]

    case System.cmd(python, args, stderr_to_stdout: true) do
      {_output, 0} ->
        load_manifest(path)

      {output, code} ->
        {:error, {:fp_surgery_failed, code, output}}
    end
  rescue
    error -> {:error, {:fp_surgery_failed, Exception.message(error)}}
  end

  defp validate_manifest(manifest, path) do
    valid? =
      Enum.all?(@model_keys, fn key ->
        case Map.get(manifest, key) do
          %{"path" => model, "noise" => noise} -> File.regular?(model) and is_list(noise)
          _ -> false
        end
      end)

    if valid?, do: :ok, else: {:error, {:invalid_fp_manifest, path, manifest}}
  end

  defp default_dir(_root, digest) when is_binary(digest),
    do:
      Path.join([
        File.cwd!(),
        "tmp",
        "onnx_fp",
        "#{String.slice(digest, 0, 16)}-v#{@noise_version}"
      ])

  defp default_dir(root, _digest) do
    slug = root |> Path.basename() |> String.split("_") |> hd() |> String.downcase()
    Path.join([File.cwd!(), "tmp", "onnx_fp", slug])
  end
end
