# 假 MCP server（StdioClient / MCPAdapter 测试用）：行分隔 JSON-RPC 2.0，
# 应答 initialize / ping / resources/list / resources/read；未知方法报
# -32601。globals 规则的线上形状约定为 ["range", lo, hi] / ["enum", [...]]
# （JSON 无 tuple）。Jason 由测试经 -pa 注入 ebin 路径。

descriptor = %{
  "id" => "mcp_vb",
  "engine" => "stub",
  "engine_version" => "1.2.3",
  "capabilities" => %{
    "supported_channels" => ["phoneme_timing"],
    "globals" => %{"gender" => ["range", -1.0, 1.0]},
    "adoptables" => ["phoneme_timing"]
  },
  "timing" => %{"frame_rate" => 100, "hop" => 512}
}

handle = fn
  %{"id" => id, "method" => "initialize"} ->
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"resources" => %{}},
        "serverInfo" => %{"name" => "fake-mcp", "version" => "0.1.0"}
      }
    }

  %{"id" => id, "method" => "ping"} ->
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}

  %{"id" => id, "method" => "resources/list"} ->
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"resources" => [%{"uri" => "vb://descriptor", "name" => "voicebank"}]}
    }

  %{"id" => id, "method" => "resources/read", "params" => %{"uri" => uri}} ->
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "contents" => [
          %{"uri" => uri, "mimeType" => "application/json", "text" => Jason.encode!(descriptor)}
        ]
      }
    }

  %{"id" => id, "method" => method} ->
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found: #{method}"}
    }

  _notification ->
    nil
end

IO.stream(:stdio, :line)
|> Enum.each(fn line ->
  with {:ok, message} <- Jason.decode(line),
       response when not is_nil(response) <- handle.(message) do
    IO.puts(Jason.encode!(response))
  end
end)
