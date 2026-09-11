defmodule NeumeOpuDs.Voicebank.ManifestTest do
  use ExUnit.Case, async: true

  alias NeumeOpuDs.Voicebank.{Manifest, Provider}

  @tag tmp_dir: true
  test "扫描完整声库并用语义资产生成稳定签名", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, first} = Manifest.scan(root)
    assert first.name == "Test Singer"
    assert first.author == "Test Author"
    assert first.languages == %{"zh" => 1}
    assert Map.keys(first.speakers) == ["Normal"]
    assert first.timing == %{sample_rate: 44_100, hop_size: 512, frame_rate: 44_100 / 512}
    assert MapSet.member?(first.capabilities, :breathiness)
    assert MapSet.member?(first.capabilities, :predict_tension)

    signature = Provider.stock(first).signature
    assert signature.name == "Test Singer (Stock)"
    assert signature.engine == :diffsinger_stock
    assert byte_size(signature.digest) == 64

    assert :ok = File.write(first.models.acoustic, "acoustic-v2")
    assert {:ok, second} = Manifest.scan(root)
    refute first.digest == second.digest
  end

  @tag tmp_dir: true
  test "phonology digest 只随字典资产变化，不随模型变化", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, first} = Manifest.scan(root)
    assert byte_size(first.phonology_digest) == 64
    refute first.phonology_digest == first.digest

    # 模型权重变化：全量 digest 变，字典级 phonology digest 不变
    # （Stock/Modified 切换或模型质量刷新不炸 Ph/Co pin）。
    assert :ok = File.write(first.models.acoustic, "acoustic-v2")
    assert {:ok, second} = Manifest.scan(root)
    refute first.digest == second.digest
    assert first.phonology_digest == second.phonology_digest

    # 词典内容变化：两者都变（segment 存在性/映射可能改变）。
    assert :ok = File.write(Path.join(root, "dsdur/dsdict-zh.yaml"), "entries: [你]\n")
    assert {:ok, third} = Manifest.scan(root)
    refute first.digest == third.digest
    refute first.phonology_digest == third.phonology_digest

    # 音素 inventory 变化同样进 phonology digest。
    assert :ok = File.write(Path.join(root, "phonemes.json"), ~s({"SP":1,"zh/a":2,"zh/e":3}))
    assert {:ok, fourth} = Manifest.scan(root)
    refute first.phonology_digest == fourth.phonology_digest
  end

  @tag tmp_dir: true
  test "拒绝逃出声库根目录的模型引用", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)
    acoustic_config = Path.join(root, "dsconfig.yaml")
    config = File.read!(acoustic_config)
    File.write!(acoustic_config, String.replace(config, "acoustic.onnx", "../../outside.onnx"))

    assert {:error, {:invalid_asset, :acoustic, {:asset_outside_voicebank, "../../outside.onnx"}}} =
             Manifest.scan(root)
  end

  @tag tmp_dir: true
  test "runtime phonology digest 混入 G2P 算法版本戳", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, manifest} = Manifest.scan(root)
    state = %{manifest: manifest}

    digest = NeumeOpuDs.Runtime.phonology_digest(state)
    assert byte_size(digest) == 64
    refute digest == manifest.phonology_digest
    assert digest == NeumeOpuDs.Pipeline.phonology_digest(state)

    # 钉住合成格式：domain separator + 字典摘要 + G2P 版本戳。
    expected =
      :crypto.hash(:sha256, [
        "neume/phonology/1\0",
        manifest.phonology_digest,
        "\0",
        NeumeOpuDs.Pipeline.g2p_version()
      ])
      |> Base.encode16(case: :lower)

    assert digest == expected
  end
end
