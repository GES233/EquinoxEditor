defmodule Equinox.Kernel.Runner do
  @moduledoc """
  Dispatch units 的执行器（`Oi.execute/2` 的薄封装）。

  输入装配沿用旧 Engine 语义：Blackboard 优先、干预兜底、悬空输入给 `:void` Param；
  跨 bundle 的内部键由 Oi 在执行计划内自动流转，不参与装配。

  前置条件：会话基础设施已启动（`Oi.Runtime.Session.ensure_started/2`，
  由 `Equinox.Session.Server` 在 init 时完成），否则 TaskSup 执行器找不到监督进程。
  """

  alias Equinox.Kernel.{Blackboard, Compiler, Configurator, Graph}
  alias Equinox.Kernel.Graph.PortRef

  @typedoc "单个 Segment 的执行单元（即 Compiler 的编译产物）。"
  @type unit :: Compiler.compiled_segment()

  @typedoc "一次渲染 dispatch：会话标识 + 全部 Segment 的执行单元。"
  @type dispatch :: %{session_id: atom() | String.t(), units: [unit()]}

  @doc """
  执行全部 Segment 的 dispatch units，把结果合并进 Blackboard。

  跨 Segment 以 `Task.async_stream` 扇出（首个错误中断）；单个 Segment 内部的
  stage 编排与并发由 `Oi.execute/2` 负责。Segment 之间无参数共享
  （Blackboard 按 `{segment_id, io_key}` 寻址且仅同段读取），合并顺序无关语义。
  """
  @spec run(dispatch(), Blackboard.t(), keyword() | Configurator.t()) ::
          {:ok, Blackboard.t()} | {:error, term()}
  def run(dispatch, board, opts_or_conf \\ [])

  def run(dispatch, %Blackboard{} = board, opts) when is_list(opts),
    do: run(dispatch, board, Configurator.new(opts))

  def run(%{session_id: session_id, units: units}, %Blackboard{} = board, %Configurator{} = conf) do
    units
    |> Task.async_stream(
      fn unit -> run_unit(session_id, unit, board, conf) end,
      max_concurrency: conf.concurrency,
      timeout: conf.timeout,
      ordered: false
    )
    |> Enum.reduce_while({:ok, board}, fn
      {:ok, {:ok, entries}}, {:ok, acc_board} ->
        {:cont, {:ok, Blackboard.put(acc_board, entries)}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:worker_crashed, reason}}}
    end)
  end

  defp run_unit(session_id, {segment_id, graph, interventions, compiled}, board, conf) do
    data = assemble_data(segment_id, graph, interventions, board)

    execute_opts = [
      data: data,
      executor: Oi.Executor.TaskSup,
      executor_opts: [sup: Oi.Runtime.Session.tasks_tuple(session_id)],
      orchid_adapters:
        [&Oi.Adapters.orchid_intervention/1, &Oi.Adapters.orchid_symbiont/1] ++
          Configurator.as_orchid_adapters(conf),
      orchid_baggage: conf.orchid_baggage,
      orchid_opts: conf.orchid_opts,
      concurrency: conf.concurrency,
      timeout: conf.timeout,
      name: session_id
    ]

    case Oi.execute(compiled, execute_opts) do
      {:ok, %Oi.Result{memory: memory}} -> {:ok, to_board_entries(segment_id, memory)}
      {:error, reason} -> {:error, reason}
    end
  end

  # 输入装配（沿用旧 Engine 语义）：
  # - 悬空输入端口（无入边）：Blackboard 命中 → memory；干预命中 → memory；
  #   都没有 → `:void` Param 兜底（避免 Oi 的 missing_input fail-fast 改变行为）；
  # - 有入边的消费端口：producer PortRef 键的干预 → `{:override, value}` data 干预；
  # - 规格形状无法识别的干预一律忽略（当前编译路径干预恒 %{}，该路径暂不可达）。
  defp assemble_data(segment_id, graph, interventions, board) do
    segment_id
    |> dangling_data(graph, interventions, board)
    |> Map.merge(producer_intervention_data(graph, interventions))
  end

  defp dangling_data(segment_id, graph, interventions, %Blackboard{memory: mem}) do
    for %Graph.Node{} = node <- Map.values(graph.nodes),
        port <- node.inputs,
        not has_in_edge?(graph, node.id, port),
        into: %{} do
      key = PortRef.to_orchid_key({:port, node.id, port})

      value =
        case Map.fetch(mem, {segment_id, key}) do
          {:ok, val} ->
            val

          :error ->
            case Map.get(interventions, {:port, node.id, port}) do
              %{input: %Orchid.Param{} = param} -> param
              %{input: raw} when not is_nil(raw) -> raw
              _ -> Orchid.Param.new(key, :void, nil)
            end
        end

      {{node.id, port}, value}
    end
  end

  defp producer_intervention_data(graph, interventions) do
    interventions
    |> Enum.flat_map(fn
      {{:port, from_node, from_port}, %{input: input}} when not is_nil(input) ->
        graph
        |> Graph.get_out_edges(from_node)
        |> Enum.filter(&(&1.from_port == from_port))
        |> Enum.map(fn edge ->
          value =
            case input do
              %Orchid.Param{} = param -> {:override, param}
              raw -> {:override, raw}
            end

          {{edge.to_node, edge.to_port}, value}
        end)

      _other ->
        []
    end)
    |> Map.new()
  end

  defp has_in_edge?(graph, node_id, port) do
    graph
    |> Graph.get_in_edges(node_id)
    |> Enum.any?(&(&1.to_port == port))
  end

  # Oi.Result.memory 包含本次喂入的 memory 输入；一并合并回黑板是无害的
  # （同键同值幂等），nil 载荷（如 :void 兜底）按旧 merge_results 语义剔除。
  defp to_board_entries(segment_id, memory) do
    memory
    |> Map.new(fn {io_key, param} ->
      {{segment_id, io_key}, Orchid.Param.get_payload(param)}
    end)
    |> Map.reject(fn {_addr, payload} -> is_nil(payload) end)
  end
end
