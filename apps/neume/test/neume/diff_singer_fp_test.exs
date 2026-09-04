defmodule Neume.DiffSingerFpTest do
  use ExUnit.Case, async: true

  alias Neume.Engine.{DiffSingerFp, DiffSingerPipeline}
  alias Neume.Voicebank.DiffSinger
  alias Neume.VoicebankFixture

  @tag tmp_dir: true
  test "加载合法 manifest，并拒绝缺失派生模型", %{tmp_dir: tmp_dir} do
    manifest =
      Map.new(~w(pitch_predict variance acoustic vocoder), fn key ->
        model = Path.join(tmp_dir, "#{key}.onnx")
        File.write!(model, key)
        {key, %{"path" => model, "noise" => []}}
      end)

    path = Path.join(tmp_dir, "fp_manifest.json")
    File.write!(path, Jason.encode!(manifest))

    assert {:ok, fp} = DiffSingerFp.load_manifest(path)
    assert fp.noise_version == DiffSingerFp.noise_version()
    assert byte_size(fp.manifest_digest) == 64
    assert fp.models["acoustic"] == Path.join(tmp_dir, "acoustic.onnx")

    File.rm!(fp.models["vocoder"])
    assert {:error, {:invalid_fp_manifest, ^path, _}} = DiffSingerFp.load_manifest(path)
  end

  @tag tmp_dir: true
  test "注入 client 默认不构建 FP，显式 stock/seed 进入 worker 与缓存身份", %{tmp_dir: tmp_dir} do
    root = VoicebankFixture.diffsinger(tmp_dir)
    assert {:ok, manifest} = DiffSinger.scan(root)

    assert {:ok, state} =
             DiffSingerPipeline.compile(
               manifest: manifest,
               track_id: "vocal",
               client: Neume.DiffSingerEditorTest.FakeClient,
               fp: false,
               seed: 7
             )

    assert state.worker_config.fp_manifest == nil
    assert state.worker_config.fp_manifest_digest == nil
    assert state.worker_config.fp_noise_version == nil
    assert state.worker_config.seed == 7
  end
end
