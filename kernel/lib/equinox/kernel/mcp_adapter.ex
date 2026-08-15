defmodule Equinox.Kernel.MCPAdapter do
  @moduledoc """
  MCP 引擎适配器——经 MCP（stdio）从外部引擎进程拉取声库描述符的
  `Equinox.Kernel.EngineAdapter` 实现。

  定位：**能力声明拉取**（Phase 2 收尾的「真实 adapter」证明）。I/O
  集中在 `fetch/1`（建连、经典握手、`resources/read` 读描述符），五个
  回调拿到 enriched config 后保持纯函数——Runner check 的纯性不破。
  render-over-MCP（tool 调用进 Orchid 图）不做，那是 Hook 领地。

  ## config

      %{
        mcp: %{command: "uvx", args: ["some-engine-server"]},
        resource_uri: "vb://descriptor"   # 缺省值
      }

  `fetch/1` 在注册表构建期（`engines` 注入前）调用一次，返回 enriched
  config（追加 `:voicebank` 与 `:server_info`），之后回调零 I/O。

  ## 描述符 JSON 约定（resource text，`application/json`）

  键同 `Equinox.Kernel.Voicebank` 字段的字符串形。两个线上约定：

  - `capabilities.globals` 的规则用列表形（JSON 无 tuple）：
    `["range", min, max]` / `["enum", [...]]`（enum 的字符串值转 atom）；
  - `capabilities.adoptables` 缺省回落 `supported_channels`。
  """

  @behaviour Equinox.Kernel.EngineAdapter

  alias Equinox.Kernel.{ChannelSpecs, MCP.StdioClient, Voicebank}

  @default_resource_uri "vb://descriptor"
  @protocol_version "2025-06-18"

  # ---- 拉取（注册表构建期一次性 I/O） ----

  @doc """
  建连并拉取声库描述符，返回 enriched config（`{:ok, config}` 追加
  `:voicebank` / `:server_info`）；任一环节失败 `{:error, reason}`。
  """
  @spec fetch(map()) :: {:ok, map()} | {:error, term()}
  def fetch(%{mcp: %{command: command} = mcp} = config) do
    case StdioClient.open(command: command, args: Map.get(mcp, :args, [])) do
      {:ok, client} ->
        try do
          do_fetch(client, config)
        after
          StdioClient.close(client)
        end

      {:error, _} = err ->
        err
    end
  end

  def fetch(other), do: {:error, {:invalid_mcp_config, other}}

  defp do_fetch(client, config) do
    uri = Map.get(config, :resource_uri, @default_resource_uri)

    with {:ok, init} <- StdioClient.request(client, "initialize", handshake_params()),
         :ok <- StdioClient.notify(client, "notifications/initialized"),
         {:ok, %{"contents" => [%{"text" => text} | _]}} <-
           StdioClient.request(client, "resources/read", %{"uri" => uri}),
         {:ok, descriptor} <- Jason.decode(text),
         {:ok, voicebank} <- descriptor_to_voicebank(descriptor) do
      {:ok,
       config
       |> Map.put(:voicebank, voicebank)
       |> Map.put(:server_info, Map.get(init, "serverInfo", %{}))}
    end
  end

  defp handshake_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "equinox-kernel", "version" => "0.1.0"}
    }
  end

  # ---- EngineAdapter 回调（enriched config 上的纯函数） ----

  @impl true
  def engine_key(config), do: Voicebank.engine_key(voicebank!(config))

  @impl true
  def channels(config) do
    voicebank = voicebank!(config)
    key = Voicebank.engine_key(voicebank)
    # 无帧网格声明（timing 为空表）→ 曲线透传模态（D1）
    timing = if map_size(voicebank.timing) == 0, do: :none, else: voicebank.timing

    voicebank.capabilities
    |> Map.get(:supported_channels, [])
    |> Map.new(fn channel ->
      case ChannelSpecs.build(channel, key, timing: timing) do
        {:ok, spec} ->
          {channel, spec}

        {:error, reason} ->
          raise ArgumentError,
                "MCPAdapter: 声库声明的 channel 无法构造 spec：" <>
                  "#{inspect({channel, reason})}"
      end
    end)
  end

  @impl true
  def timing_spec(config), do: {:ok, voicebank!(config).timing}

  @impl true
  def globals(config), do: Map.get(voicebank!(config).capabilities, :globals, %{})

  @impl true
  def adoptables(config) do
    capabilities = voicebank!(config).capabilities
    Map.get(capabilities, :adoptables, Map.get(capabilities, :supported_channels, []))
  end

  defp voicebank!(%{voicebank: %Voicebank{} = voicebank}), do: voicebank

  defp voicebank!(config) do
    raise ArgumentError,
          "MCPAdapter config 缺 :voicebank——注册表构建期先调 fetch/1；" <>
            "当前键：#{inspect(Map.keys(config))}"
  end

  # ---- 描述符 JSON → Voicebank attrs ----

  defp descriptor_to_voicebank(%{} = descriptor) do
    Voicebank.new(%{
      id: Map.get(descriptor, "id"),
      engine: to_atom(Map.get(descriptor, "engine")),
      engine_version: Map.get(descriptor, "engine_version"),
      models: Map.get(descriptor, "models", %{}),
      dictionary: Map.get(descriptor, "dictionary", %{}),
      capabilities: normalize_capabilities(Map.get(descriptor, "capabilities", %{})),
      timing: normalize_timing(Map.get(descriptor, "timing", %{}))
    })
  end

  defp descriptor_to_voicebank(other), do: {:error, {:invalid_descriptor, other}}

  # 键存在才收录（空列表/空表是有效声明——如 adoptables: [] = 全部不可
  # 采纳——不能当缺失回落）；值归一化为 atom 列表 / globals 规则 tuple
  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    %{}
    |> put_atom_list(capabilities, "supported_channels", :supported_channels)
    |> put_atom_list(capabilities, "supported_params", :supported_params)
    |> put_atom_list(capabilities, "adoptables", :adoptables)
    |> put_globals(capabilities)
  end

  defp normalize_capabilities(_other), do: %{}

  defp put_atom_list(acc, map, wire_key, key) do
    case Map.fetch(map, wire_key) do
      {:ok, list} when is_list(list) -> Map.put(acc, key, atom_list(list))
      _absent_or_invalid -> acc
    end
  end

  defp put_globals(acc, capabilities) do
    case Map.fetch(capabilities, "globals") do
      {:ok, globals} when is_map(globals) -> Map.put(acc, :globals, normalize_globals(globals))
      _absent_or_invalid -> acc
    end
  end

  defp normalize_timing(timing) when is_map(timing) do
    %{}
    |> put_if(timing, "frame_rate", :frame_rate)
    |> put_if(timing, "hop", :hop)
  end

  defp normalize_timing(_other), do: %{}

  defp put_if(acc, map, wire_key, key) do
    case Map.fetch(map, wire_key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  # globals 规则线上形状：["range", min, max] / ["enum", [...]] → tuple
  defp normalize_globals(globals) when is_map(globals) do
    Map.new(globals, fn {key, rule} -> {String.to_atom(key), normalize_rule(rule)} end)
  end

  defp normalize_rule(["range", min, max]) when is_number(min) and is_number(max),
    do: {:range, min, max}

  defp normalize_rule(["enum", allowed]) when is_list(allowed),
    do: {:enum, Enum.map(allowed, &to_atom/1)}

  defp normalize_rule(other), do: other

  defp atom_list(list) when is_list(list), do: Enum.map(list, &to_atom/1)

  defp to_atom(nil), do: nil
  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_atom(value), do: value
end
