defmodule EquinoxAdapters.UTAUCompatTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.Voicebank
  alias EquinoxAdapters.UTAUCompat

  @fixture Path.expand("../fixtures/utau_cv", __DIR__)

  test "load/1：解析 CV 声库目录为 engines 注册表条目" do
    assert {:ok, {UTAUCompat, %{voicebank: %Voicebank{} = vb}}} = UTAUCompat.load(@fixture)

    assert vb.id == "Test CV Voicebank"
    assert vb.engine == :utau
    assert vb.engine_version =~ ~r/^[0-9a-f]{12}$/
    assert vb.models == %{oto: "oto.ini", prefix_map: "prefix.map"}
    assert vb.timing == %{}

    assert vb.capabilities.supported_channels == [:curve]
    assert vb.capabilities.supported_params == [:pitch]

    assert [%{tone: "C4", prefix: "", suffix: ""}, %{tone: "C#4", prefix: "", suffix: "_C4"}] =
             vb.capabilities.subbanks

    # oto 条目：float 毫秒、负 cutoff 保留符号、空字段按 0
    assert [a, ka, n] = vb.dictionary.aliases

    assert %{
             alias: "あ",
             file: "あ.wav",
             offset: 10.5,
             consonant: 80.0,
             cutoff: -120.0,
             preutterance: 45.0,
             overlap: 20.0
           } = a

    assert ka.preutterance == 50.25
    assert n.preutterance == 0.0
    assert n.overlap == 15.0
  end

  test "load/1：缺 oto.ini 响亮报错" do
    assert {:error, {:oto_not_found, path}} =
             UTAUCompat.load(Path.expand("../fixtures/nope", __DIR__))

    assert path =~ "oto.ini"
  end

  test "五回调（拼接式边界：无帧网格、无 adoptables、flags 作 globals）" do
    {:ok, {UTAUCompat, config}} = UTAUCompat.load(@fixture)

    assert UTAUCompat.engine_key(config) =~ ~r/^Test CV Voicebank@[0-9a-f]{12}$/
    assert UTAUCompat.timing_spec(config) == {:error, :no_frame_grid}
    assert UTAUCompat.adoptables(config) == []

    assert UTAUCompat.globals(config) == %{
             g: {:range, -100, 100},
             B: {:range, 0, 100},
             t: {:range, -1200, 1200},
             Y: {:range, 0, 100},
             P: {:range, 0, 100}
           }

    # 曲线 spec 是透传模态（D1）：target 原样返回控制点 payload
    assert %{curve: %{projection: projection, target: target}} = UTAUCompat.channels(config)
    assert is_function(projection, 2)

    payload = %{param: :pitch, adapter: "Elixir.X", points: []}
    assert target.(payload, :fake_request) == [{{:port, :synth, :pitch}, payload}]
  end

  test "engine_key 随 oto 内容变化（内容戳纪律，D2）" do
    {:ok, {UTAUCompat, config}} = UTAUCompat.load(@fixture)

    other =
      put_in(config.voicebank.engine_version, "deadbeef0000")

    refute UTAUCompat.engine_key(config) == UTAUCompat.engine_key(other)
  end
end
