defmodule Neumu.ProjectServerTest do
  use ExUnit.Case, async: false

  alias Neumu.ProjectStub

  setup do
    project_id = "project-#{System.unique_integer([:positive])}"

    {:ok, _pid} = Neumu.open_project(project_id, ProjectStub.multi_track(project_id))

    on_exit(fn ->
      if Neumu.ProjectServer.whereis(project_id), do: Neumu.close_project(project_id)
    end)

    %{project_id: project_id}
  end

  # 阻塞式 renderer：报告自身 pid 并等待测试进程放行。
  defp blocking_renderer(test_pid) do
    fn _multi_track ->
      send(test_pid, {:render_started, self()})

      receive do
        :release_render -> {:ok, ProjectStub.mix_artifact()}
      end
    end
  end

  test "工程打开后按 project_id 定位，关闭后查询返回 tagged error", %{project_id: id} do
    assert {:ok, 0} = Neumu.history_pin(id)

    assert {:error, {:project_already_open, ^id}} =
             Neumu.open_project(id, ProjectStub.multi_track(id))

    assert :ok = Neumu.close_project(id)
    refute Neumu.ProjectServer.whereis(id)
    assert {:error, {:unknown_project, ^id}} = Neumu.history_pin(id)
    assert {:error, {:unknown_project, ^id}} = Neumu.render_job(id, 1)
    assert {:error, {:unknown_project, ^id}} = Neumu.submit_render(id)
    assert {:error, {:unknown_project, ^id}} = Neumu.close_project(id)

    assert {:ok, _pid} = Neumu.open_project(id, ProjectStub.multi_track(id))
  end

  test "渲染成功：job 完成、制品按 id 可取、source_pin 保留、事件按序到达", %{
    project_id: id
  } do
    :ok = Neumu.subscribe(id)
    assert {:ok, pin} = Neumu.history_pin(id)
    artifact = ProjectStub.mix_artifact()

    assert {:ok, job} = Neumu.submit_render(id, renderer: fn _mt -> {:ok, artifact} end)
    assert job.status == :running
    assert job.project_id == id
    assert job.source_pin == pin

    assert_receive {:render_changed, job_id, :running}
    assert job_id == job.id
    assert_receive {:render_changed, ^job_id, :completed}
    assert_receive {:artifact_ready, ^job_id, artifact_id, ^pin}

    assert {:ok, done} = Neumu.render_job(id, job_id)
    assert done.status == :completed
    assert done.artifact == artifact
    assert done.error == nil
    assert done.source_pin == pin

    assert {:ok, ^artifact} = Neumu.artifact(artifact_id)
  end

  test "渲染失败：原因保存在 job，不派发 artifact_ready", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    reason = {:engine_failed, :timeout}

    assert {:ok, job} = Neumu.submit_render(id, renderer: fn _mt -> {:error, reason} end)

    assert_receive {:render_changed, job_id, :running}
    assert job_id == job.id
    assert_receive {:render_changed, ^job_id, :failed}
    refute_received {:artifact_ready, _, _, _}

    assert {:ok, failed} = Neumu.render_job(id, job_id)
    assert failed.status == :failed
    assert failed.error == reason
    assert failed.artifact == nil
  end

  test "渲染期间 ProjectServer 仍可响应查询", %{project_id: id} do
    assert {:ok, job} = Neumu.submit_render(id, renderer: blocking_renderer(self()))
    assert_receive {:render_started, render_pid}

    # 渲染任务仍阻塞时，查询立即返回权威状态。
    assert {:ok, running} = Neumu.render_job(id, job.id)
    assert running.status == :running
    assert {:ok, pin} = Neumu.history_pin(id)
    assert pin == job.source_pin

    send(render_pid, :release_render)
    assert {:ok, done} = await_status(id, job.id, :completed)
    assert done.source_pin == pin
  end

  test "渲染任务崩溃被记为失败且不拖垮 ProjectServer", %{project_id: id} do
    :ok = Neumu.subscribe(id)

    assert {:ok, job} = Neumu.submit_render(id, renderer: fn _mt -> raise "boom" end)

    assert_receive {:render_changed, job_id, :running}
    assert job_id == job.id
    assert_receive {:render_changed, ^job_id, :failed}

    assert {:ok, failed} = Neumu.render_job(id, job_id)
    assert {:render_crashed, _crash} = failed.error

    assert {:ok, _pin} = Neumu.history_pin(id)
  end

  test "提交渲染的参数校验走 tagged error", %{project_id: id} do
    assert {:error, {:invalid_job_id, nil}} = Neumu.submit_render(id, job_id: nil)
  end

  test "open_project 拒绝 nil project_id" do
    assert {:error, {:invalid_project_id, nil}} =
             Neumu.open_project(nil, ProjectStub.multi_track("nil-project"))
  end

  test "查询未知 job 返回带 id 的 tagged error", %{project_id: id} do
    assert {:error, {:job_not_found, :no_such_job}} = Neumu.render_job(id, :no_such_job)
  end

  test "重复 job_id 不得覆盖在途 job", %{project_id: id} do
    assert {:ok, job} =
             Neumu.submit_render(id, job_id: :dup_running, renderer: blocking_renderer(self()))

    assert_receive {:render_started, render_pid}

    assert {:error, {:job_already_exists, :dup_running}} =
             Neumu.submit_render(id,
               job_id: :dup_running,
               renderer: fn _mt ->
                 {:ok, ProjectStub.mix_artifact()}
               end
             )

    # 原 job 仍是权威的 running 状态。
    assert {:ok, ^job} = Neumu.render_job(id, :dup_running)

    send(render_pid, :release_render)
    assert {:ok, %{status: :completed}} = await_status(id, job.id, :completed)
  end

  test "重复 job_id 不得覆盖终态 job", %{project_id: id} do
    assert {:ok, job} =
             Neumu.submit_render(id,
               job_id: :dup_done,
               renderer: fn _mt -> {:ok, ProjectStub.mix_artifact()} end
             )

    assert {:ok, %{status: :completed}} = await_status(id, job.id, :completed)

    assert {:error, {:job_already_exists, :dup_done}} =
             Neumu.submit_render(id,
               job_id: :dup_done,
               renderer: fn _mt ->
                 {:ok, ProjectStub.mix_artifact()}
               end
             )

    assert {:ok, %{status: :completed}} = Neumu.render_job(id, :dup_done)
  end

  test "重复订阅幂等：每个事件只投递一次", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    :ok = Neumu.subscribe(id)
    :ok = Neumu.subscribe(id)

    assert {:ok, job} =
             Neumu.submit_render(id, renderer: fn _mt -> {:ok, ProjectStub.mix_artifact()} end)

    events = collect_events()

    assert Enum.filter(events, &match?({:render_changed, _, _}, &1)) == [
             {:render_changed, job.id, :running},
             {:render_changed, job.id, :completed}
           ]

    assert Enum.count(events, &match?({:artifact_ready, _, _, _}, &1)) == 1
  end

  test "关闭工程时在途 renderer 被终止", %{project_id: id} do
    assert {:ok, _job} = Neumu.submit_render(id, renderer: blocking_renderer(self()))
    assert_receive {:render_started, render_pid}
    ref = Process.monitor(render_pid)

    assert :ok = Neumu.close_project(id)

    assert_receive {:DOWN, ^ref, :process, ^render_pid, _reason}
    refute Process.alive?(render_pid)
    refute Neumu.ProjectServer.whereis(id)
  end

  # 收集一段窗口内的工程事件，用于断言重复订阅不产生重复投递。
  defp collect_events(acc \\ []) do
    receive do
      {:render_changed, _, _} = event -> collect_events([event | acc])
      {:artifact_ready, _, _, _} = event -> collect_events([event | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  test "退订后不再收到工程事件", %{project_id: id} do
    :ok = Neumu.subscribe(id)
    :ok = Neumu.unsubscribe(id)

    assert {:ok, _job} =
             Neumu.submit_render(id, renderer: fn _mt -> {:ok, ProjectStub.mix_artifact()} end)

    refute_received {:render_changed, _, _}
  end

  # 有界轮询权威 job 状态直到进入目标状态；超时让测试失败并展示最后一次
  # 查询结果。
  defp await_status(project_id, job_id, status, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_status(project_id, job_id, status, deadline)
  end

  defp do_await_status(project_id, job_id, status, deadline) do
    last = Neumu.render_job(project_id, job_id)

    case last do
      {:ok, %{status: ^status}} = ok ->
        ok

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_await_status(project_id, job_id, status, deadline)
        else
          flunk(
            "等待 job #{inspect(job_id)} 进入 #{inspect(status)} 超时，" <>
              "最后一次查询结果：#{inspect(last)}"
          )
        end
    end
  end
end
