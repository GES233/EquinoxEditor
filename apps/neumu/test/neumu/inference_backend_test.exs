defmodule Neumu.InferenceBackendTest do
  @moduledoc "实验后端选项穿过 facade、读档、check 与异步渲染；不加载真模型。"
  use ExUnit.Case, async: false

  alias Neumu.ProjectStub

  defmodule Client do
    @behaviour Neume.Engine.DiffSingerWorker

    @impl true
    def call(payload, config) do
      send(config.test_pid, {:backend_call, payload.action, config.backend})
      execute(payload, config)
    end

    defp execute(%{action: "render", out_path: path, ph_dur: durations}, _config) do
      frames = Enum.sum(durations)
      samples = frames * 512
      :ok = Neume.Wav.write(path, :binary.copy(<<0, 0>>, samples), 44_100)

      {:ok,
       %{
         "path" => path,
         "sample_rate" => 44_100,
         "frames" => frames,
         "samples" => samples,
         "duration_sec" => samples / 44_100
       }}
    end

    defp execute(payload, config), do: ProjectStub.PhonemesClient.call(payload, config)
  end

  @tag tmp_dir: true
  test "后端不改工程身份，create/load 可分别选择并经原协议渲染", %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "backend-#{System.unique_integer([:positive])}"

    opts =
      ProjectStub.open_opts(registry, tmp_dir, Client) ++
        [diffsinger_backend: :openvino, diffsinger_client_config: %{test_pid: self()}]

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    assert {:ok, _pid} = Neumu.create_project(project_id, opts)
    assert {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)

    assert {:ok, 2} =
             Neumu.insert_note(project_id, "lead", "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "a",
               phonemes: [["zh", "a"]]
             })

    assert {:ok, %{status: :ok}} = Neumu.check(project_id)
    assert_received {:backend_call, "check", :openvino}
    assert :ok = Neumu.subscribe(project_id)

    for _repeat <- 1..2 do
      assert {:ok, job} = Neumu.submit_render(project_id)
      job_id = job.id
      assert_receive {:artifact_ready, ^job_id, artifact_id, 2}, 10_000
      assert_receive {:backend_call, "render", :openvino}
      assert {:ok, _path} = Neumu.export_artifact(artifact_id, Path.join(tmp_dir, "audio.wav"))
    end

    assert {:ok, 2} = Neumu.history_pin(project_id)
    path = Path.join(tmp_dir, "project.neume")
    assert {:ok, ^path} = Neumu.save_project(project_id, path)
    assert :ok = Neumu.close_project(project_id)

    assert {:ok, _pid} =
             Neumu.load_project(project_id, path, Keyword.put(opts, :diffsinger_backend, :cpu))

    assert {:ok, 2} = Neumu.history_pin(project_id)
    assert {:ok, %{status: :ok}} = Neumu.check(project_id)
    assert_received {:backend_call, "check", :cpu}
  end
end
