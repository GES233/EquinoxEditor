defmodule Equinox.Kernel.Runner do
  @moduledoc """
  Dispatch units 的执行器（`Oi.execute/2` 的薄封装），两段式：先 check 后 render。

  check 阶段对全部 unit 的存活 patch（`RenderRequest.patches`，写时 transport
  已由 workspace 完成）按 channel 分组，经 Configurator 注入的 channel spec
  逐 patch 求新鲜投影并 `Tamale.Patch.resolve/2` 判定（digest 零容差比对，
  与 `Coconut.Render.Resolve` 同语义）；冲突 / 未知通道 / 投影失败全量聚合为
  `{:error, {:check_failed, [entry]}}`，且一个窗口都不执行。全部通过才把
  resolved payload 折叠为 `%{PortRef => %{input: value}}` 干预规格，进入
  render 阶段。

  同阶段还有 globals 门控：dispatch `track_globals` 携带的 per-track
  引擎旋钮值按轨对照 `track_global_rules`（缺条目回落
  `Configurator.global_rules`；nil = 无 Adapter 声明，不门控）校验，
  违例以 `kind: :global` 条目（带 `:track_id` / `:key`）并入同一聚合。

  输入装配沿用旧 Engine 语义：Blackboard 优先、干预兜底、悬空输入给 `:void` Param；
  跨 bundle 的内部键由 Oi 在执行计划内自动流转，不参与装配。

  前置条件：会话基础设施已启动（`Oi.Runtime.Session.ensure_started/2`，
  由 `Equinox.Session.Server` 在 init 时完成），否则 TaskSup 执行器找不到监督进程。
  """

  alias Equinox.Kernel.{Blackboard, Compiler, Configurator, Graph}
  alias Equinox.Kernel.Graph.PortRef

  @typedoc "单个窗口的执行单元（即 Compiler 的编译产物）：第三元素是窗口 RenderRequest，check 通过后派生 `Compiler.interventions_map()` 喂输入装配。"
  @type unit :: Compiler.compiled_unit()

  @typedoc """
  一次渲染 dispatch：会话标识 + 全部窗口的执行单元 + 按轨派生的 channel
  specs（`track_channels`，per-track EngineAdapter 粒度；缺条目的轨回落
  `Configurator.channels`）；`track_globals` / `track_global_rules` 为
  per-track 引擎旋钮值与校验规则（globals 门控，见模块文档）。
  """
  @type dispatch :: %{
          required(:session_id) => atom() | String.t(),
          required(:units) => [unit()],
          optional(:track_channels) => %{term() => %{atom() => Configurator.channel_spec()}},
          optional(:track_globals) => %{term() => %{atom() => term()}},
          optional(:track_global_rules) => %{
            term() => %{atom() => {:range, term(), term()} | {:enum, [term()]}}
          }
        }

  @typedoc "check 失败条目；`:conflict` 另带 `:intervention_id`（patch id）字段；`:global` 条目带 `:track_id` / `:key`（无 `:unit_id` / `:channel`）。"
  @type check_entry :: %{
          optional(:intervention_id) => term(),
          optional(:unit_id) => Compiler.unit_id(),
          optional(:channel) => atom(),
          optional(:track_id) => term(),
          optional(:key) => atom(),
          kind: :conflict | :unknown_channel | :projection_failed | :global,
          reason: term()
        }

  @doc """
  执行全部窗口的 dispatch units，把结果合并进 Blackboard。

  先跑 check（全部 unit 的 patch resolve，见模块文档）：任一失败全量聚合
  为 `{:error, {:check_failed, [entry]}}` 且一个窗口都不执行；空 patch 快路径
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

  def run(
        %{session_id: session_id, units: units} = dispatch,
        %Blackboard{} = board,
        %Configurator{} = conf
      ) do
    track_channels = Map.get(dispatch, :track_channels, %{})
    global_entries = check_track_globals(dispatch, conf.global_rules)

    case resolve_units(units, conf.channels, track_channels) do
      {:ok, runnable} ->
        if global_entries == [] do
          do_run(session_id, runnable, board, conf)
        else
          {:error, {:check_failed, global_entries}}
        end

      {:error, {:check_failed, entries}} ->
        {:error, {:check_failed, global_entries ++ entries}}
    end
  end

  # check 全过后跨窗口以 `Task.async_stream` 扇出（首个错误中断）
  defp do_run(session_id, runnable, board, conf) do
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

  # ---- check 阶段：globals 门控（与 patch check 共用 one-vote 全量聚合） ----

  # 值来自 dispatch.track_globals（per-track 引擎旋钮，TrackMeta 侧表供给）；
  # 校验规则按轨取 track_global_rules（Adapter 派生），缺条目回落
  # conf.global_rules；规则为 nil = 无 Adapter 声明，不做门控。条目顺序按
  # track_id 排序保证确定性
  @spec check_track_globals(dispatch(), Configurator.t()[:global_rules]) :: [check_entry()]
  defp check_track_globals(dispatch, default_rules) do
    values_by_track = Map.get(dispatch, :track_globals, %{})
    rules_by_track = Map.get(dispatch, :track_global_rules, %{})

    values_by_track
    |> Enum.sort_by(fn {track_id, _values} -> inspect(track_id) end)
    |> Enum.flat_map(fn {track_id, values} ->
      case Map.get(rules_by_track, track_id, default_rules) do
        nil -> []
        rules -> validate_globals(track_id, values, rules)
      end
    end)
  end

  defp validate_globals(track_id, values, rules) do
    for {key, value} <- values, entry = check_global(track_id, key, value, rules), do: entry
  end

  defp check_global(track_id, key, value, rules) do
    case Map.fetch(rules, key) do
      :error ->
        %{kind: :global, track_id: track_id, key: key, reason: :unknown_global}

      {:ok, spec} ->
        case conform_global(spec, value) do
          :ok -> nil
          {:error, reason} -> %{kind: :global, track_id: track_id, key: key, reason: reason}
        end
    end
  end

  # 与 coconut `Render.Engine` 的 globals 门控同语义（reason 形状对齐）
  defp conform_global({:range, lo, hi}, value) when is_number(value) do
    if value >= lo and value <= hi, do: :ok, else: {:error, {:out_of_range, {lo, hi}}}
  end

  defp conform_global({:range, _, _}, _value), do: {:error, :not_a_number}

  defp conform_global({:enum, allowed}, value) do
    if value in allowed, do: :ok, else: {:error, {:not_in_enum, allowed}}
  end

  defp conform_global(spec, _value), do: {:error, {:invalid_global_spec, spec}}

  # ---- check 阶段：patch resolve（先于任何执行） ----

  # 逐 unit 把存活 patch 按 channel 分组 resolve；错误条目全量聚合（不放过
  # 任何一个 unit），全部通过才换形为 {unit_id, graph, interventions_map,
  # compiled}。空 patch 快路径零成本：group_by 得空 map，reduce 直接返回
  # {[], %{}}。channel specs 按 unit 所属轨解析（per-track Adapter 粒度），
  # 缺条目回落 default（`Configurator.channels`）。
  @spec resolve_units([unit()], %{atom() => Configurator.channel_spec()}, %{
          term() => %{atom() => Configurator.channel_spec()}
        }) ::
          {:ok, [{Compiler.unit_id(), Graph.t(), Compiler.interventions_map(), Oi.Compiled.t()}]}
          | {:error, {:check_failed, [check_entry()]}}
  defp resolve_units(units, default_channels, track_channels) do
    {runnable, entries} =
      Enum.map_reduce(units, [], fn {unit_id, graph, request, compiled}, entries_acc ->
        {track_id, _window_start} = unit_id
        channels = Map.get(track_channels, track_id, default_channels)
        {unit_entries, interventions_map} = resolve_unit(unit_id, request, channels)
        {{unit_id, graph, interventions_map, compiled}, entries_acc ++ unit_entries}
      end)

    case entries do
      [] -> {:ok, runnable}
      _ -> {:error, {:check_failed, entries}}
    end
  end

  defp resolve_unit(unit_id, request, channels) do
    request.patches
    |> Enum.group_by(& &1.channel)
    |> Enum.reduce({[], %{}}, fn {channel, patches}, {entries_acc, data_acc} ->
      {entries, data} = resolve_channel(unit_id, channel, patches, request, channels)
      {entries_acc ++ entries, Map.merge(data_acc, data)}
    end)
  end

  # 单 channel：无 spec → :unknown_channel（每 patch 一条）；逐 patch 求新鲜
  # 投影（projection 失败 → :projection_failed）后 `Tamale.Patch.resolve/2`
  # 判定（digest 漂移 → :conflict，带 patch id）；全部 ok 则把 payload 经
  # spec.target 折叠为干预规格
  defp resolve_channel(unit_id, channel, patches, request, channels) do
    case Map.fetch(channels, channel) do
      :error ->
        entries =
          Enum.map(patches, fn patch ->
            %{
              unit_id: unit_id,
              channel: channel,
              kind: :unknown_channel,
              reason: :no_channel_spec,
              intervention_id: patch.id
            }
          end)

        {entries, %{}}

      {:ok, spec} ->
        Enum.reduce(patches, {[], %{}}, fn patch, {entries_acc, data_acc} ->
          case resolve_patch(spec, request, patch) do
            {:ok, payload} ->
              {entries_acc, Map.merge(data_acc, fold_resolved(payload, spec.target))}

            {:error, kind, reason} ->
              entry = %{
                unit_id: unit_id,
                channel: channel,
                kind: kind,
                reason: reason,
                intervention_id: patch.id
              }

              {[entry | entries_acc], data_acc}
          end
        end)
        |> then(fn {entries, data} -> {Enum.reverse(entries), data} end)
    end
  end

  # 逐 patch resolve：新鲜投影（digest 输入的 canonical 归一化是 channel /
  # Host 侧职责）→ digest 零容差比对。`Tamale.Patch.resolve/2` 的
  # `{:error, _}`（投影非 canonical）归入 :projection_failed
  defp resolve_patch(spec, request, patch) do
    with {:ok, fresh_base} <- spec.projection.(request, patch),
         {:ok, payload} <- Tamale.Patch.resolve(patch.patch, fresh_base) do
      {:ok, payload}
    else
      {:conflict, reason} -> {:error, :conflict, reason}
      {:error, reason} -> {:error, :projection_failed, reason}
      other -> {:error, :projection_failed, other}
    end
  end

  # resolved payload 经 channel spec 的 target 绑定端口，折叠为 assemble_data
  # 识别的 %{PortRef => %{input: value}} 形状：PortRef 直取，或一元函数
  # fan-out；同端口后写覆盖先写（与 `Coconut.Render.Resolve` 同语义）
  defp fold_resolved(payload, target) do
    target
    |> bind_payload(payload)
    |> Map.new(fn {port_ref, value} -> {port_ref, %{input: value}} end)
  end

  defp bind_payload(target, payload) when is_function(target, 1), do: target.(payload)

  defp bind_payload({:port, _node, _port} = port_ref, payload), do: [{port_ref, payload}]

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
