defmodule Neumu.ContractTest do
  @moduledoc """
  契约级端到端场景：参考客户端（`Neumu.RefClient`）按 facade 协议跑完
  建工程 → 编辑 → pin 挂载（含 stale 重放）→ 冲突 check → repatch →
  按 pin 渲染对比 → 导出 的完整回路。前端实现的协议步骤以这里为准。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.{ProjectStub, RefClient}
  alias Neumu.ProjectStub.PhonemesClient

  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    # 制品落一个真实文件，导出测试才有源。
    wav_path = Path.join(tmp_dir, "stub.wav")
    File.write!(wav_path, "RIFFfakeWAVE")

    renderer = fn _multi_track -> {:ok, %{ProjectStub.mix_artifact() | path: wav_path}} end

    %{project_id: project_id, stock: stock, renderer: renderer, tmp_dir: tmp_dir}
  end

  defp notes(client, track_id \\ "lead") do
    client.snapshot.tracks |> Enum.find(&(&1.id == track_id)) |> Map.fetch!(:notes)
  end

  test "完整契约回路", %{project_id: id, stock: stock, renderer: renderer, tmp_dir: tmp_dir} do
    # —— 建工程与初始镜像 ——
    assert {:ok, 1} = Neumu.add_track(id, "lead", stock.id)

    assert {:ok, 2} =
             Neumu.insert_note(id, "lead", "n1", :head, {0, 480}, %{
               pitch: 60,
               lyric: "la",
               phonemes: [["zh", "l"], ["zh", "a"]]
             })

    assert {:ok, client} = RefClient.open(id)
    assert client.pin == 2
    assert [%{id: "n1", lyric: "la"}] = notes(client)

    # —— 编辑手势：拆分（镜像随 pin 前进同步） ——
    assert {:ok, client} =
             RefClient.dispatch(client, fn -> Neumu.split_note(id, "lead", "n1", 240, "n1b") end)

    assert client.pin == 3
    assert [%{id: "n1"}, %{id: "n1b"}] = notes(client)

    # —— pin 挂载：并发编辑导致 stale，参考客户端重放 ——
    {:ok, stale_probe} = Neumu.probe_pin(id, "lead", "n1")

    assert {:ok, client} =
             RefClient.dispatch(client, fn -> Neumu.edit_note(id, "lead", "n1", %{pitch: 62}) end)

    assert client.pin == 4

    assert {:stale, client} =
             RefClient.dispatch(client, fn ->
               Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], stale_probe)
             end)

    assert {:ok, client} =
             RefClient.mount(client, "lead", "n1", fn fresh ->
               Neumu.mount_pitch(id, "lead", "n1", [[120, 72]], fresh)
             end)

    assert client.pin == 5

    assert {:ok, client} =
             RefClient.mount(client, "lead", "n1", fn probe ->
               Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], probe)
             end)

    assert client.pin == 6

    assert [%{channel: :pitch}, %{channel: :duration}] =
             client.snapshot.tracks |> hd() |> Map.fetch!(:pins)

    # —— 试听 A/B：渲染挂载前（pin 4）与挂载后（pin 6） ——
    assert {:ok, job_a} = Neumu.submit_render(id, pin: 4, renderer: renderer)
    assert {:ok, job_b} = Neumu.submit_render(id, pin: 6, renderer: renderer)
    assert_receive {:artifact_ready, _, artifact_a, 4}
    assert_receive {:artifact_ready, _, artifact_b, 6}
    assert job_a.source_pin == 4 and job_b.source_pin == 6

    # —— 改词 → 冲突占一等位置 → 一键 repatch ——
    assert {:ok, client} =
             RefClient.dispatch(client, fn ->
               Neumu.edit_note(id, "lead", "n1", %{lyric: "lo"})
             end)

    assert client.pin == 7

    assert {:ok, %{pin: 7, status: :failed, entries: entries}} = Neumu.check(id)

    assert [
             %{kind: :conflict, channel: :duration, patch_id: duration_patch},
             %{kind: :conflict, channel: :pitch, patch_id: pitch_patch}
           ] = Enum.sort_by(entries, & &1.channel)

    assert {:ok, 8, results} = Neumu.repatch(id, "lead", [duration_patch, pitch_patch])
    assert Enum.all?(results, &(&1.status == :repatched))

    {:ok, client} = RefClient.sync(client)
    assert client.pin == 8
    assert {:ok, %{pin: 8, status: :ok, entries: []}} = Neumu.check(id)

    # —— 导出制品（完整落盘） ——
    dest = Path.join(tmp_dir, "exports/mix-a.wav")
    assert {:ok, ^dest} = Neumu.export_artifact(artifact_a, dest)
    assert File.read!(dest) == File.read!(Path.join(tmp_dir, "stub.wav"))

    # 任务枚举可用于回放历史对比。
    assert {:ok, jobs} = Neumu.list_render_jobs(id)
    assert Enum.map(jobs, & &1.source_pin) == [4, 6]
    assert Enum.map(jobs, & &1.artifact_id) == [artifact_a, artifact_b]
  end

  test "导出的失败形状：未知制品与源文件缺失", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "out.wav")

    assert {:error, {:artifact_not_found, "nope"}} = Neumu.export_artifact("nope", dest)

    # 源文件缺失：登记一个指向不存在路径的制品。
    {:ok, artifact_id} =
      Neumu.ArtifactStore.put(%{
        ProjectStub.mix_artifact()
        | path: Path.join(tmp_dir, "gone.wav")
      })

    assert {:error, {:export_failed, _}} = Neumu.export_artifact(artifact_id, dest)
    refute File.exists?(dest)
  end
end
