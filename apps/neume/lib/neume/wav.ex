defmodule Neume.Wav do
  @moduledoc """
  单声道 WAV 的读写与按绝对采样偏移拼接。

  读侧兼容 PCM16 与 float32（统一转成 s16le 采样二进制）；写侧固定
  PCM16。`concat/2` 间隙填零，重叠时后到者裁剪头部，保证先到内容的
  绝对位置不动。
  """

  @typedoc "内存中的单声道音频：`samples` 为 s16le 二进制。"
  @type clip :: %{samples: binary(), sample_rate: pos_integer()}

  @doc "读取 WAV 文件，统一返回 s16le 采样的 clip。"
  @spec read(Path.t()) :: {:ok, clip()} | {:error, term()}
  def read(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, clip} <- parse(binary) do
      {:ok, clip}
    end
  end

  @doc "把 s16le 采样写成 PCM16 单声道 WAV。"
  @spec write(Path.t(), binary(), pos_integer()) :: :ok | {:error, term()}
  def write(path, samples, sample_rate)
      when is_binary(samples) and is_integer(sample_rate) and sample_rate > 0 do
    data_size = byte_size(samples)

    header =
      <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
        1::little-16, sample_rate::little-32, sample_rate * 2::little-32, 2::little-16,
        16::little-16, "data", data_size::little-32>>

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, header <> samples)
    end
  end

  @doc """
  按绝对采样偏移拼接 `[%{clip: clip(), offset: non_neg_integer()}]`。

  间隙填零；重叠时后到者裁剪头部（先写内容位置不动）。返回总采样数
  与 s16le 二进制。
  """
  @spec concat([%{clip: clip(), offset: non_neg_integer()}], pos_integer()) ::
          {:ok, %{samples: binary(), sample_rate: pos_integer(), sample_count: non_neg_integer()}}
  def concat(items, sample_rate) when is_list(items) do
    items = Enum.sort_by(items, & &1.offset)

    {chunks, _cursor} =
      Enum.reduce(items, {[], 0}, fn %{clip: clip, offset: offset}, {chunks, cursor} ->
        sample_count = div(byte_size(clip.samples), 2)
        offset = max(offset, 0)
        gap = max(offset - cursor, 0)
        crop = max(cursor - offset, 0)
        keep = max(sample_count - crop, 0)

        chunk =
          if keep > 0 do
            binary_part(clip.samples, crop * 2, keep * 2)
          else
            <<>>
          end

        padding = :binary.copy(<<0, 0>>, gap)
        {[{padding, chunk} | chunks], max(offset, cursor) + keep}
      end)

    samples =
      chunks
      |> Enum.reverse()
      |> Enum.map(fn {padding, chunk} -> padding <> chunk end)
      |> IO.iodata_to_binary()

    {:ok, %{samples: samples, sample_rate: sample_rate, sample_count: div(byte_size(samples), 2)}}
  end

  # ---- 解析 ----

  defp parse(<<"RIFF", _size::little-32, "WAVE", rest::binary>>) do
    with {:ok, format, channels, sample_rate, bits, rest} <- find_fmt(rest),
         {:ok, data} <- find_data(rest) do
      convert(data, format, channels, sample_rate, bits)
    end
  end

  defp parse(_other), do: {:error, :invalid_wav}

  defp find_fmt(<<"fmt ", size::little-32, chunk::binary-size(size), rest::binary>>) do
    case chunk do
      <<format::little-16, channels::little-16, sample_rate::little-32, _byte_rate::little-32,
        _align::little-16, bits::little-16, _extra::binary>> ->
        {:ok, format, channels, sample_rate, bits, rest}

      _other ->
        {:error, :invalid_fmt_chunk}
    end
  end

  defp find_fmt(
         <<_id::binary-size(4), size::little-32, _chunk::binary-size(size), rest::binary>>
       ),
       do: find_fmt(rest)

  defp find_fmt(_other), do: {:error, :missing_fmt_chunk}

  defp find_data(<<"data", size::little-32, data::binary-size(size), _rest::binary>>),
    do: {:ok, data}

  defp find_data(
         <<_id::binary-size(4), size::little-32, _chunk::binary-size(size), rest::binary>>
       ),
       do: find_data(rest)

  defp find_data(_other), do: {:error, :missing_data_chunk}

  defp convert(data, 1, 1, sample_rate, 16), do: {:ok, %{samples: data, sample_rate: sample_rate}}

  defp convert(data, 3, 1, sample_rate, 32) do
    samples =
      for <<value::little-float-32 <- data>>, into: <<>> do
        clamped = value |> max(-1.0) |> min(1.0)
        <<round(clamped * 32767)::little-signed-16>>
      end

    {:ok, %{samples: samples, sample_rate: sample_rate}}
  end

  defp convert(_data, format, channels, _sample_rate, bits),
    do: {:error, {:unsupported_wav_format, format, channels, bits}}
end
