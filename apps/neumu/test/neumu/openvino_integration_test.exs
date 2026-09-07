defmodule Neumu.OpenVinoIntegrationTest do
  @moduledoc "显式启用的本机 GPU facade 闭环；不修改模型、不要求后端字节一致。"
  use ExUnit.Case, async: false

  @moduletag :openvino
  @moduletag timeout: 300_000
  @moduletag tmp_dir: true

  alias Neume.Voicebank.Registry
  alias NeumeOpuDs.Fp, as: DiffSingerFp
  alias NeumeOpuDs.Voicebank.{Manifest, Provider}

  test "真实混合后端经 Neumu check、异步渲染、导出和读档", %{tmp_dir: tmp_dir} do
    python = System.fetch_env!("DS_PYTHON")
    root = System.fetch_env!("DS_VOICEBANK")
    fp_path = System.fetch_env!("DS_FP_MANIFEST")
    assert File.regular?(python)
    assert {:ok, manifest} = Manifest.scan(root)
    assert {:ok, fp} = DiffSingerFp.load_manifest(fp_path)
    entry = Provider.modified(manifest, fp)
    registry = %Registry{entries: %{entry.id => entry}, diagnostics: []}
    id = "openvino-#{System.unique_integer([:positive])}"

    opts = [
      voicebank_registry: registry,
      python: [python],
      diffsinger_backend: :openvino,
      output_dir: tmp_dir,
      seed: 0
    ]

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(id), do: Neumu.close_project(id)
    end)

    assert {:ok, _pid} = Neumu.create_project(id, opts)
    assert {:ok, 1} = Neumu.add_track(id, "lead", entry.id)

    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 960}, %{pitch: 60, lyric: "啦"})

    assert {:ok, %{pin: 2, status: :ok}} = Neumu.check(id)
    assert :ok = Neumu.subscribe(id)

    for repeat <- 1..2 do
      assert {:ok, job} = Neumu.submit_render(id)
      job_id = job.id
      assert_receive {:artifact_ready, ^job_id, artifact_id, 2}, 120_000
      path = Path.join(tmp_dir, "gpu-#{repeat}.wav")
      assert {:ok, ^path} = Neumu.export_artifact(artifact_id, path)
      assert {:ok, "RIFF" <> _rest} = File.read(path)
      assert File.stat!(path).size > 44
    end

    assert {:ok, 2} = Neumu.history_pin(id)
    path = Path.join(tmp_dir, "project.neume")
    assert {:ok, ^path} = Neumu.save_project(id, path)
    assert :ok = Neumu.close_project(id)
    assert {:ok, _pid} = Neumu.load_project(id, path, opts)
    assert {:ok, %{pin: 2, status: :ok}} = Neumu.check(id)
  end
end
