defmodule EquinoxAdapters.UTAUCompat do
  @moduledoc """
  UTAU CV 声库兼容适配器——**拼接式引擎边界**（无帧网格、ms 控制点域）。

  契约级实现（loader + 五回调）；真实音频渲染（resampler 子进程 /
  wavtool 拼接）是 Hook/Step 领地，不在此层。

  ## `load/1` 读取的声库文件

  - `oto.ini`（必需）：`wav名=别名,offset,consonant,cutoff,preutterance,
    overlap`，float 毫秒、空字段按 0、数值以 offset 为零点；cutoff 负值
    保留符号（resampler 约定：从文件末尾量）。v1 按 UTF-8 读取——
    真实声库默认 Shift-JIS（`#Charset:` 可覆盖），解码是 follow-up。
  - `character.txt`（可选）：`key=value`，`name` 作声库 id 缺省
    （缺省回落目录名）。
  - `prefix.map`（可选）：Tab 三列（音名 / 前缀 / 后缀），`#` 按空串
    兼容处理；进 `capabilities.subbanks`。

  `engine_version` = oto.ini 内容的 sha256 前 12 hex（文件型声库无
  semver，用内容戳——D2）；**无帧网格**（`timing_spec/1` 返回
  `{:error, :no_frame_grid}`，D1），曲线 channel 走控制点透传模态
  （UTAU pitch 本就是 PBS/PBW/PBY 稀疏控制点域）。
  """

  @behaviour Equinox.Kernel.EngineAdapter

  alias Equinox.Kernel.{ChannelSpecs, Voicebank}

  # resampler flags 子集（UTAU Wiki / OpenUtau 表达式表的公开范围；flag
  # 区分大小写；单位依 resampler 而异的 t 按 moresampler 的 cent 域声明）
  @resampler_flags %{
    g: {:range, -100, 100},
    B: {:range, 0, 100},
    t: {:range, -1200, 1200},
    Y: {:range, 0, 100},
    P: {:range, 0, 100}
  }

  # ---- loader ----

  @doc """
  读取 UTAU CV 声库目录，返回 `{:ok, {__MODULE__, config}}`——可直接进
  `engines` 注册表（`%{"vb_id" => {UTAUCompat, config}}`）。
  """
  @spec load(Path.t()) :: {:ok, {module(), map()}} | {:error, term()}
  def load(dir) do
    oto_path = Path.join(dir, "oto.ini")

    with {:ok, oto_binary} <- File.read(oto_path),
         {:ok, entries} <- parse_oto(oto_binary),
         {:ok, name} <- read_character_name(dir),
         {:ok, subbanks} <- read_prefix_map(dir) do
      {:ok, voicebank} =
        Voicebank.new(%{
          id: name || Path.basename(dir),
          engine: :utau,
          engine_version: content_stamp(oto_binary),
          models: %{oto: "oto.ini"} |> maybe_put_prefix_map(subbanks),
          dictionary: %{aliases: entries},
          capabilities: %{
            supported_channels: [:curve],
            supported_params: [:pitch],
            subbanks: subbanks
          },
          timing: %{}
        })

      {:ok, {__MODULE__, %{voicebank: voicebank}}}
    else
      {:error, :enoent} -> {:error, {:oto_not_found, oto_path}}
      {:error, _} = err -> err
    end
  end

  # D2：文件型声库无 semver，engine_version 用内容戳（sha256 前 12 hex）
  defp content_stamp(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp maybe_put_prefix_map(models, []), do: models
  defp maybe_put_prefix_map(models, _subbanks), do: Map.put(models, :prefix_map, "prefix.map")

  # ---- oto.ini 解析 ----

  @doc "解析 oto.ini 内容为条目列表（`%{alias, file, offset, consonant, cutoff, preutterance, overlap}`）。"
  @spec parse_oto(binary()) :: {:ok, [map()]} | {:error, term()}
  def parse_oto(binary) do
    binary
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_oto_line(line) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = err -> err
    end
  end

  defp parse_oto_line(line) do
    with [file, right] <- String.split(line, "=", parts: 2),
         [alias_name | numbers] <- String.split(right, ",", parts: 6),
         {:ok, [offset, consonant, cutoff, preutterance, overlap]} <- parse_numbers(numbers) do
      {:ok,
       %{
         alias: if(alias_name == "", do: Path.rootname(file), else: alias_name),
         file: file,
         offset: offset,
         consonant: consonant,
         cutoff: cutoff,
         preutterance: preutterance,
         overlap: overlap
       }}
    else
      _ -> {:error, {:invalid_oto_line, line}}
    end
  end

  # 空字段按 0（OpenUtau ParseDouble 语义）；数值最多 5 个，缺省补 0
  defp parse_numbers(numbers) do
    numbers = (numbers ++ ["0", "0", "0", "0", "0"]) |> Enum.take(5)

    numbers
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_ms(raw) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp parse_ms(""), do: {:ok, 0.0}

  defp parse_ms(raw) do
    case Float.parse(String.trim(raw)) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  # ---- character.txt / prefix.map ----

  defp read_character_name(dir) do
    case File.read(Path.join(dir, "character.txt")) do
      {:ok, binary} ->
        name =
          binary
          |> String.split("\n", trim: true)
          |> Enum.find_value(fn line ->
            case String.split(line, "=", parts: 2) do
              [key, value] -> if String.downcase(key) == "name", do: String.trim(value)
              _ -> nil
            end
          end)

        {:ok, name}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, _} = err ->
        err
    end
  end

  defp read_prefix_map(dir) do
    case File.read(Path.join(dir, "prefix.map")) do
      {:ok, binary} ->
        subbanks =
          binary
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim_trailing(&1, "\r"))
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t") do
              [tone, prefix, suffix] ->
                [%{tone: tone, prefix: placeholder(prefix), suffix: placeholder(suffix)}]

              _ ->
                []
            end
          end)

        {:ok, subbanks}

      {:error, :enoent} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  # `#` 是无词缀占位显示的兼容处理
  defp placeholder("#"), do: ""
  defp placeholder(value), do: value

  # ---- EngineAdapter 回调 ----

  @impl true
  def engine_key(%{voicebank: voicebank}), do: Voicebank.engine_key(voicebank)

  @impl true
  def channels(%{voicebank: voicebank}) do
    # D1：无帧网格 → 曲线走控制点透传模态
    {:ok, spec} = ChannelSpecs.build(:curve, engine_key(%{voicebank: voicebank}), timing: :none)
    %{curve: spec}
  end

  @impl true
  def timing_spec(_config), do: {:error, :no_frame_grid}

  @impl true
  def globals(_config), do: @resampler_flags

  @impl true
  def adoptables(_config), do: []
end
