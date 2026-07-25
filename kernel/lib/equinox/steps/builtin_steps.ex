defmodule Equinox.Steps.Phonemizer do
  use Oi.Step, name: :phonemizer

  manifest(inputs: [:notes], outputs: [linguistic: :linguistic])

  routine notes, _opts do
    # 模拟注音逻辑
    phonemized =
      Enum.map(notes, fn note ->
        Map.put(note, :phoneme, note.lyric <> "_p")
      end)

    ok(phonemized)
  end
end

defmodule Equinox.Steps.AcousticModel do
  use Oi.Step, name: :acoustic_model

  manifest(inputs: [:notes, :linguistic], outputs: [mel: :mel])

  routine [notes, linguistic], _opts do
    # 模拟声学推理
    features =
      Enum.zip_with(notes, linguistic, fn _n, l ->
        "Features[#{l.phoneme}]"
      end)

    ok(features)
  end
end

defmodule Equinox.Steps.Vocoder do
  use Oi.Step, name: :vocoder

  manifest(inputs: [:mel], outputs: [audio: :audio])

  routine mels, _opts do
    # 模拟声码器转换
    audio =
      Enum.map(mels, fn mel ->
        "AudioFloat32[#{mel}]"
      end)

    ok(audio)
  end
end

defmodule Equinox.Steps.TrackInput do
  @moduledoc """
  Arranger 的轨道入口，代表混音阶段接入的一条轨道的数据。
  带有 Offset 和 Volume。
  """
  use Oi.Step, name: :track_input

  manifest(inputs: [:audio], outputs: [track_out: :audio])

  routine audio, opts do
    offset_tick = Keyword.get(opts, :offset_tick, 0)
    volume = Keyword.get(opts, :volume, 1.0)

    # 在实际情况中，它可能需要对齐音频的采样点
    processed = "Offset(#{offset_tick}):Vol(#{volume}):#{inspect(audio)}"

    ok(processed)
  end
end

defmodule Equinox.Steps.Mixer do
  @moduledoc """
  汇总多条轨道的音频流进行相加混合。
  """
  use Oi.Step, name: :mixer

  # 单端口多轨道：上游产出可以是轨道列表或单条轨道，经 List.wrap 归一
  manifest(inputs: [:tracks], outputs: [mixed: :audio])

  routine tracks, _opts do
    # 模拟叠加
    mixed = "Mix[#{tracks |> List.wrap() |> Enum.join(" + ")}]"

    ok(mixed)
  end
end

defmodule Equinox.Steps.Output do
  @moduledoc """
  最终主输出设备或文件导出节点。
  """
  use Oi.Step, name: :master_output

  manifest(inputs: [:mixed], outputs: [master_out: :audio])

  routine mixed, _opts do
    # 这里可以是写入 .wav 或者发送给播放器的句柄
    ok(mixed)
  end
end
