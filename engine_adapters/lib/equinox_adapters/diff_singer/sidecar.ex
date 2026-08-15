defmodule EquinoxAdapters.DiffSinger.Sidecar do
  @moduledoc """
  DiffSinger Python sidecar 的生命周期包装——每个声库目录（model_root）
  一个 python 子进程（8 个 ONNX session 常驻内存），经
  `Equinox.Kernel.MCP.StdioClient` 行分隔 JSON-RPC（MCP 形状）通信。

  协议面与工具清单见 `sidecar/server.py` 的 moduledoc；本模块只负责
  建连（`initialize` 握手）+ `tools/call` 转发 + content 解包。

  ## 启动

      {:ok, pid} = Sidecar.ensure_started(model_root, out_dir: "...")

  默认经 `uv run --project <engine_adapters/sidecar> server.py` 起子进程
  （`uv` 经 PATH 解析）；`opts[:command]` / `opts[:args]` 可整体覆盖
  （测试用 stub server 注入）。进程级副作用只在 Step routine 内发生
  （Runner check 相纯性不破）。

  ## 超时

  启动握手 600s（uv 首次依赖解析 + 8 session 加载在负载高的 CPU-only
  机器上可达数分钟）；单次工具调用 600s（CPU 扩散推理）。
  """

  use GenServer

  alias Equinox.Kernel.MCP.StdioClient

  @sidecar_dir Path.expand("../../../sidecar", __DIR__)
  @protocol_version "2025-06-18"
  @handshake_timeout 600_000
  @tool_timeout 600_000

  @registry EquinoxAdapters.SidecarRegistry
  @supervisor EquinoxAdapters.SidecarSupervisor

  @typedoc "sidecar 包装进程。"
  @type t :: pid()

  # ---- Client API ----

  @doc """
  确保 model_root 对应的 sidecar 已启动（Registry 按 model_root 去重）。
  """
  @spec ensure_started(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def ensure_started(model_root, opts \\ []) do
    case Registry.lookup(@registry, {:sidecar, model_root}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {model_root, opts}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  完整五段管线渲染。`opts`：`:out_path`（必填，wav 落盘绝对路径）、
  `:seed`（可选）、`:ph_dur_override`（可选，align 返回的对齐后逐音素
  帧数）、`:lead_in_sec`（可选；有 override 时必须显式传 align 的
  `lead_in_sec`，缺省由 sidecar 按句首 SP 词推导）。返回
  `{:ok, %{path, sample_rate, frames, lead_in_sec}}`。
  """
  @spec render(t(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def render(pid, words, opts) do
    arguments =
      %{"words" => words, "out_path" => Keyword.fetch!(opts, :out_path)}
      |> maybe_put("seed", Keyword.get(opts, :seed))
      |> maybe_put("ph_dur_override", Keyword.get(opts, :ph_dur_override))
      |> maybe_put("lead_in_sec", Keyword.get(opts, :lead_in_sec))

    tool_call(pid, "render", arguments)
  end

  @doc "确定性前向（编码 + dur + pitch），返回 `{:ok, %{ph_dur, pitch_pred_midi, total_frames}}`。"
  @spec predict(t(), list()) :: {:ok, map()} | {:error, term()}
  def predict(pid, words) do
    tool_call(pid, "predict", %{"words" => words})
  end

  @doc """
  元音锚点对齐（predict + 放置），返回
  `{:ok, %{phonemes, ph_dur, lead_in_sec, total_frames}}`——绝对音素边界
  即渲染真相（`ph_dur` 走 render 的 `:ph_dur_override` 回放）。
  """
  @spec align(t(), list()) :: {:ok, map()} | {:error, term()}
  def align(pid, words) do
    tool_call(pid, "align", %{"words" => words})
  end

  @doc "sidecar 的产物落盘目录。"
  @spec out_dir(t()) :: Path.t()
  def out_dir(pid) do
    # 排队在启动握手（模型加载，分钟级下限）之后是预期路径，不能用 5s 缺省
    GenServer.call(pid, :out_dir, @handshake_timeout + 5_000)
  end

  defp tool_call(pid, name, arguments) do
    GenServer.call(pid, {:tool_call, name, arguments}, @tool_timeout + 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :sidecar_not_running}
    :exit, {:normal, _} -> {:error, :sidecar_not_running}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # 线上 JSON → atom 键（递归；嵌套的 phonemes 列表项也要转）
  defp atomize_keys(%{} = map),
    do: Map.new(map, fn {key, value} -> {String.to_atom(key), atomize_keys(value)} end)

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  # ---- GenServer ----

  @doc false
  def start_link({model_root, opts}) do
    GenServer.start_link(__MODULE__, {model_root, opts},
      name: {:via, Registry, {@registry, {:sidecar, model_root}}}
    )
  end

  @impl true
  def init({model_root, opts}) do
    {:ok, %{model_root: model_root, opts: opts, client: nil, out_dir: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    out_dir = Keyword.get(state.opts, :out_dir, Path.join(@sidecar_dir, "out"))
    command = Keyword.get(state.opts, :command, "uv")
    args = Keyword.get(state.opts, :args, default_args(state.model_root, out_dir))

    with {:ok, client} <- StdioClient.open(command: command, args: args),
         {:ok, _init} <-
           StdioClient.request(client, "initialize", handshake_params(), @handshake_timeout),
         :ok <- StdioClient.notify(client, "notifications/initialized") do
      {:noreply, %{state | client: client, out_dir: out_dir}}
    else
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:out_dir, _from, state), do: {:reply, state.out_dir, state}

  def handle_call({:tool_call, _name, _arguments}, _from, %{client: nil} = state) do
    {:reply, {:error, :sidecar_not_running}, state}
  end

  def handle_call({:tool_call, name, arguments}, _from, %{client: client} = state) do
    reply =
      case StdioClient.request(
             client,
             "tools/call",
             %{"name" => name, "arguments" => arguments},
             @tool_timeout
           ) do
        {:ok, %{"isError" => true, "content" => [%{"text" => text} | _]}} ->
          {:error, {:tool_error, text}}

        {:ok, %{"content" => [%{"text" => text} | _]}} ->
          # 键集合封闭（自家 sidecar 线上形状），递归 atom 化无泄漏风险
          with {:ok, payload} <- Jason.decode(text) do
            {:ok, atomize_keys(payload)}
          end

        {:ok, other} ->
          {:error, {:bad_tool_result, other}}

        {:error, _} = err ->
          err
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{client: nil}), do: :ok
  def terminate(_reason, %{client: client}), do: StdioClient.close(client)

  defp default_args(model_root, out_dir) do
    [
      "run",
      "--project",
      @sidecar_dir,
      Path.join(@sidecar_dir, "server.py"),
      "--model-root",
      model_root,
      "--out-dir",
      out_dir
    ]
  end

  defp handshake_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "equinox-engine-adapters", "version" => "0.1.0"}
    }
  end
end
