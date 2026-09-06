defmodule Neume.DiffSingerWorkerTest do
  @moduledoc "不启动 Python 的 worker 身份回归：默认 CPU 复用、实验后端隔离。"
  use ExUnit.Case, async: false

  alias Neume.Engine.DiffSingerWorker
  alias Neume.Engine.DiffSingerWorker.Server

  test "后端进入常驻身份，相同配置复用" do
    python = "neume-missing-python-#{System.unique_integer([:positive])}"
    config = %{python: [python], voicebank_root: "unused"}

    workers = fn ->
      for {Server, key} = name <- :global.registered_names(),
          elem(key, 0) == [python],
          do: :global.whereis_name(name)
    end

    on_exit(fn ->
      for pid <- workers.(), is_pid(pid), Process.alive?(pid), do: GenServer.stop(pid)
    end)

    for backend <- [nil, :cpu, :openvino, :openvino] do
      opts = if backend, do: Map.put(config, :backend, backend), else: config

      assert {:error, {:python_not_found, ^python}} =
               DiffSingerWorker.call(%{action: "check"}, opts)

      assert length(workers.()) == if(backend == :openvino, do: 2, else: 1)
    end
  end
end
