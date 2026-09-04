defmodule Neume.Engine.DiffSingerWorker do
  @moduledoc """
  DiffSinger Python worker 的 NDJSON Port 客户端。

  同一 `{python, voicebank_root, voicebank_digest, worker}` 只保留一个常驻
  进程，ONNX session 因而不会在每次渲染时重载；原地更新模型后摘要变化，
  也不会误用旧 session。请求串行化是刻意的：一个 worker 内的模型与 ONNX
  Runtime arena 归同一生命周期所有。
  """

  alias Neume.Engine.DiffSingerWorker.Server

  @callback call(map(), map()) :: {:ok, map()} | {:error, term()}

  @spec call(map(), map()) :: {:ok, map()} | {:error, term()}
  def call(payload, config) when is_map(payload) and is_map(config) do
    with {:ok, pid} <- ensure_server(config) do
      GenServer.call(pid, {:request, payload}, :infinity)
    end
  end

  defp ensure_server(config) do
    key = worker_key(config)
    name = {:global, {Server, key}}

    case :global.whereis_name({Server, key}) do
      :undefined ->
        case Server.start({name, key, config}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  defp worker_key(config) do
    {Map.get(config, :python, ["python"]), Map.fetch!(config, :voicebank_root),
     Map.get(config, :voicebank_digest), Map.get(config, :fp_manifest),
     Map.get(config, :fp_manifest_digest), Map.get(config, :fp_noise_version),
     Map.get(config, :seed, 0), Map.get(config, :worker, default_worker())}
  end

  defp default_worker do
    Application.app_dir(:neume, "priv/diffsinger/worker.py")
  end

  defmodule Server do
    @moduledoc false

    use GenServer

    require Logger

    @line_limit 64_000_000

    def start({name, key, config}) do
      GenServer.start(__MODULE__, {key, config}, name: name)
    end

    @impl true
    def init({key, config}) do
      {:ok,
       %{
         port: nil,
         key: key,
         config: config,
         ready: false,
         buffer: "",
         current: nil,
         queue: :queue.new(),
         next_id: 1
       }}
    end

    @impl true
    def handle_call({:request, payload}, from, state) do
      case ensure_worker(state) do
        {:ok, state} ->
          id = state.next_id

          state = %{
            state
            | next_id: id + 1,
              queue: :queue.in({id, from, payload}, state.queue)
          }

          {:noreply, maybe_dispatch(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, reset_worker(state)}
      end
    end

    @impl true
    def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
      {:noreply, handle_line(%{state | buffer: ""}, state.buffer <> line)}
    end

    def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
      {:noreply, %{state | buffer: state.buffer <> chunk}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
      error = {:error, {:worker_exit, status}}

      if state.current, do: GenServer.reply(elem(state.current, 1), error)

      Enum.each(:queue.to_list(state.queue), fn {_id, from, _payload} ->
        GenServer.reply(from, error)
      end)

      {:noreply, reset_worker(state)}
    end

    def handle_info(_message, state), do: {:noreply, state}

    defp ensure_worker(%{port: port} = state) when is_port(port), do: {:ok, state}

    defp ensure_worker(state), do: spawn_worker(state)

    defp spawn_worker(%{config: config} = state) do
      if is_port(state.port), do: Port.close(state.port)

      [command | args] = Map.get(config, :python, ["python"])

      case System.find_executable(command) do
        nil ->
          {:error, {:python_not_found, command}}

        executable ->
          worker = Map.get(config, :worker, default_worker())

          if File.regular?(worker) do
            port =
              Port.open({:spawn_executable, executable}, [
                :binary,
                :stream,
                :exit_status,
                {:line, @line_limit},
                {:args,
                 args ++
                   [worker, Map.fetch!(config, :voicebank_root)] ++
                   worker_args(config)}
              ])

            {:ok, %{state | port: port, ready: false, buffer: "", current: nil}}
          else
            {:error, {:worker_not_found, worker}}
          end
      end
    end

    defp worker_args(config) do
      case Map.get(config, :fp_manifest) do
        path when is_binary(path) ->
          ["--fp-manifest", path, "--seed", to_string(Map.get(config, :seed, 0))]

        _ ->
          []
      end
    end

    defp default_worker do
      Application.app_dir(:neume, "priv/diffsinger/worker.py")
    end

    defp maybe_dispatch(%{ready: true, current: nil} = state) do
      case :queue.out(state.queue) do
        {:empty, _queue} ->
          state

        {{:value, {id, from, payload}}, queue} ->
          line = payload |> Map.put(:id, id) |> Jason.encode!()
          true = Port.command(state.port, line <> "\n")
          %{state | current: {id, from}, queue: queue}
      end
    end

    defp maybe_dispatch(state), do: state

    defp handle_line(state, line) do
      case Jason.decode(line) do
        {:ok, %{"ready" => true}} ->
          maybe_dispatch(%{state | ready: true})

        {:ok, %{"id" => id} = response} ->
          state |> reply_current(id, response) |> maybe_dispatch()

        {:ok, other} ->
          Logger.warning("DiffSinger worker 返回未知消息：#{inspect(other)}")
          state

        {:error, _reason} ->
          Logger.warning("DiffSinger worker 返回非 JSON 行：#{String.slice(line, 0, 200)}")
          state
      end
    end

    defp reply_current(%{current: {id, from}} = state, id, response) do
      reply =
        if response["ok"],
          do: {:ok, response["result"]},
          else: {:error, {:worker_error, response["error"]}}

      GenServer.reply(from, reply)
      %{state | current: nil}
    end

    defp reply_current(state, id, _response) do
      Logger.warning("DiffSinger worker 返回过期请求 id：#{id}")
      state
    end

    defp reset_worker(state) do
      %{
        state
        | port: nil,
          ready: false,
          buffer: "",
          current: nil,
          queue: :queue.new()
      }
    end
  end
end
