defmodule Neume.RenderJob do
  @moduledoc """
  一次渲染的纯值状态机。

  Job 钉住提交时的 Coconut History node id；后续工程继续编辑不会改变
  `source_pin`。调度、进程和 Oi execution handle 由上层运行时持有，不进入
  这个领域值。
  """

  alias Coconut.Edit.History

  @enforce_keys [:id, :project_id, :source_pin]
  defstruct [:id, :project_id, :source_pin, :artifact, :error, status: :queued]

  @type id :: term()
  @type project_id :: term()
  @type status :: :queued | :running | :completed | :failed
  @type artifact :: Neume.RenderArtifact.t() | Neume.MixArtifact.t()

  @type t :: %__MODULE__{
          id: id(),
          project_id: project_id(),
          source_pin: History.node_id(),
          status: status(),
          artifact: artifact() | nil,
          error: term() | nil
        }

  @doc "创建钉住工程版本的排队中渲染任务。"
  @spec new(id(), project_id(), History.node_id()) :: {:ok, t()} | {:error, term()}
  def new(id, project_id, source_pin) do
    cond do
      is_nil(id) ->
        {:error, {:invalid_job_id, id}}

      is_nil(project_id) ->
        {:error, {:invalid_project_id, project_id}}

      not (is_integer(source_pin) and source_pin >= 0) ->
        {:error, {:invalid_source_pin, source_pin}}

      true ->
        {:ok, %__MODULE__{id: id, project_id: project_id, source_pin: source_pin}}
    end
  end

  @doc "把排队中的任务标记为运行中。"
  @spec start(t()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{status: :queued} = job), do: {:ok, %{job | status: :running}}
  def start(%__MODULE__{} = job), do: invalid_transition(job, :running)

  @doc "用渲染制品完成运行中的任务。"
  @spec complete(t(), artifact()) :: {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{status: :running} = job, %Neume.RenderArtifact{} = artifact) do
    {:ok, %{job | status: :completed, artifact: artifact, error: nil}}
  end

  def complete(%__MODULE__{status: :running} = job, %Neume.MixArtifact{} = artifact) do
    {:ok, %{job | status: :completed, artifact: artifact, error: nil}}
  end

  def complete(%__MODULE__{status: :running}, nil), do: {:error, :missing_artifact}

  def complete(%__MODULE__{status: :running}, artifact),
    do: {:error, {:invalid_artifact, artifact}}

  def complete(%__MODULE__{} = job, _artifact), do: invalid_transition(job, :completed)

  @doc "用失败原因终止运行中的任务。"
  @spec fail(t(), term()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{status: :running} = job, reason) when not is_nil(reason) do
    {:ok, %{job | status: :failed, artifact: nil, error: reason}}
  end

  def fail(%__MODULE__{status: :running}, nil), do: {:error, :missing_failure_reason}
  def fail(%__MODULE__{} = job, _reason), do: invalid_transition(job, :failed)

  defp invalid_transition(job, target) do
    {:error, {:invalid_render_job_transition, job.status, target}}
  end
end
