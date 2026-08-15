defmodule Equinox.Kernel.MCPAdapterTest do
  use ExUnit.Case, async: false

  alias Equinox.Kernel.{MCPAdapter, Voicebank}

  defp mcp_config do
    %{
      mcp: %{
        command: "elixir",
        args: [
          "-pa",
          Path.join(Mix.Project.build_path(), "lib/jason/ebin"),
          Path.expand("test/support/fake_mcp_server.exs")
        ]
      }
    }
  end

  test "fetch/1：握手 + resources/read → enriched config" do
    assert {:ok, config} = MCPAdapter.fetch(mcp_config())

    assert %Voicebank{} = config.voicebank
    assert config.voicebank.id == "mcp_vb"
    assert config.voicebank.engine == :stub
    assert config.voicebank.engine_version == "1.2.3"
    assert config.voicebank.capabilities.supported_channels == [:phoneme_timing]
    assert config.voicebank.timing == %{frame_rate: 100, hop: 512}
    assert config.server_info == %{"name" => "fake-mcp", "version" => "0.1.0"}

    # mcp 连接信息原样保留（可复fetch）
    assert config.mcp == mcp_config().mcp
  end

  test "fetch/1 错误路径：缺 mcp 配置 / command 不存在" do
    assert {:error, {:invalid_mcp_config, _}} = MCPAdapter.fetch(%{})

    assert {:error, {:command_not_found, _}} =
             MCPAdapter.fetch(%{mcp: %{command: "definitely-not-a-real-command-xyz", args: []}})
  end

  test "五回调从 enriched config 纯派生" do
    {:ok, config} = MCPAdapter.fetch(mcp_config())

    assert MCPAdapter.engine_key(config) == "mcp_vb@1.2.3"
    assert MCPAdapter.timing_spec(config) == {:ok, %{frame_rate: 100, hop: 512}}

    # globals 线上列表形 → tuple 规则
    assert MCPAdapter.globals(config) == %{gender: {:range, -1.0, 1.0}}

    assert MCPAdapter.adoptables(config) == [:phoneme_timing]

    # channels 按 supported_channels 经 ChannelSpecs 构造
    assert %{phoneme_timing: %{projection: projection, target: {:port, :synth, :phoneme_timing}}} =
             MCPAdapter.channels(config)

    assert is_function(projection, 2)
  end

  test "adoptables 缺省回落 supported_channels；显式空表不回落" do
    {:ok, config} = MCPAdapter.fetch(mcp_config())

    # fake server 显式声明了 adoptables: ["phoneme_timing"]；移除后应回落
    fallback =
      put_in(
        config.voicebank.capabilities,
        Map.delete(config.voicebank.capabilities, :adoptables)
      )

    assert MCPAdapter.adoptables(fallback) == [:phoneme_timing]

    gated = put_in(config.voicebank.capabilities[:adoptables], [])
    assert MCPAdapter.adoptables(gated) == []
  end

  test "未 fetch 的裸 config 响亮报错" do
    assert_raise ArgumentError, ~r/fetch\/1/, fn -> MCPAdapter.engine_key(mcp_config()) end
  end
end
