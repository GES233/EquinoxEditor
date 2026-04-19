defmodule Equinox.Kernel.Planner do
  @moduledoc """
  将编译后的 Segment bundle 对齐为栅栏同步的执行管线。
  """

  alias Equinox.Kernel.Compiler
  alias Equinox.Editor.Segment
  alias Equinox.Kernel.RecipeBundle

  defmodule Stage do
    @moduledoc "计划中的单个执行栅栏。"

    @type task_def :: {Segment.id(), RecipeBundle.t()}

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            tasks: [task_def()]
          }

    defstruct [:index, tasks: []]
  end

  defmodule Plan do
    @moduledoc "构成完整执行策略的有序阶段序列。"

    @type t :: %__MODULE__{
            stages: [Stage.t()],
            total_tasks: non_neg_integer()
          }

    defstruct [:stages, total_tasks: 0]

    @spec new([Stage.t()]) :: t()
    def new(stages) do
      total_tasks = Enum.reduce(stages, 0, &(&2 + length(&1.tasks)))
      %__MODULE__{stages: stages, total_tasks: total_tasks}
    end
  end

  @spec build([Segment.t()] | [{Segment.id(), [RecipeBundle.t()]}]) ::
          {:error, any()} | {:ok, Plan.t()}
  def build(segments_or_compiled_pairs)

  def build([%Segment{} | _] = segments) do
    with {:ok, compiled_pairs} <- Compiler.compile_to_recipes(segments) do
      stages = align_stages(compiled_pairs)
      {:ok, Plan.new(stages)}
    end
  end

  def build(compiled_pairs) do
    stages = align_stages(compiled_pairs)
    {:ok, Plan.new(stages)}
  end

  defp align_stages(compiled_pairs) do
    compiled_pairs
    |> Enum.flat_map(fn {segment_id, bundles} ->
      bundles
      |> Enum.with_index()
      |> Enum.map(fn {bundle, stage_idx} -> {stage_idx, {segment_id, bundle}} end)
    end)
    |> Enum.group_by(fn {idx, _task} -> idx end, fn {_idx, task} -> task end)
    |> Enum.sort_by(fn {idx, _tasks} -> idx end)
    |> Enum.map(fn {index, tasks} -> %Stage{index: index, tasks: tasks} end)
  end
end
