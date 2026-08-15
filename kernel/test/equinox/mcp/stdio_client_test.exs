defmodule Equinox.Kernel.MCP.StdioClientTest do
  use ExUnit.Case, async: false

  alias Equinox.Kernel.MCP.StdioClient

  # fake server 只需 Jason 在代码路径上（kernel 自身依赖，注入其 ebin）
  defp server_args do
    [
      "-pa",
      Path.join(Mix.Project.build_path(), "lib/jason/ebin"),
      Path.expand("test/support/fake_mcp_server.exs")
    ]
  end

  defp open_client do
    {:ok, client} = StdioClient.open(command: "elixir", args: server_args())

    on_exit(fn -> StdioClient.close(client) end)

    client
  end

  test "经典握手 + ping + resources/list + resources/read" do
    client = open_client()

    assert {:ok, result} =
             StdioClient.request(client, "initialize", %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{},
               "clientInfo" => %{"name" => "equinox-test", "version" => "0.0.0"}
             })

    assert %{"protocolVersion" => "2025-06-18", "serverInfo" => %{"name" => "fake-mcp"}} = result

    assert :ok = StdioClient.notify(client, "notifications/initialized")
    assert {:ok, %{}} = StdioClient.request(client, "ping")

    assert {:ok, %{"resources" => [%{"uri" => "vb://descriptor"}]}} =
             StdioClient.request(client, "resources/list")

    assert {:ok, %{"contents" => [%{"mimeType" => "application/json", "text" => text}]}} =
             StdioClient.request(client, "resources/read", %{"uri" => "vb://descriptor"})

    assert {:ok, %{"id" => "mcp_vb", "engine_version" => "1.2.3"}} = Jason.decode(text)
  end

  test "未知方法透传 error 对象" do
    client = open_client()

    assert {:error, %{"code" => -32_601, "message" => message}} =
             StdioClient.request(client, "tools/call")

    assert message =~ "Method not found"
  end

  test "command 不存在响亮报错" do
    assert {:error, {:command_not_found, "definitely-not-a-real-command-xyz"}} =
             StdioClient.open(command: "definitely-not-a-real-command-xyz")
  end
end
