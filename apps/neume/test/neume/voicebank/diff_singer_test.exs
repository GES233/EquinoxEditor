defmodule Neume.Voicebank.DiffSingerTest do
  use ExUnit.Case, async: true

  alias Neume.Voicebank.{DiffSinger, Entry}

  @tag tmp_dir: true
  test "扫描完整声库并用语义资产生成稳定签名", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)

    assert {:ok, first} = DiffSinger.scan(root)
    assert first.name == "Test Singer"
    assert first.author == "Test Author"
    assert first.languages == %{"zh" => 1}
    assert Map.keys(first.speakers) == ["Normal"]
    assert first.timing == %{sample_rate: 44_100, hop_size: 512, frame_rate: 44_100 / 512}
    assert MapSet.member?(first.capabilities, :breathiness)
    assert MapSet.member?(first.capabilities, :predict_tension)

    signature = Entry.stock(first).signature
    assert signature.name == "Test Singer (Stock)"
    assert signature.engine == :diffsinger_stock
    assert byte_size(signature.digest) == 64

    assert :ok = File.write(first.models.acoustic, "acoustic-v2")
    assert {:ok, second} = DiffSinger.scan(root)
    refute first.digest == second.digest
  end

  @tag tmp_dir: true
  test "拒绝逃出声库根目录的模型引用", %{tmp_dir: tmp_dir} do
    root = Neume.VoicebankFixture.diffsinger(tmp_dir)
    acoustic_config = Path.join(root, "dsconfig.yaml")
    config = File.read!(acoustic_config)
    File.write!(acoustic_config, String.replace(config, "acoustic.onnx", "../../outside.onnx"))

    assert {:error, {:invalid_asset, :acoustic, {:asset_outside_voicebank, "../../outside.onnx"}}} =
             DiffSinger.scan(root)
  end
end
