defmodule Neumu.AuditionTest do
  @moduledoc """
  试听支撑的 facade 矩阵：声库列表查询、非渲染 check（冲突一等位置）、
  按 pin 渲染与渲染任务枚举（`source_pin`/`artifact_id`）。
  probe/check 走 `Neumu.ProjectStub.PhonemesClient`。
  """

  use ExUnit.Case, async: false

  @moduletag tmp_dir: true

  alias Neumu.ProjectStub
  alias Neumu.ProjectStub.PhonemesClient

  # 默认工程：一条 fixture 声库的 "lead" 人声轨 + 一个双音素音符
  # （pin 0 = 空工程，pin 1 = 加轨，pin 2 = 插音符）。
  setup %{tmp_dir: tmp_dir} do
    {registry, stock} = ProjectStub.stock_registry(tmp_dir)
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Neumu.create_project(project_id, ProjectStub.open_opts(registry, tmp_dir, PhonemesClient))

    {:ok, 1} = Neumu.add_track(project_id, "lead", stock.id)

    {:ok, 2} =
      Neumu.insert_note(project_id, "lead", "n1", :head, {0, 480}, %{
        pitch: 60,
        lyric: "la",
        phonemes: [["zh", "l"], ["zh", "a"]]
      })

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id, stock: stock}
  end

  # 递归断言投影只含 plain data：无 PID/函数/引用/端口，无遗留 struct。
  defp assert_plain_data(term) do
    refute is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
           "泄露运行时对象：#{inspect(term)}"

    cond do
      is_struct(term) -> flunk("泄露 struct：#{inspect(term)}")
      is_map(term) -> Enum.each(term, fn {k, v} -> assert_plain_data({k, v}) end)
      is_tuple(term) -> term |> Tuple.to_list() |> Enum.each(&assert_plain_data/1)
      is_list(term) -> Enum.each(term, &assert_plain_data/1)
      true -> :ok
    end
  end

  test "list_voicebanks 返回 plain-data 条目，只读无副作用", %{project_id: id, stock: stock} do
    :ok = Neumu.subscribe(id)

    assert {:ok, [entry]} = Neumu.list_voicebanks(id)

    stock_id = stock.id

    assert %{
             id: ^stock_id,
             name: _name,
             mode: :stock,
             engine: :diffsinger_stock,
             digest: digest
           } = entry

    assert is_binary(digest) and byte_size(digest) == 64
    assert_plain_data(entry)

    assert {:ok, 2} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "check 通过时返回 :ok，只读无副作用", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, %{pin: 2, status: :ok, entries: []}} = Neumu.check(id)
    assert {:ok, 2} = Neumu.history_pin(id)
    refute_received {:project_changed, _, _}
  end

  test "check 失败时返回 plain-data 冲突条目（patch 只留引用）", %{project_id: id} do
    assert {:ok, probe} = Neumu.probe_pin(id, "lead", "n1")
    assert {:ok, 3} = Neumu.mount_phoneme_duration(id, "lead", "n1", [[0, 96]], probe)

    # 改显式音素 → 输入底料变化 → pin 冲突。
    assert {:ok, 4} = Neumu.edit_note(id, "lead", "n1", %{phonemes: [["zh", "l"], ["zh", "u"]]})

    assert {:ok, %{pin: 4, status: :failed, entries: [entry]}} = Neumu.check(id)

    assert %{
             kind: :conflict,
             stage: :probe,
             track_id: "lead",
             channel: :duration,
             reason: :base_changed,
             patch_id: patch_id,
             note_id: "n1"
           } = entry

    assert is_binary(patch_id)
    assert_plain_data(entry)

    # 冲突可 repatch 兜住，之后 check 恢复 :ok。
    assert {:ok, 5, [%{status: :repatched}]} = Neumu.repatch(id, "lead", [patch_id])
    assert {:ok, %{pin: 5, status: :ok, entries: []}} = Neumu.check(id)
  end

  test "按 pin 渲染：渲染历史状态，source_pin 钉住目标 pin", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    # pin 3：改词。历史 pin 2 仍是 "la"。
    assert {:ok, 3} = Neumu.edit_note(id, "lead", "n1", %{lyric: "lu"})
    assert_received {:project_changed, ^id, 3}

    test_pid = self()

    spy = fn multi_track ->
      lyric = multi_track.session.history.present.tracks["lead"].elements_by_id["n1"].lyric
      send(test_pid, {:rendered_lyric, lyric})
      {:ok, ProjectStub.mix_artifact()}
    end

    # 渲染 pin 2 的历史状态。
    assert {:ok, job} = Neumu.submit_render(id, pin: 2, renderer: spy)
    assert job.source_pin == 2
    assert_receive {:render_changed, _, :running}
    assert_receive {:render_changed, job_id, :completed}
    assert_receive {:artifact_ready, ^job_id, _artifact_id, 2}

    # 渲染当前（pin 3）。
    assert {:ok, job2} = Neumu.submit_render(id, renderer: spy)
    assert job2.source_pin == 3
    assert_receive {:artifact_ready, job_id2, _artifact_id2, 3}
    assert job_id2 == job2.id

    # spy 在任务进程里自报：两份渲染分别看到 "la" 与 "lu"。
    assert_received {:rendered_lyric, "la"}
    assert_received {:rendered_lyric, "lu"}

    # 按 pin 渲染不碰当前工程状态。
    assert {:ok, 3} = Neumu.history_pin(id)
    assert {:ok, snapshot} = Neumu.snapshot(id)
    assert [%{lyric: "lu"}] = snapshot.tracks |> hd() |> Map.fetch!(:notes)

    # 被 squash/不存在的 pin 与非法 pin：tagged error，不产生任务。
    assert {:error, {:unknown_node, 999}} = Neumu.submit_render(id, pin: 999, renderer: spy)
    assert {:error, {:invalid_source_pin, :bogus}} = Neumu.submit_render(id, pin: :bogus)

    assert {:ok, jobs} = Neumu.list_render_jobs(id)
    assert length(jobs) == 2
  end

  test "list_render_jobs 枚举 source_pin 与 artifact_id，失败任务带净化后的 error", %{
    project_id: id
  } do
    :ok = Neumu.subscribe(id)

    ok_renderer = fn _multi_track -> {:ok, ProjectStub.mix_artifact()} end

    fail_renderer = fn _multi_track ->
      {:error, {:check_failed, [%{kind: :static, reason: :boom}]}}
    end

    assert {:ok, job1} = Neumu.submit_render(id, renderer: ok_renderer)
    assert_receive {:artifact_ready, _, _, _}

    assert {:ok, job2} = Neumu.submit_render(id, renderer: fail_renderer)
    assert_receive {:render_changed, _, :failed}

    assert {:ok, jobs} = Neumu.list_render_jobs(id)

    assert [
             %{
               job_id: _,
               source_pin: 2,
               status: :completed,
               artifact_id: artifact_id,
               error: nil
             },
             %{
               job_id: _,
               source_pin: 2,
               status: :failed,
               artifact_id: nil,
               error: {:check_failed, [%{kind: :static, reason: :boom}]}
             }
           ] = jobs

    assert is_binary(artifact_id)
    assert job1.id == Enum.at(jobs, 0).job_id
    assert job2.id == Enum.at(jobs, 1).job_id
    assert_plain_data(jobs)
  end

  test "新查询入口对未知工程返回 tagged error" do
    assert {:error, {:unknown_project, :nope}} = Neumu.list_voicebanks(:nope)
    assert {:error, {:unknown_project, :nope}} = Neumu.check(:nope)
    assert {:error, {:unknown_project, :nope}} = Neumu.list_render_jobs(:nope)

    assert {:error, {:unknown_project, :nope}} = Neumu.submit_render(:nope, pin: 2)
  end
end
