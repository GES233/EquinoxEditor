defmodule Neumu.VoicebankFixture do
  @moduledoc false

  # 测试用 OpenUtau 格式 DiffSinger 声库目录：配置、八个模型占位、
  # 字典与 speaker embedding 齐全，供 DiffSinger.scan/1 严格校验通过。
  # 与 apps/neume/test/support/voicebank_fixture.ex 同构；umbrella 各 app 的
  # test/support 不互相共享，这里保留一份最小拷贝。

  def diffsinger(parent, opts \\ []) do
    root = Path.join(parent, Keyword.get(opts, :directory, "voicebank"))

    for directory <- ["dsdur", "dspitch", "dsvariance", "dsvocoder", "linguistic", "embeds"] do
      File.mkdir_p!(Path.join(root, directory))
    end

    name = Keyword.get(opts, :name, "Test Singer")
    write(root, "character.txt", "name=#{name}\nauthor=Test Author\n")
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
