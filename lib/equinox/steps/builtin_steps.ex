defmodule Equinox.Steps.Phonemizer do
  use Orchid.Step
  alias Orchid.Param

  def run(notes_param, _opts) do
    notes = Param.get_payload(notes_param)

    # 模拟注音逻辑
    phonemized =
      Enum.map(notes, fn note ->
        Map.put(note, :phoneme, note.lyric <> "_p")
      end)

    {:ok, Param.new(:linguistic, :linguistic) |> Param.set_payload(phonemized)}
  end
end

defmodule Equinox.Steps.AcousticModel do
  use Orchid.Step
  alias Orchid.Param

  def run([notes_param, linguistic_param], _opts) do
    notes = Param.get_payload(notes_param)
    linguistic = Param.get_payload(linguistic_param)

    # 模拟声学推理
    features =
      Enum.zip_with(notes, linguistic, fn _n, l ->
        "Features[#{l.phoneme}]"
      end)

    {:ok, Param.new(:mel, :mel) |> Param.set_payload(features)}
  end
end

defmodule Equinox.Steps.Vocoder do
  use Orchid.Step
  alias Orchid.Param

  def run(mel_param, _opts) do
    mels = Param.get_payload(mel_param)

    # 模拟声码器转换
    audio =
      Enum.map(mels, fn mel ->
        "AudioFloat32[#{mel}]"
      end)

    {:ok, Param.new(:audio, :audio) |> Param.set_payload(audio)}
  end
end

defmodule Equinox.Steps.TrackInput do
  @moduledoc """
  Arranger 的轨道入口，代表混音阶段接入的一条轨道的数据。
  带有 Offset 和 Volume。
  """
  use Orchid.Step
  alias Orchid.Param

  def run(audio_param, opts) do
    audio = Param.get_payload(audio_param)
    offset_tick = Keyword.get(opts, :offset_tick, 0)
    volume = Keyword.get(opts, :volume, 1.0)

    # 在实际情况中，它可能需要对齐音频的采样点
    processed = "Offset(#{offset_tick}):Vol(#{volume}):#{inspect(audio)}"

    {:ok, Param.new(:track_out, :audio) |> Param.set_payload(processed)}
  end
end

defmodule Equinox.Steps.Mixer do
  @moduledoc """
  汇总多条轨道的音频流进行相加混合。
  """
  use Orchid.Step
  alias Orchid.Param

  def run(tracks_params, _opts) when is_list(tracks_params) do
    tracks = Enum.map(tracks_params, &Param.get_payload/1)

    # 模拟叠加
    mixed = "Mix[#{Enum.join(tracks, " + ")}]"

    {:ok, Param.new(:mixed, :audio) |> Param.set_payload(mixed)}
  end

  def run(single_track_param, opts), do: run([single_track_param], opts)
end

defmodule Equinox.Steps.Output do
  @moduledoc """
  最终主输出设备或文件导出节点。
  """
  use Orchid.Step
  alias Orchid.Param

  def run(mixed_param, _opts) do
    mixed = Param.get_payload(mixed_param)

    # 这里可以是写入 .wav 或者发送给播放器的句柄
    {:ok, Param.new(:master_out, :audio) |> Param.set_payload(mixed)}
  end
end
