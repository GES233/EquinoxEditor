# 假 DiffSinger sidecar（Sidecar 测试用）：行分隔 JSON-RPC 2.0，应答
# initialize / tools/call（predict / render）；render 会在 out_path 落一个
# 假文件模拟产物；工具 "fail" 返回 isError: true。Jason 由测试经 -pa 注入。

handle_tool = fn
  "predict", _args ->
    %{"ph_dur" => [42], "pitch_pred_midi" => [60.0], "total_frames" => 42}

  "render", args ->
    out_path = args["out_path"]
    File.mkdir_p!(Path.dirname(out_path))
    File.write!(out_path, "fake-wav")
    %{"path" => out_path, "sample_rate" => 44_100, "frames" => 100}

  "fail", _args ->
    :tool_error

  _unknown, _args ->
    :unknown_tool
end

handle = fn
  %{"id" => id, "method" => "initialize"} ->
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fake-ds-sidecar", "version" => "0.1.0"}
      }
    }

  %{"id" => id, "method" => "tools/call", "params" => %{"name" => name} = params} ->
    case handle_tool.(name, Map.get(params, "arguments", %{})) do
      :tool_error ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "boom"}],
            "isError" => true
          }
        }

      :unknown_tool ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_601, "message" => "Method not found: #{name}"}
        }

      payload ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
            "isError" => false
          }
        }
    end

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
