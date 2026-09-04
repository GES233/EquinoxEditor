defmodule Neume.RenderJobTest do
  use ExUnit.Case, async: true

  alias Neume.{Event, RenderArtifact, RenderJob}

  test "合法生命周期保留 identity，并在完成态持有制品" do
    artifact = %RenderArtifact{frame_count: 12}

    assert {:ok, queued} = RenderJob.new("job-1", "project-1", 7)
    assert queued.status == :queued
    assert queued.source_pin == 7
    assert queued.artifact == nil
    assert queued.error == nil

    assert {:ok, running} = RenderJob.start(queued)
    assert {:ok, completed} = RenderJob.complete(running, artifact)
    assert completed.status == :completed
    assert completed.artifact == artifact
    assert completed.source_pin == 7
  end

  test "失败态携带原因且不携带制品" do
    assert {:ok, job} = RenderJob.new("job-1", "project-1", 7)
    assert {:ok, job} = RenderJob.start(job)
    assert {:ok, failed} = RenderJob.fail(job, {:engine_failed, :timeout})

    assert failed.status == :failed
    assert failed.error == {:engine_failed, :timeout}
    assert failed.artifact == nil
  end

  test "非法构造返回 tagged error" do
    assert {:error, {:invalid_job_id, nil}} = RenderJob.new(nil, "project-1", 0)
    assert {:error, {:invalid_project_id, nil}} = RenderJob.new("job-1", nil, 0)
    assert {:error, {:invalid_source_pin, -1}} = RenderJob.new("job-1", "project-1", -1)
  end

  test "运行前不能完成或失败" do
    assert {:ok, job} = RenderJob.new("job-1", "project-1", 0)

    assert {:error, {:invalid_render_job_transition, :queued, :completed}} =
             RenderJob.complete(job, %RenderArtifact{frame_count: 1})

    assert {:error, {:invalid_render_job_transition, :queued, :failed}} =
             RenderJob.fail(job, :boom)
  end

  test "完成与失败要求各自的结果" do
    assert {:ok, job} = RenderJob.new("job-1", "project-1", 0)
    assert {:ok, job} = RenderJob.start(job)

    assert {:error, :missing_artifact} = RenderJob.complete(job, nil)

    assert {:error, {:invalid_artifact, :not_an_artifact}} =
             RenderJob.complete(job, :not_an_artifact)

    assert {:error, :missing_failure_reason} = RenderJob.fail(job, nil)
  end

  test "终态不能再次转换" do
    artifact = %RenderArtifact{frame_count: 1}
    assert {:ok, job} = RenderJob.new("job-1", "project-1", 0)
    assert {:ok, job} = RenderJob.start(job)
    assert {:ok, completed} = RenderJob.complete(job, artifact)

    assert {:error, {:invalid_render_job_transition, :completed, :running}} =
             RenderJob.start(completed)

    assert {:error, {:invalid_render_job_transition, :completed, :failed}} =
             RenderJob.fail(completed, :late_error)
  end

  test "事件保持最小 tuple 形状" do
    assert Event.project_changed("project-1", 7) == {:project_changed, "project-1", 7}

    assert {:ok, job} = RenderJob.new("job-1", "project-1", 7)
    assert {:ok, running} = RenderJob.start(job)
    assert Event.render_changed(running) == {:render_changed, "job-1", :running}

    assert {:ok, completed} =
             RenderJob.complete(running, %RenderArtifact{frame_count: 1})

    assert Event.artifact_ready(completed, "artifact-1") ==
             {:artifact_ready, "job-1", "artifact-1", 7}
  end

  test "制品就绪事件只接受已完成任务" do
    assert {:ok, queued} = RenderJob.new("job-1", "project-1", 7)
    assert {:error, {:artifact_not_ready, :queued}} = Event.artifact_ready(queued, "artifact-1")

    assert {:ok, running} = RenderJob.start(queued)
    assert {:ok, completed} = RenderJob.complete(running, %RenderArtifact{frame_count: 1})
    assert {:error, :invalid_artifact_id} = Event.artifact_ready(completed, nil)
  end
end
