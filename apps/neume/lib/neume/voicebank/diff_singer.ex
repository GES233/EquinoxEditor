defmodule Neume.Voicebank.DiffSinger do
  @moduledoc """
  OpenUtau 格式 DiffSinger 声库的只读描述符与扫描器。

  模型、字典与 embedding 始终留在仓库外。扫描结果保存规范化绝对路径，
  `signature/1` 则只暴露可进入 `Coconut.Project` 的名称、引擎类型和内容摘要。
  摘要覆盖会影响推理的配置、模型、字典及 embedding，不覆盖立绘和说明文件。
  """

  @config_paths %{
    acoustic: "dsconfig.yaml",
    duration: "dsdur/dsconfig.yaml",
    pitch: "dspitch/dsconfig.yaml",
    variance: "dsvariance/dsconfig.yaml",
    vocoder: "dsvocoder/vocoder.yaml"
  }

  @enforce_keys [
    :root,
    :name,
    :author,
    :digest,
    :models,
    :dictionaries,
    :languages,
    :speakers,
    :timing,
    :capabilities
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          root: Path.t(),
          name: String.t(),
          author: String.t() | nil,
          digest: String.t(),
          models: %{atom() => Path.t()},
          dictionaries: %{(atom() | String.t()) => Path.t()},
          languages: %{String.t() => non_neg_integer()},
          speakers: %{String.t() => Path.t()},
          timing: %{sample_rate: pos_integer(), hop_size: pos_integer(), frame_rate: float()},
          capabilities: MapSet.t(atom())
        }

  @doc "扫描并严格校验一个 OpenUtau 格式 DiffSinger 声库目录。"
  @spec scan(Path.t()) :: {:ok, t()} | {:error, term()}
  def scan(root) when is_binary(root) do
    root = Path.expand(root)

    with :ok <- ensure_directory(root),
         {:ok, configs} <- read_configs(root),
         {:ok, character} <- read_character(root),
         {:ok, models} <- resolve_models(root, configs),
         {:ok, dictionaries} <- resolve_dictionaries(root, configs),
         {:ok, languages} <- read_json(dictionaries.languages),
         :ok <- validate_languages(languages),
         {:ok, speakers} <- resolve_speakers(root, configs),
         {:ok, timing} <- resolve_timing(configs),
         {:ok, digest} <- digest_assets(root, models, dictionaries, speakers) do
      {:ok,
       %__MODULE__{
         root: root,
         name: Map.get(character, "name", Path.basename(root)),
         author: Map.get(character, "author"),
         digest: digest,
         models: models,
         dictionaries: dictionaries,
         languages: languages,
         speakers: speakers,
         timing: timing,
         capabilities: capabilities(configs.acoustic, configs.variance)
       }}
    end
  end

  def scan(root), do: {:error, {:invalid_voicebank_root, root}}

  defp ensure_directory(root) do
    if File.dir?(root), do: :ok, else: {:error, {:voicebank_not_found, root}}
  end

  defp read_configs(root) do
    Enum.reduce_while(@config_paths, {:ok, %{}}, fn {key, relative}, {:ok, acc} ->
      path = Path.join(root, relative)

      case read_yaml(path) do
        {:ok, config} when is_map(config) -> {:cont, {:ok, Map.put(acc, key, config)}}
        {:ok, other} -> {:halt, {:error, {:invalid_voicebank_config, relative, other}}}
        {:error, reason} -> {:halt, {:error, {:invalid_voicebank_config, relative, reason}}}
      end
    end)
  end

  defp read_yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- Jason.decode(bytes) do
      {:ok, value}
    end
  end

  defp read_character(root) do
    path = Path.join(root, "character.txt")

    with {:ok, text} <- File.read(path) do
      character =
        text
        |> String.split(~r/\R/u, trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
            _ -> acc
          end
        end)

      {:ok, character}
    else
      {:error, reason} -> {:error, {:invalid_character_file, reason}}
    end
  end

  defp resolve_models(root, configs) do
    specs = [
      {:duration_linguistic, "dsdur", configs.duration, "linguistic"},
      {:duration, "dsdur", configs.duration, "dur"},
      {:pitch_linguistic, "dspitch", configs.pitch, "linguistic"},
      {:pitch, "dspitch", configs.pitch, "pitch"},
      {:variance_linguistic, "dsvariance", configs.variance, "linguistic"},
      {:variance, "dsvariance", configs.variance, "variance"},
      {:acoustic, ".", configs.acoustic, "acoustic"},
      {:vocoder, "dsvocoder", configs.vocoder, "model"}
    ]

    resolve_specs(root, specs)
  end

  defp resolve_dictionaries(root, configs) do
    specs = [
      {:phonemes, ".", configs.acoustic, "phonemes"},
      {:languages, ".", configs.acoustic, "languages"}
    ]

    with {:ok, base} <- resolve_specs(root, specs) do
      lexical =
        root
        |> Path.join("dsdur/dsdict-*.yaml")
        |> Path.wildcard()
        |> Enum.reduce(%{}, fn path, acc ->
          language = path |> Path.basename(".yaml") |> String.replace_prefix("dsdict-", "")
          Map.put(acc, language, Path.expand(path))
        end)

      if map_size(lexical) == 0 do
        {:error, :missing_lexical_dictionaries}
      else
        {:ok, Map.merge(base, lexical)}
      end
    end
  end

  defp resolve_specs(root, specs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {name, base, config, key}, {:ok, acc} ->
      with {:ok, relative} <- fetch_string(config, key),
           {:ok, path} <- resolve_asset(root, Path.join(root, base), relative) do
        {:cont, {:ok, Map.put(acc, name, path)}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_asset, name, reason}}}
      end
    end)
  end

  defp resolve_speakers(root, configs) do
    speakers = Map.get(configs.acoustic, "speakers", [])

    if is_list(speakers) and speakers != [] and Enum.all?(speakers, &is_binary/1) do
      Enum.reduce_while(speakers, {:ok, %{}}, fn name, {:ok, acc} ->
        candidates = [Path.join(root, "embeds/#{name}.emb"), Path.join(root, "#{name}.emb")]

        case Enum.find(candidates, &File.regular?/1) do
          nil -> {:halt, {:error, {:missing_speaker_embedding, name}}}
          path -> {:cont, {:ok, Map.put(acc, name, Path.expand(path))}}
        end
      end)
    else
      {:error, {:invalid_speakers, speakers}}
    end
  end

  defp resolve_timing(configs) do
    configs = [
      configs.acoustic,
      configs.duration,
      configs.pitch,
      configs.variance,
      configs.vocoder
    ]

    timings = Enum.map(configs, &{Map.get(&1, "sample_rate"), Map.get(&1, "hop_size")})

    case Enum.uniq(timings) do
      [{sample_rate, hop_size}]
      when is_integer(sample_rate) and sample_rate > 0 and is_integer(hop_size) and hop_size > 0 ->
        {:ok, %{sample_rate: sample_rate, hop_size: hop_size, frame_rate: sample_rate / hop_size}}

      _ ->
        {:error, {:inconsistent_timing, timings}}
    end
  end

  defp validate_languages(languages) when is_map(languages) do
    if map_size(languages) > 0 and
         Enum.all?(languages, fn {name, id} ->
           is_binary(name) and is_integer(id) and id >= 0
         end) do
      :ok
    else
      {:error, {:invalid_languages, languages}}
    end
  end

  defp validate_languages(languages), do: {:error, {:invalid_languages, languages}}

  defp capabilities(acoustic, variance) do
    [
      {:key_shift, Map.get(acoustic, "use_key_shift_embed", false)},
      {:speed, Map.get(acoustic, "use_speed_embed", false)},
      {:energy, Map.get(acoustic, "use_energy_embed", false)},
      {:breathiness, Map.get(acoustic, "use_breathiness_embed", false)},
      {:voicing, Map.get(acoustic, "use_voicing_embed", false)},
      {:tension, Map.get(acoustic, "use_tension_embed", false)},
      {:falsetto_deviation, Map.get(acoustic, "use_falsetto_dev_embed", false)},
      {:continuous_acceleration, Map.get(acoustic, "use_continuous_acceleration", false)},
      {:variable_depth, Map.get(acoustic, "use_variable_depth", false)},
      {:predict_energy, Map.get(variance, "predict_energy", false)},
      {:predict_breathiness, Map.get(variance, "predict_breathiness", false)},
      {:predict_voicing, Map.get(variance, "predict_voicing", false)},
      {:predict_tension, Map.get(variance, "predict_tension", false)},
      {:predict_falsetto_deviation, Map.get(variance, "predict_falsetto_dev", false)}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp fetch_string(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_config_value, key, value}}
      :error -> {:error, {:missing_config_value, key}}
    end
  end

  defp resolve_asset(root, base, relative) do
    path = Path.expand(relative, base)
    relative_to_root = Path.relative_to(path, root)

    outside? =
      Path.type(relative_to_root) == :absolute or
        relative_to_root == ".." or
        String.starts_with?(relative_to_root, "../") or
        String.starts_with?(relative_to_root, "..\\")

    cond do
      outside? ->
        {:error, {:asset_outside_voicebank, relative}}

      not File.regular?(path) ->
        {:error, {:asset_not_found, relative}}

      true ->
        {:ok, path}
    end
  end

  defp digest_assets(root, models, dictionaries, speakers) do
    config_files = Enum.map(@config_paths, fn {_key, path} -> Path.join(root, path) end)

    semantic_files =
      ["character.txt", "dsdict*.yaml", "dsdur/dsdict*.yaml"]
      |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))

    files =
      config_files ++
        Map.values(models) ++
        Map.values(dictionaries) ++
        Map.values(speakers) ++
        semantic_files

    files
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn path, {:ok, context} ->
      relative = path |> Path.relative_to(root) |> String.replace("\\", "/")

      context =
        :crypto.hash_update(context, <<byte_size(relative)::unsigned-big-64, relative::binary>>)

      case hash_file(path, context) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:digest_failed, relative, reason}}}
      end
    end)
    |> case do
      {:ok, context} -> {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, _} = error -> error
    end
  end

  defp hash_file(path, context) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      result = hash_chunks(file, context)
      File.close(file)
      result
    end
  end

  defp hash_chunks(file, context) do
    case IO.binread(file, 1_048_576) do
      :eof -> {:ok, context}
      {:error, reason} -> {:error, reason}
      bytes -> hash_chunks(file, :crypto.hash_update(context, bytes))
    end
  end
end
