defmodule Neume.Event do
  @moduledoc """
  Neume 向 application service 暴露的最小领域事件。

  状态类事件（`project_changed`/`render_changed`/`artifact_ready`）只携带
  用于重新查询权威状态的 identity，不携带工程快照、制品内容、
  Orchid report 或 UI 展示数据。唯一的例外是 `render_progress`：
  进度不是权威状态（丢失不影响一致性，UI 可随时重查 job 状态），
  其 payload 由生产者自由定义，仅要求 plain data。
  """

  alias Coconut.Edit.History
  alias Neume.RenderJob

  @type artifact_id :: term()

  @type t ::
          {:project_changed, RenderJob.project_id(), History.node_id()}
          | {:render_changed, RenderJob.id(), RenderJob.status()}
          | {:artifact_ready, RenderJob.id(), artifact_id(), History.node_id()}
          | {:render_progress, RenderJob.id(), term()}

  @doc "工程 History cursor 发生变化。"
  @spec project_changed(RenderJob.project_id(), History.node_id()) :: t()
  def project_changed(project_id, history_pin),
    do: {:project_changed, project_id, history_pin}

  @doc "渲染任务状态发生变化。"
  @spec render_changed(RenderJob.t()) :: t()
  def render_changed(%RenderJob{id: id, status: status}),
    do: {:render_changed, id, status}

  @doc "已完成任务的制品可供消费；版本钉取自任务创建时的输入。"
  @spec artifact_ready(RenderJob.t(), artifact_id()) :: t() | {:error, term()}
  def artifact_ready(
        %RenderJob{status: :completed, id: job_id, source_pin: source_pin},
        artifact_id
      )
      when not is_nil(artifact_id) do
    {:artifact_ready, job_id, artifact_id, source_pin}
  end

  def artifact_ready(%RenderJob{status: status}, _artifact_id) when status != :completed,
    do: {:error, {:artifact_not_ready, status}}

  def artifact_ready(%RenderJob{}, nil), do: {:error, :invalid_artifact_id}

  @doc """
  渲染进度报告。payload 形状由生产者自由定义（必须是 plain data），
  本契约只固定信封；当前生产者见 `Neume.RenderGraph`（轨级
  started/finished/failed）与实现 `render_checked/6` 的 runtime
  （乐句粒度）。
  """
  @spec render_progress(RenderJob.id(), term()) :: t()
  def render_progress(job_id, payload), do: {:render_progress, job_id, payload}
end
