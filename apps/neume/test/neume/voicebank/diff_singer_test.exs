defmodule Neume.Voicebank.DiffSingerTest do
  use ExUnit.Case, async: true

  alias Neume.Voicebank.DiffSinger

  @tag tmp_dir: true
  test "扫描完整声库并用语义资产生成稳定签名", %{tmp_dir: tmp_dir} do
    root = fixture(tmp_dir)

    assert {:ok, first} = DiffSinger.scan(root)
    assert first.name == "Test Singer"
    assert first.author == "Test Author"
    assert first.languages == %{"zh" => 1}
    assert Map.keys(first.speakers) == ["Normal"]
    assert first.timing == %{sample_rate: 44_100, hop_size: 512, frame_rate: 44_100 / 512}
    assert MapSet.member?(first.capabilities, :breathiness)
    assert MapSet.member?(first.capabilities, :predict_tension)

    signature = DiffSinger.signature(first)
    assert signature.name == "Test Singer"
    assert signature.engine == :diffsinger
    assert byte_size(signature.digest) == 64

    assert :ok = File.write(first.models.acoustic, "acoustic-v2")
    assert {:ok, second} = DiffSinger.scan(root)
    refute first.digest == second.digest
  end

  @tag tmp_dir: true
  test "拒绝逃出声库根目录的模型引用", %{tmp_dir: tmp_dir} do
    root = fixture(tmp_dir)
    acoustic_config = Path.join(root, "dsconfig.yaml")
    config = File.read!(acoustic_config)
    File.write!(acoustic_config, String.replace(config, "acoustic.onnx", "../../outside.onnx"))

    assert {:error, {:invalid_asset, :acoustic, {:asset_outside_voicebank, "../../outside.onnx"}}} =
             DiffSinger.scan(root)
  end

  def fixture(parent) do
    root = Path.join(parent, "voicebank")

    for directory <- ["dsdur", "dspitch", "dsvariance", "dsvocoder", "linguistic", "embeds"] do
      File.mkdir_p!(Path.join(root, directory))
    end

    write(root, "character.txt", "name=Test Singer\nauthor=Test Author\n")
    write(root, "languages.json", ~s({"zh":1}))
    write(root, "phonemes.json", ~s({"SP":1,"zh/a":2}))
    write(root, "dsdict-zh.yaml", "entries: []\n")
    write(root, "dsdur/dsdict-zh.yaml", "entries: []\n")

    write(
      root,
      "dsconfig.yaml",
      """
      phonemes: phonemes.json
      languages: languages.json
      acoustic: acoustic.onnx
      speakers: [Normal]
      use_breathiness_embed: true
      sample_rate: 44100
      hop_size: 512
      """
    )

    write(
      root,
      "dsdur/dsconfig.yaml",
      stage_config("dur", "duration.onnx")
    )

    write(
      root,
      "dspitch/dsconfig.yaml",
      stage_config("pitch", "pitch.onnx")
    )

    write(
      root,
      "dsvariance/dsconfig.yaml",
      stage_config("variance", "variance.onnx") <> "predict_tension: true\n"
    )

    write(
      root,
      "dsvocoder/vocoder.yaml",
      "model: vocoder.onnx\nsample_rate: 44100\nhop_size: 512\n"
    )

    for path <- [
          "acoustic.onnx",
          "linguistic/model.onnx",
          "dsdur/duration.onnx",
          "dspitch/pitch.onnx",
          "dsvariance/variance.onnx",
          "dsvocoder/vocoder.onnx",
          "embeds/Normal.emb"
        ] do
      write(root, path, path)
    end

    root
  end

  defp stage_config(key, model) do
    """
    phonemes: ../phonemes.json
    languages: ../languages.json
    linguistic: ../linguistic/model.onnx
    #{key}: #{model}
    sample_rate: 44100
    hop_size: 512
    """
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
