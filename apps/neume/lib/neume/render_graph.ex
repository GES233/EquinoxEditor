defmodule Neume.RenderGraph do
  @moduledoc """
  Neume 声明式多轨渲染图（见 `docs/design-2026-09-multitrack-runtime.md`）：

  ```text
  render_<id> × N（每轨一节点、独立 cluster，stage 内并行 fan-out）
    └─► collect（按 arity 生成的 fan-in 节点）
          └─► TrackGainPan ──► Mix ──► Master ──► Export
  ```

  - solo/mute 路由在建图前由 `Neume.MixPipeline.audible_tracks/1` 完成，
    被排除轨不建节点（跳过渲染）；路由变化只影响下游 Mix 的输入集合，
    不使声学 phrase 缓存失效；
  - track 节点不缓存：phrase 级缓存由 `Neume.RenderCache`（磁盘）承担；
  - TrackGainPan/Mix/Master/Export 挂 `cache: true`，由 orchid_stratum
    整步缓存，stores 为 per-MultiTrack 的 ETS 表（`cache_stores`），
    生命周期随工程（owner 为 `MultiTrack.open/2` 调用进程，如 Neumu
    的 `ProjectServer`）；工程关闭即整表回收，无跨工程共享；
  - 并发上限走 `Oi.Executor.TaskSup`（`:concurrency` 默认
    `System.schedulers_online()`）；stage 内 fail-fast，错误聚合成
    `{:error, {:render_failed, entries}}`，entry 带 `track_id`。
  - 协作取消：`run/3` 的 `:cancel_token`（`Oi.CancelToken`）同时进入
    Oi dispatch（stage 边界闸门）与各轨渲染请求（`TrackRender` 入口
    检查 + `Editor.render/2` 透传给实现 `render_checked/6` 的 runtime
    做乐句粒度轮询）。取消统一归一为 `{:error, :render_cancelled}`；
    不抢占在途步骤。
  - 进度：`run/3` 的 `:progress` 一元回调随请求透传。`TrackRender`
    上报轨级 `%{kind: :track, track_id: _, status: :started | :finished
    | :failed}`；乐句粒度由 runtime 自报（`render_checked/6` 契约）。
    payload 形状是生产者自由约定，不进 `Neume.Event` 信封以外的契约。
    本图不自建第二执行器。
  """

  alias Coconut.Edit.{Track, Workspace}
  alias Neume.{Editor, MixPipeline, MultiTrack, TrackConfig}
  alias Oi.Flowgraph

  @type audible :: [{Track.track_id(), Track.t()}]

  # ---------- TrackRender（每轨一个节点，不缓存） ----------

  defmodule Steps.TrackRender do
    @moduledoc false
    use Oi.Step, name: :track_render

    manifest(inputs: [:request], outputs: [artifact: :any])

    routine request, _opts do
      case request do
        %{
          session: session,
          pickle_registry: registry,
          track_runtime: track_runtime,
          track_id: track_id
        } = req ->
          token = Map.get(req, :cancel_token)
          progress = Map.get(req, :progress)

          if Neume.RenderGraph.cancel_requested?(token) do
            {:error, {:track_render_failed, track_id, :render_cancelled}}
          else
            Neume.Runtime.report_progress(progress, %{
              kind: :track,
              track_id: track_id,
              status: :started
            })

            result =
              with {:ok, editor} <- Editor.attach_runtime(track_runtime, session, registry),
                   {:ok, editor, artifact} <- Editor.render(editor, render_opts(token, progress)),
                   {:ok, track_runtime} <- Editor.detach_runtime(editor),
                   {:ok, track} <- Workspace.fetch_track(Coconut.workspace(session), track_id) do
                ok(%{
                  track_id: track_id,
                  artifact: artifact,
                  track_runtime: track_runtime,
                  mix: TrackConfig.mix(track),
                  # 每次渲染的制品路径都是新文件，内容摘要才是稳定的缓存 key 成分。
                  wav_digest: wav_digest(artifact.path)
                })
              else
                {:error, reason} -> {:error, {:track_render_failed, track_id, reason}}
              end

            Neume.Runtime.report_progress(progress, %{
              kind: :track,
              track_id: track_id,
              status: track_progress_status(result)
            })

            result
          end

        other ->
          {:error, {:invalid_render_request, other}}
      end
    end

    defp render_opts(token, progress) do
      [cancel_token: token, progress: progress]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end

    defp track_progress_status({:ok, _}), do: :finished
    defp track_progress_status({:error, _}), do: :failed

    defp wav_digest(path) do
      case File.read(path) do
        {:ok, binary} -> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
        _missing -> nil
      end
    end
  end

  # ---------- Collect（fan-in） ----------

  defmodule Steps.Collect do
    @moduledoc false
    # Oi 图是静态 DAG，单端口只接受一条入边（`Oi.Compile.Bundle.node_to_step/2`
    # 对每个输入端口只取一条边），N 个 track 节点的输出无法直接汇入
    # TrackGainPan 的 :tracks 端口。这里按 arity 生成 fan-in 模块
    # （同 arity 全局共享一份、按 track_id 排序对齐输入端口），把 N 路
    # artifact 收成有序列表。

    @spec module_for(pos_integer()) :: module()
    def module_for(count) when is_integer(count) and count > 0 do
      module = Module.concat(__MODULE__, "N#{count}")

      unless Code.ensure_loaded?(module) do
        :global.set_lock({__MODULE__, module})

        try do
          unless Code.ensure_loaded?(module) do
            Module.create(module, module_ast(count), Macro.Env.location(__ENV__))
          end
        after
          :global.del_lock({__MODULE__, module})
        end
      end

      module
    end

    defp module_ast(1) do
      quote do
        use Oi.Step, name: :collect_n1

        manifest(inputs: [:in_0], outputs: [tracks: :any])

        routine in_0, opts do
          _ = opts
          ok([in_0])
        end
      end
    end

    defp module_ast(count) do
      inputs = Enum.map(0..(count - 1), &String.to_atom("in_#{&1}"))
      vars = Enum.map(0..(count - 1), &Macro.var(String.to_atom("in_#{&1}"), nil))

      quote do
        use Oi.Step, name: String.to_atom("collect_n#{unquote(count)}")

        manifest(inputs: unquote(inputs), outputs: [tracks: :any])

        routine unquote(vars), opts do
          _ = opts
          ok(unquote(vars))
        end
      end
    end
  end

  # ---------- 取消信号 ----------

  @doc "协作取消令牌是否已被取消；无令牌（nil）恒为 false。"
  @spec cancel_requested?(Oi.CancelToken.t() | nil) :: boolean()
  def cancel_requested?(nil), do: false
  def cancel_requested?(%Oi.CancelToken{} = token), do: Oi.CancelToken.cancelled?(token)

  # ---------- 缓存 stores（per-MultiTrack ETS，生命周期随工程） ----------

  @doc "新建一对 stratum ETS stores（meta/blob），供 `orchid_baggage` 使用。"
  @spec new_cache_stores() :: map()
  def new_cache_stores do
    %{
      meta_store:
        {OrchidStratum.MetaStorage.EtsAdapter, OrchidStratum.MetaStorage.EtsAdapter.init()},
      blob_store:
        {OrchidStratum.BlobStorage.EtsAdapter, OrchidStratum.BlobStorage.EtsAdapter.init()}
    }
  end

  # ---------- 图构建 ----------

  @spec build(audible(), keyword()) :: {:ok, Oi.Compiled.t()} | {:error, term()}
  def build(audible, opts \\ []) do
    track_ids = Enum.map(audible, &elem(&1, 0))

    graph =
      Flowgraph.new_flowchart()
      |> add_render_steps(track_ids)
      |> Flowgraph.add_step(Steps.Collect.module_for(length(track_ids)), as: :collect)
      |> Flowgraph.add_step(MixPipeline.Steps.TrackGainPan, opts: [cache: true])
      |> Flowgraph.add_step(MixPipeline.Steps.Mix, opts: [cache: true])
      |> Flowgraph.add_step(MixPipeline.Steps.Master, opts: [cache: true])
      |> Flowgraph.add_step(MixPipeline.Steps.Export,
        opts: [cache: true, output_dir: Keyword.get(opts, :output_dir, "tmp/renders")]
      )
      |> connect_renders(track_ids)
      |> Flowgraph.connect({:collect, :tracks}, {:track_gain_pan, :tracks})
      |> Flowgraph.connect({:track_gain_pan, :prepared_tracks}, {:mix, :tracks})
      |> Flowgraph.connect({:mix, :mix}, {:master, :mix})
      |> Flowgraph.connect({:master, :master}, {:export, :master})

    # 每轨独立 cluster：同 stage 的 N 个 bundle 经 TaskSup 真并行。
    cluster = %Oi.Topology.Cluster{
      node_colors: Map.new(track_ids, &{render_node(&1), render_cluster(&1)})
    }

    Oi.compile(graph, cluster)
  end

  @spec run(MultiTrack.t(), audible(), keyword()) ::
          {:ok, MultiTrack.t(), Neume.MixArtifact.t()} | {:error, term()}
  def run(%MultiTrack{} = runtime, audible, opts \\ []) do
    with {:ok, compiled} <- build(audible, output_dir: runtime.output_dir),
         data <- build_data(runtime, audible, opts),
         {:ok, sup} <- Task.Supervisor.start_link() do
      try do
        execute_and_collect(runtime, compiled, data, audible, sup, opts)
      after
        Supervisor.stop(sup)
      end
    end
  end

  defp add_render_steps(graph, track_ids) do
    Enum.reduce(track_ids, graph, fn track_id, acc ->
      Flowgraph.add_step(acc, Steps.TrackRender, as: render_node(track_id))
    end)
  end

  defp connect_renders(graph, track_ids) do
    track_ids
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {track_id, index}, acc ->
      Flowgraph.connect(
        acc,
        {render_node(track_id), :artifact},
        {:collect, String.to_atom("in_#{index}")}
      )
    end)
  end

  defp build_data(runtime, audible, opts) do
    cancel_token = Keyword.get(opts, :cancel_token)
    progress = Keyword.get(opts, :progress)

    Map.new(audible, fn {track_id, _track} ->
      request = %{
        session: runtime.session,
        pickle_registry: runtime.pickle_registry,
        track_runtime: Map.fetch!(runtime.tracks, track_id),
        track_id: track_id
      }

      request =
        if cancel_token, do: Map.put(request, :cancel_token, cancel_token), else: request

      request = if progress, do: Map.put(request, :progress, progress), else: request

      {render_node(track_id), %{request: request}}
    end)
  end

  defp execute_and_collect(runtime, compiled, data, audible, sup, opts) do
    execute_opts =
      [
        data: data,
        executor: Oi.Executor.TaskSup,
        executor_opts: [sup: sup],
        orchid_adapters: [&Oi.Adapters.orchid_stratum/2],
        orchid_baggage: runtime.cache_stores
      ] ++ opts

    case Oi.execute(compiled, execute_opts) do
      {:ok, %Oi.Result{status: :cancelled}} ->
        # 取消发生在 stage 边界（track 渲染全部结束之后、mix 之前等）。
        {:error, :render_cancelled}

      {:ok, result} ->
        collect(runtime, result, audible)

      {:error, _} = error ->
        # track 渲染经 token 轮询提前终止时，取消语义优先于原始错误形状。
        if cancel_requested?(Keyword.get(opts, :cancel_token)),
          do: {:error, :render_cancelled},
          else: normalize_error(error)
    end
  end

  defp collect(runtime, result, audible) do
    with {:ok, artifact} <- Oi.Result.reify(result, {:export, :artifact}) do
      # 末端 step 经 stratum 缓存后，drafting memory 里是脱水 ref，取回后按需水合。
      artifact = hydrate(artifact)

      tracks =
        Enum.reduce(audible, runtime.tracks, fn {track_id, _track}, acc ->
          {:ok, payload} = Oi.Result.reify(result, {render_node(track_id), :artifact})
          Map.put(acc, track_id, payload.track_runtime)
        end)

      {:ok, %{runtime | tracks: tracks}, artifact}
    end
  end

  defp hydrate({:ref, store, hash}) do
    case Orchid.Repo.dispatch_store(store, :get, [hash]) do
      {:ok, data} -> data
      :miss -> raise "stratum hydration failed: blob #{Base.encode16(hash)} missing"
    end
  end

  defp hydrate(other), do: other

  defp normalize_error({:error, {:orchid_error, _recipe, %Orchid.Error{reason: reason}}}) do
    case unwrap_reason(reason) do
      {:track_render_failed, track_id, inner} ->
        {:error, {:render_failed, [%{kind: :track, track_id: track_id, reason: inner}]}}

      other ->
        {:error, {:render_failed, [%{kind: :render, reason: other}]}}
    end
  end

  defp normalize_error({:error, _} = error), do: error

  defp unwrap_reason([single]), do: unwrap_reason(single)
  defp unwrap_reason(other), do: other

  defp render_node(track_id), do: String.to_atom("render_#{track_id}")
  defp render_cluster(track_id), do: String.to_atom("render_#{track_id}")
end
