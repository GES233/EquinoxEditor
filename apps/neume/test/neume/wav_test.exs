defmodule Neume.WavTest do
  use ExUnit.Case, async: true

  alias Neume.Wav

  defp pcm(values), do: for(v <- values, into: <<>>, do: <<v::little-signed-16>>)

  @tag tmp_dir: true
  test "PCM16 写入后读回一致", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "roundtrip.wav")
    samples = pcm([0, 1000, -1000, 32767, -32768])

    assert :ok = Wav.write(path, samples, 44_100)
    assert {:ok, clip} = Wav.read(path)
    assert clip.sample_rate == 44_100
    assert clip.samples == samples
  end

  @tag tmp_dir: true
  test "float32 WAV 读时转 PCM16", %{tmp_dir: tmp_dir} do
    floats = [0.0, 0.5, -0.5, 1.0, -1.0]
    data = for(v <- floats, into: <<>>, do: <<v::little-float-32>>)
    data_size = byte_size(data)

    binary =
      <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 3::little-16,
        1::little-16, 44_100::little-32, 44_100 * 4::little-32, 4::little-16, 32::little-16,
        "data", data_size::little-32>> <> data

    path = Path.join(tmp_dir, "float.wav")
    File.write!(path, binary)

    assert {:ok, clip} = Wav.read(path)
    assert clip.samples == pcm([0, 16384, -16384, 32767, -32767])
  end

  @tag tmp_dir: true
  test "非 WAV 报错", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bad.wav")
    File.write!(path, "not a wav")
    assert {:error, :invalid_wav} = Wav.read(path)
  end

  test "concat 间隙填零、保持偏移" do
    a = pcm([1, 1, 1])
    b = pcm([2, 2])

    assert {:ok, result} =
             Wav.concat(
               [
                 %{clip: %{samples: a, sample_rate: 10}, offset: 0},
                 %{clip: %{samples: b, sample_rate: 10}, offset: 5}
               ],
               10
             )

    assert result.samples == pcm([1, 1, 1, 0, 0, 2, 2])
    assert result.sample_count == 7
  end

  test "concat 重叠时后到者裁剪头部" do
    a = pcm([1, 1, 1, 1])
    b = pcm([2, 2, 2])

    assert {:ok, result} =
             Wav.concat(
               [
                 %{clip: %{samples: a, sample_rate: 10}, offset: 0},
                 %{clip: %{samples: b, sample_rate: 10}, offset: 2}
               ],
               10
             )

    assert result.samples == pcm([1, 1, 1, 1, 2])
  end

  test "concat 空列表得空音频" do
    assert {:ok, result} = Wav.concat([], 44_100)
    assert result.sample_count == 0
  end
end
