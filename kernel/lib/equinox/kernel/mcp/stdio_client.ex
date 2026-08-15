defmodule Equinox.Kernel.MCP.StdioClient do
  @moduledoc """
  最小 MCP stdio client——行分隔 JSON-RPC 2.0 over 子进程 stdio。

  为零依赖（Jason 已在 kernel 依赖里）的能力声明拉取而写：只覆盖经典
  握手（`initialize` → `notifications/initialized`）与 request/notify
  骨架；server 通知忽略、error 对象透传、Port 死亡时挂起请求全部以
  `{:error, {:server_exited, status}}` 收尾。分页 / progress /
  cancellation 不实现（能力拉取用不到）。

  Windows 注意：`command` 经 `System.find_executable/1` 解析 PATH；
  `.bat` / `.cmd` 包装（npx / uvx 在 Windows 的形态）由 Erlang 的
  `spawn_executable` 直接处理（已验证），无需 `cmd /c`。
  """

  use GenServer

  @default_timeout 10_000
  @max_line 1_048_576

  @typedoc "client 进程。"
  @type t :: pid()

  # ---- Client API ----

  @doc """
  启动子进程并返回 client。`opts`：`:command`（必填，可执行名或路径）、
  `:args`（缺省 `[]`）、`:env`（缺省 `%{}`）。找不到可执行文件报
  `{:error, {:command_not_found, command}}`。
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    with {:ok, command} <- Keyword.fetch(opts, :command),
         {:ok, executable, args} <- resolve_executable(command, Keyword.get(opts, :args, [])) do
      GenServer.start_link(__MODULE__, {executable, args, Keyword.get(opts, :env, %{})})
    end
  end

  @doc "同步 JSON-RPC 请求（`{:ok, result}` / `{:error, error_object | reason}`）。"
  @spec request(t(), binary(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def request(client, method, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(client, {:request, method, params}, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :client_not_running}
    :exit, {:normal, _} -> {:error, :client_not_running}
  end

  @doc "发 JSON-RPC 通知（无响应）。"
  @spec notify(t(), binary(), map()) :: :ok
  def notify(client, method, params \\ %{}), do: GenServer.cast(client, {:notify, method, params})

  @doc "关闭 client 与子进程。"
  @spec close(t()) :: :ok
  def close(client) do
    GenServer.stop(client, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # ---- 可执行解析 ----

  # Erlang 的 spawn_executable 在 Windows 下能直接跑 .bat/.cmd 包装
  # （已验证：Scoop 的 elixir.bat 原始 spawn 正常），只需解析 PATH
  defp resolve_executable(command, args) do
    case System.find_executable(command) do
      nil -> {:error, {:command_not_found, command}}
      path -> {:ok, path, args}
    end
  end

  # ---- GenServer ----

  @impl true
  def init({executable, args, env}) do
    # {:env, []} 是「清空环境」而非「不设置」，非空才传
    port_opts =
      [:binary, :use_stdio, :exit_status, {:line, @max_line}, {:args, args}] ++ env_opts(env)

    {:ok,
     %{port: Port.open({:spawn_executable, executable}, port_opts), next_id: 1, pending: %{}}}
  end

  defp env_opts(env) when map_size(env) == 0, do: []

  defp env_opts(env) do
    [{:env, Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}]
  end

  @impl true
  def handle_call({:request, method, params}, from, %{port: nil} = state) do
    _ = {method, params, from}
    {:reply, {:error, :server_not_running}, state}
  end

  def handle_call({:request, method, params}, from, state) do
    id = state.next_id

    send_message(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_cast({:notify, method, params}, %{port: nil} = state) do
    _ = {method, params}
    {:noreply, state}
  end

  def handle_cast({:notify, method, params}, state) do
    send_message(state.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, message} -> {:noreply, dispatch(message, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, {:server_exited, status}})
    end

    {:noreply, %{state | port: nil, pending: %{}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, %{port: port}) do
    Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  # ---- 消息分发 ----

  # 响应（带 id）：配对挂起请求
  defp dispatch(%{"id" => id, "result" => result}, state) do
    {from, pending} = Map.pop(state.pending, id)
    if from, do: GenServer.reply(from, {:ok, result})
    %{state | pending: pending}
  end

  defp dispatch(%{"id" => id, "error" => error}, state) do
    {from, pending} = Map.pop(state.pending, id)
    if from, do: GenServer.reply(from, {:error, error})
    %{state | pending: pending}
  end

  # server 通知 / 主动请求：忽略（最小实现无 server→client 调用面）
  defp dispatch(_other, state), do: state

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end
end
