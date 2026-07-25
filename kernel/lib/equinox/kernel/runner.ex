defmodule Equinox.Kernel.Runner do
  @moduledoc """
  Dispatch units 的执行器（`Oi.execute/2` 的薄封装），两段式：先 check 后 render。

  check 阶段对全部 unit 的存活干预（`RenderRequest.interventions`）按 channel
  分组，经 Configurator 注入的 channel spec 求投影并
  `Zongzi.Intervention.Declaration.resolve_within/2` 批量 resolve；冲突 / 未知
  通道 / 投影失败全量聚合为 `{:error, {:check_failed, [entry]}}`，且一个窗口
  都不执行。全部通过才把 resolved artifact 折叠为
  `%{PortRef => %{input: value}}` 干预规格，进入 render 阶段。

  输入装配沿用旧 Engine 语义：Blackboard 优先、干预兜底、悬空输入给 `:void` Param；
  跨 bundle 的内部键由 Oi 在执行计划内自动流转，不参与装配。

  前置条件：会话基础设施已启动（`Oi.Runtime.Session.ensure_started/2`，
  由 `Equinox.Session.Server` 在 init 时完成），否则 TaskSup 执行器找不到监督进程。
  """

  alias Equinox.Kernel.{Blackboard, Compiler, Configurator, Graph}
  alias Equinox.Kernel.Graph.PortRef
  alias Zongzi.Intervention.Declaration

  @typedoc "单个窗口的执行单元（即 Compiler 的编译产物）：第三元素是窗口 RenderRequest，check 通过后派生 `Compiler.interventions_map()` 喂输入装配。"
  @type unit :: Compiler.compiled_unit()

  @typedoc "一次渲染 dispatch：会话标识 + 全部窗口的执行单元。"
  @type dispatch :: %{session_id: atom() | String.t(), units: [unit()]}

  @typedoc "check 失败条目；`:conflict` 另带 `:intervention_id` 字段。"
  @type check_entry :: %{
          optional(:intervention_id) => term(),
          unit_id: Compiler.unit_id(),
          channel: atom(),
          kind: :conflict | :unknown_channel | :projection_failed,
          reason: term()
        }

  @doc """
  执行全部窗口的 dispatch units，把结果合并进 Blackboard。

  先跑 check（全部 unit 的干预 resolve，见模块文档）：任一失败全量聚合
  为 `{:error, {:check_failed, [entry]}}` 且一个窗口都不执行；空干预快路径
  零成本。check 通过后跨窗口以 `Task.async_stream` 扇出（首个错误中断）；
  单个窗口内部的 stage 编排与并发由 `Oi.execute/2` 负责。窗口之间无参数共享
  （Blackboard 按 `{unit_id, io_key}` 寻址且仅同单元读取，unit id 为
  `{track_id, window_start_tick}`），合并顺序无关语义。
  """
  @spec run(dispatch(), Blackboard.t(), keyword() | Configurator.t()) ::
          {:ok, Blackboard.t()}
          | {:error, {:check_failed, [check_entry()]}}
          | {:error, term()}
  def run(dispatch, board, opts_or_conf \\ [])

  def run(dispatch, %Blackboard{} = board, opts) when is_list(opts),
    do: run(dispatch, board, Configurator.new(opts))

  def run(%{session_id: session_id, units: units}, %Blackboard{} = board, %Configurator{} = conf) do
    with {:ok, runnable} <- resolve_units(units, conf.channels) do
      runnable
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
  end

  # ---- check 阶段：干预 resolve（先于任何执行） ----

  # 逐 unit 把存活干预按 channel 分组 resolve；错误条目全量聚合（不放过任何一个
  # unit），全部通过才换形为 {unit_id, graph, interventions_map, compiled}。
  # 空干预快路径零成本：group_by 得空 map，reduce 直接返回 {[], %{}}。
  @spec resolve_units([unit()], %{atom() => Configurator.channel_spec()}) ::
          {:ok, [{Compiler.unit_id(), Graph.t(), Compiler.interventions_map(), Oi.Compiled.t()}]}
          | {:error, {:check_failed, [check_entry()]}}
  defp resolve_units(units, channels) do
    {runnable, entries} =
      Enum.map_reduce(units, [], fn {unit_id, graph, request, compiled}, entries_acc ->
        {unit_entries, interventions_map} = resolve_unit(unit_id, request, channels)
        {{unit_id, graph, interventions_map, compiled}, entries_acc ++ unit_entries}
      end)

    case entries do
      [] -> {:ok, runnable}
      _ -> {:error, {:check_failed, entries}}
    end
  end

  defp resolve_unit(unit_id, request, channels) do
    request.interventions
    |> Enum.group_by(& &1.channel)
    |> Enum.reduce({[], %{}}, fn {channel, interventions}, {entries_acc, data_acc} ->
      {entries, data} = resolve_channel(unit_id, channel, interventions, request, channels)
      {entries_acc ++ entries, Map.merge(data_acc, data)}
    end)
  end

  # 单 channel：无 spec → :unknown_channel；projection 失败 → :projection_failed；
  # resolve 冲突 → :conflict（带 intervention_id）；全部 ok 则折叠为干预规格
  defp resolve_channel(unit_id, channel, interventions, request, channels) do
    with {:ok, spec} <- fetch_channel_spec(channels, channel, unit_id),
         {:ok, projection} <- run_projection(spec, request, channel, unit_id) do
      case Declaration.resolve_within(interventions, projection) do
        %{ok: resolved, conflicts: []} ->
          {[], fold_resolved(resolved, spec.target)}

        %{conflicts: conflicts} ->
          entries =
            Enum.map(conflicts, fn {intervention, reason} ->
              %{
                unit_id: unit_id,
                channel: channel,
                kind: :conflict,
                reason: reason,
                intervention_id: intervention.id
              }
            end)

          {entries, %{}}
      end
    else
      {:error, entry} -> {[entry], %{}}
    end
  end

  defp fetch_channel_spec(channels, channel, unit_id) do
    case Map.fetch(channels, channel) do
      {:ok, spec} ->
        {:ok, spec}

      :error ->
        {:error,
         %{unit_id: unit_id, channel: channel, kind: :unknown_channel, reason: :no_channel_spec}}
    end
  end

  defp run_projection(spec, request, channel, unit_id) do
    case spec.projection.(request) do
      {:ok, projection} ->
        {:ok, projection}

      {:error, reason} ->
        {:error, %{unit_id: unit_id, channel: channel, kind: :projection_failed, reason: reason}}
    end
  end

  # resolved artifact 经 channel spec 的 target 绑定端口，折叠为 assemble_data
  # 识别的 %{PortRef => %{input: value}} 形状：PortRef 直取，或一元函数 fan-out
  defp fold_resolved(resolved, target) do
    Enum.reduce(resolved, %{}, fn {_intervention, artifact}, acc ->
      target
      |> bind_artifact(artifact)
      |> Enum.reduce(acc, fn {port_ref, value}, inner ->
        Map.put(inner, port_ref, %{input: value})
      end)
    end)
  end

  defp bind_artifact(target, artifact) when is_function(target, 1), do: target.(artifact)

  defp bind_artifact({:port, _node, _port} = port_ref, artifact), do: [{port_ref, artifact}]

  defp run_unit(session_id, {unit_id, graph, interventions, compiled}, board, conf) do
    data = assemble_data(unit_id, graph, interventions, board)

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
      {:ok, %Oi.Result{memory: memory}} -> {:ok, to_board_entries(unit_id, memory)}
      {:error, reason} -> {:error, reason}
    end
  end

  # 输入装配（沿用旧 Engine 语义）：
  # - 悬空输入端口（无入边）：Blackboard 命中 → memory；干预命中 → memory；
  #   都没有 → `:void` Param 兜底（避免 Oi 的 missing_input fail-fast 改变行为）；
  # - 有入边的消费端口：producer PortRef 键的干预 → `{:override, value}` data 干预；
  # - 规格形状无法识别的干预一律忽略。
  defp assemble_data(unit_id, graph, interventions, board) do
    unit_id
    |> dangling_data(graph, interventions, board)
    |> Map.merge(producer_intervention_data(graph, interventions))
  end

  defp dangling_data(unit_id, graph, interventions, %Blackboard{memory: mem}) do
    for %Graph.Node{} = node <- Map.values(graph.nodes),
        port <- node.inputs,
        not has_in_edge?(graph, node.id, port),
        into: %{} do
      key = PortRef.to_orchid_key({:port, node.id, port})

      value =
        case Map.fetch(mem, {unit_id, key}) do
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
  defp to_board_entries(unit_id, memory) do
    memory
    |> Map.new(fn {io_key, param} ->
      {{unit_id, io_key}, Orchid.Param.get_payload(param)}
    end)
    |> Map.reject(fn {_addr, payload} -> is_nil(payload) end)
  end
end
