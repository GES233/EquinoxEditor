defmodule NeumeLab.SineRendererTest do
  @moduledoc """
  正弦演示渲染器：经 facade 渲染任务产出可听 WAV 制品；空工程返回
  tagged error 且不产生制品。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  setup %{tmp_dir: tmp_dir} do
    demo = NeumeLab.Fixture.open_demo(dir: Path.join(tmp_dir, "lab"))

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(demo.project_id), do: Neumu.close_project(demo.project_id)
    end)

    %{demo: demo}
  end

  test "渲染演示工程：制品是合法 16-bit PCM WAV，时长覆盖全部音符", %{demo: demo} do
    :ok = Neumu.subscribe(demo.project_id)

    {:ok, job} = Neumu.submit_render(demo.project_id, renderer: &NeumeLab.SineRenderer.render/1)
    assert_receive {:artifact_ready, job_id, artifact_id, _pin}, 10_000
    assert job_id == job.id

    {:ok, artifact} = Neumu.artifact(artifact_id)
    assert artifact.sample_rate == 44_100
    # 末音符 1920 tick × 0.5/480 s/tick = 2.0s → 88_200 采样。
    assert artifact.sample_count == 88_200
    assert_in_delta artifact.duration_sec, 2.0, 0.01
    assert artifact.track_ids == ["lead"]

    wav = File.read!(artifact.path)
    assert <<"RIFF", size::little-32, "WAVE", _rest::binary>> = wav
    assert size == 36 + artifact.sample_count * 2
    assert byte_size(wav) == 44 + artifact.sample_count * 2
  end

  test "空工程返回 {:error, :no_notes}，任务失败且无制品", %{tmp_dir: tmp_dir} do
    root = NeumeLab.Fixture.voicebank(Path.join(tmp_dir, "empty"))
    {:ok, registry} = Neume.Voicebank.Registry.discover(root)
    project_id = "lab-empty-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id,
        voicebank_registry: registry,
        diffsinger_client: NeumeLab.DemoClient,
        output_dir: Path.join(tmp_dir, "renders")
      )

    :ok = Neumu.subscribe(project_id)

    {:ok, job} = Neumu.submit_render(project_id, renderer: &NeumeLab.SineRenderer.render/1)
    assert_receive {:render_changed, job_id, :failed}, 10_000
    assert job_id == job.id

    {:ok, [failed]} = Neumu.list_render_jobs(project_id)
    assert %{status: :failed, artifact_id: nil, error: :no_notes} = failed
  end
end
