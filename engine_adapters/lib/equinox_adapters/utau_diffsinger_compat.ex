defmodule EquinoxAdapters.UTAUDiffSingerCompat do
  @moduledoc """
  UTAU 封装 DiffSinger 声库兼容适配器——**神经式引擎边界**（帧网格、
  密采样曲线域）。读取 OpenUtau 推理侧声库目录（`dsconfig.yaml` 优先、
  `dsconfig.json` 回退 + `phonemes.txt` + 可选 `character.txt`）。

  契约级实现（loader + 五回调）+ 推理打包：onnx 推理本体在
  `EquinoxAdapters.DiffSinger.InferStep`（Python sidecar 经 MCP stdio）；
  本模块的 `:phoneme_timing` spec target 是 DiffSinger 版 arity-2 扇出
  （`DiffSinger.Packaging` 把整个窗口打包成 sidecar words 落
  `{:port, :infer, :words}`），`:curve` spec 维持 kernel 共享实现
  （光栅化落 `{:port, :synth, param}`，接推理节点是后续工作）。

  ## 关键映射

  - 帧网格：`frame_rate = sample_rate / hop_size`（44100/512 ≈ 86.13，
    **float**——D3），`hop = hop_size`；曲线 channel 走 `CurveRaster`
    光栅化模态。
  - `supported_channels`：`[:phoneme_timing, :curve]`；`adoptables` 同
    （预测音素时长 → `:phoneme_timing`、预测 pitch → `:curve`，
    OpenUtau 的一等可编辑数据；energy/breathiness 的采纳语义待定，不声明）。
  - `supported_params` 推导：`:pitch`（有 pitch 模型）、`:energy` /
    `:breathiness`（`predict_energy` / `predict_breathiness`，缺省 true）、
    `:tension` / `:voicing`（`predict_tension` / `predict_voicing` 或对应
    `use*Embed`，缺省 false）。
  - `globals`：`key_shift`（范围取 `augmentationArgs.randomPitchShifting.
    range`，缺省 `{:range, -12, 12}`）+ `speaker`（`speakers` 存在时的
    enum，值为去扩展名的 atom）。
  - `engine_version` = sha256(dsconfig + phonemes.txt) 前 12 hex（D2）。

  注意：`dsconfig.yaml` 是 OpenUtau **推理**配置；DiffSinger 官方训练
  config 是它的超集，字段语义不同，不要混用。
  """

  @behaviour Equinox.Kernel.EngineAdapter

  alias Equinox.Kernel.{ChannelSpecs, Voicebank}
  alias EquinoxAdapters.{DiffSinger.Packaging, Util}

  @default_sample_rate 44_100
  @default_hop_size 512

  # ---- loader ----

  @doc """
  读取声库目录，返回 `{:ok, {__MODULE__, config}}`（可直接进 `engines`
  注册表）。`dsconfig.yaml` 优先，`dsconfig.json` 回退；两者皆缺报
  `{:error, {:dsconfig_not_found, dir}}`。
  """
  @spec load(Path.t()) :: {:ok, {module(), map()}} | {:error, term()}
  def load(dir) do
    with {:ok, dsconfig_binary, config} <- read_dsconfig(dir),
         {:ok, phonemes_binary} <- read_optional(Path.join(dir, "phonemes.txt")),
         {:ok, voicebank} <- build_voicebank(dir, dsconfig_binary, phonemes_binary, config) do
      {:ok,
       {__MODULE__,
        %{
          voicebank: voicebank,
          key_shift_range: key_shift_range(config),
          speakers: speakers_of(config)
        }}}
    end
  end

  defp build_voicebank(dir, dsconfig_binary, phonemes_binary, config) do
    sample_rate = Map.get(config, "sample_rate", @default_sample_rate)
    hop_size = Map.get(config, "hop_size", @default_hop_size)

    Voicebank.new(%{
      id: Util.character_name(dir) || Path.basename(dir),
      engine: :utau_diffsinger,
      engine_version: Util.content_stamp(dsconfig_binary <> phonemes_binary),
      models: models_of(config),
      dictionary: %{
        phonemes: parse_phonemes(phonemes_binary),
        languages: Map.get(config, "languages")
      },
      capabilities: %{
        supported_channels: [:phoneme_timing, :curve],
        supported_params: supported_params(config)
      },
      timing: %{frame_rate: sample_rate / hop_size, hop: hop_size}
    })
  end

  defp read_dsconfig(dir) do
    yaml_path = Path.join(dir, "dsconfig.yaml")
    json_path = Path.join(dir, "dsconfig.json")

    cond do
      File.exists?(yaml_path) ->
        with {:ok, binary} <- File.read(yaml_path),
             {:ok, config} <- YamlElixir.read_from_string(binary) do
          {:ok, binary, config}
        end

      File.exists?(json_path) ->
        with {:ok, binary} <- File.read(json_path),
             {:ok, config} <- Jason.decode(binary) do
          {:ok, binary, config}
        end

      true ->
        {:error, {:dsconfig_not_found, dir}}
    end
  end

  defp read_optional(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> {:ok, ""}
      {:error, _} = err -> err
    end
  end

  defp parse_phonemes(binary) do
    binary
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
  end

  defp models_of(config) do
    [:acoustic, :vocoder, :dur, :linguistic, :pitch, :variance]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(config, Atom.to_string(key)) do
        nil -> acc
        path -> Map.put(acc, key, path)
      end
    end)
  end

  # supported_params 推导（缺省值对齐 OpenUtau DsConfig：energy/breathiness
  # 缺省 true，tension/voicing 缺省 false）
  defp supported_params(config) do
    []
    |> maybe_add(Map.has_key?(config, "pitch"), :pitch)
    |> maybe_add(Map.get(config, "predict_energy", true), :energy)
    |> maybe_add(Map.get(config, "predict_breathiness", true), :breathiness)
    |> maybe_add(Map.get(config, "predict_tension", false), :tension)
    |> maybe_add(Map.get(config, "predict_voicing", false), :voicing)
    |> Enum.reverse()
  end

  defp maybe_add(params, condition, param) do
    if condition, do: [param | params], else: params
  end

  defp key_shift_range(config) do
    case get_in(config, ["augmentationArgs", "randomPitchShifting", "range"]) do
      [lo, hi] when is_number(lo) and is_number(hi) -> {:range, lo, hi}
      _ -> {:range, -12, 12}
    end
  end

  defp speakers_of(config) do
    case Map.get(config, "speakers") do
      [_ | _] = speakers -> Enum.map(speakers, &(&1 |> Path.rootname() |> String.to_atom()))
      _ -> nil
    end
  end

  # ---- EngineAdapter 回调 ----

  @impl true
  def engine_key(%{voicebank: voicebank}), do: Voicebank.engine_key(voicebank)

  @impl true
  def channels(%{voicebank: voicebank} = config) do
    key = engine_key(config)

    {:ok, phoneme_timing} = ChannelSpecs.build(:phoneme_timing, key)
    {:ok, curve} = ChannelSpecs.build(:curve, key, timing: voicebank.timing)

    # DiffSinger 版 target：窗口打包（notes+spans+tempo → sidecar words）
    # 扇出到推理节点 {:port, :infer, :words}（DiffSinger.InferStep）；patch
    # payload 的 delta 施加尚未接入（v1 忽略，投影/对拍语义不变）
    phoneme_timing = %{phoneme_timing | target: Packaging.target(voicebank.timing)}

    %{phoneme_timing: phoneme_timing, curve: curve}
  end

  @impl true
  def timing_spec(%{voicebank: voicebank}), do: {:ok, voicebank.timing}

  @impl true
  def globals(config) do
    %{key_shift: config.key_shift_range}
    |> then(fn rules ->
      case config.speakers do
        nil -> rules
        speakers -> Map.put(rules, :speaker, {:enum, speakers})
      end
    end)
  end

  @impl true
  def adoptables(_config), do: [:phoneme_timing, :curve]
end
