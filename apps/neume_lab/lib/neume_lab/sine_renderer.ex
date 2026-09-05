defmodule NeumeLab.SineRenderer do
  @moduledoc """
  演示渲染器：把工程音符正弦合成为单声道 WAV，验证"渲染 → 制品 →
  试听/导出"闭环而不触碰 DiffSinger 推理。

  音高准确（含微分音十进制字符串）、时值按固定 120 BPM（PPQ 480）折算，
  音色只是正弦波；不构成产品质量，也不进入渲染缓存。
  """

  alias Neume.MixArtifact

  @sample_rate 44_100
  # 演示拍速：120 BPM、四分音符 480 tick → 每 tick 0.5/480 秒
  @sec_per_tick 0.5 / 480
  @amplitude 0.3
  @fade_samples 220

  @doc """
  渲染入口（facade `submit_render/2` 的 `:renderer` 契约，arity 1）。

  从 `Neume.MultiTrack` 投影音符，合成 WAV 写入工程的 `output_dir`，
  返回登记用的 `Neume.MixArtifact`。
  """
  @spec render(Neume.MultiTrack.t()) :: {:ok, MixArtifact.t()} | {:error, term()}
  def render(%Neume.MultiTrack{} = multi_track) do
    snapshot = Neumu.ProjectSnapshot.build(multi_track, "lab-render")

    case synthesize(snapshot.tracks) do
      {:ok, samples} ->
        path = Path.join(multi_track.output_dir, "lab-render-#{unique()}.wav")

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, encode_wav(samples)) do
          {:ok,
           %MixArtifact{
             path: path,
             sample_rate: @sample_rate,
             sample_count: div(bit_size(samples), 16),
             duration_sec: div(bit_size(samples), 16) / @sample_rate,
             track_ids: Enum.map(snapshot.tracks, & &1.id)
           }}
        else
          {:error, reason} -> {:error, {:write_failed, reason}}
        end

      :empty ->
        {:error, :no_notes}
    end
  end

  defp unique, do: System.unique_integer([:positive])

  # 全部音符混进一个 float 采样缓冲；无音符时返回 :empty。
  defp synthesize(tracks) do
    notes =
      for track <- tracks, note <- track.notes, freq = note_freq(note.pitch) do
        {note.start_tick, note.end_tick, freq}
      end

    if notes == [] do
      :empty
    else
      total_ticks = notes |> Enum.map(fn {_s, e, _f} -> e end) |> Enum.max()
      total_samples = max(round(total_ticks * @sec_per_tick * @sample_rate), @sample_rate)
      buffer = :array.new(total_samples, default: 0.0, fixed: true)

      buffer =
        Enum.reduce(notes, buffer, fn {start_tick, end_tick, freq}, acc ->
          mix_note(acc, tick_sample(start_tick), tick_sample(end_tick), freq, total_samples)
        end)

      {:ok, encode_samples(buffer, total_samples)}
    end
  end

  defp tick_sample(tick), do: round(tick * @sec_per_tick * @sample_rate)

  # 单音符正弦（带短淡入淡出防爆音）叠加进缓冲。
  defp mix_note(buffer, first, last, freq, total_samples) do
    first = min(first, total_samples - 1)
    last = min(max(last, first + 1), total_samples)

    Enum.reduce(first..(last - 1), buffer, fn i, acc ->
      t = i / @sample_rate
      fade = min((i - first) / @fade_samples, (last - 1 - i) / @fade_samples)
      gain = @amplitude * min(max(fade, 0.0), 1.0)
      :array.set(i, :array.get(i, acc) + gain * :math.sin(2 * :math.pi() * freq * t), acc)
    end)
  end

  defp encode_samples(buffer, total_samples) do
    for i <- 0..(total_samples - 1), into: <<>> do
      value = :array.get(i, buffer) |> max(-1.0) |> min(1.0)
      <<round(value * 32_767)::little-signed-16>>
    end
  end

  defp note_freq(nil), do: nil
  defp note_freq(midi) when is_number(midi), do: 440.0 * :math.pow(2, (midi - 69) / 12)

  defp note_freq(midi) when is_binary(midi) do
    case Float.parse(midi) do
      {value, _rest} -> note_freq(value)
      :error -> nil
    end
  end

  # 16-bit 单声道 PCM WAV 头 + 数据。
  defp encode_wav(samples) do
    data_size = byte_size(samples)

    header =
      <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
        1::little-16, @sample_rate::little-32, @sample_rate * 2::little-32, 2::little-16,
        16::little-16, "data", data_size::little-32>>

    header <> samples
  end
end
