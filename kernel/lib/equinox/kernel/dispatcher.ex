defmodule Equinox.Kernel.Dispatcher do
  @moduledoc """
  编排栅栏同步的阶段执行。
  职责：按阶段扇出任务、收集结果、在下一阶段前执行栅栏同步。
  """

  alias Equinox.Kernel.{Planner, Engine, Blackboard, Configurator}

  @spec dispatch(Planner.Plan.t(), Blackboard.t(), keyword() | Configurator.t()) ::
          {:ok, Blackboard.t()} | {:error, term()}
  def dispatch(plan, board, opts_or_conf \\ [])

  def dispatch(%Planner.Plan{} = plan, %Blackboard{} = board, opts) when is_list(opts),
    do: dispatch(plan, board, Configurator.new(opts))

  def dispatch(plan, board, %Configurator{} = conf) do
    Enum.reduce_while(plan.stages, {:ok, board}, fn stage, {:ok, current_board} ->
      case run_stage(stage, current_board, conf) do
        {:ok, updated_board} -> {:cont, {:ok, updated_board}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_stage(stage, blackboard, %Configurator{} = conf) do
    stage.tasks
    |> Task.async_stream(
      fn {segment_id, bundle} -> Engine.run(segment_id, bundle, blackboard, conf) end,
      max_concurrency: conf.concurrency,
      timeout: conf.timeout,
      ordered: false
    )
    |> Enum.reduce_while({:ok, blackboard}, fn
      {:ok, {:ok, segment_id, outputs}}, {:ok, acc_board} ->
        {:cont, {:ok, merge_results(acc_board, segment_id, outputs)}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:worker_crashed, reason}}}
    end)
  end

  defp merge_results(%Blackboard{} = board, segment_id, outputs) do
    entries =
      outputs
      |> Enum.map(fn
        %Orchid.Param{} = p -> {{segment_id, p.name}, Orchid.Param.get_payload(p)}
        {port_name, p} -> {{segment_id, port_name}, Orchid.Param.get_payload(p)}
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Blackboard.put(board, entries)
  end
end
