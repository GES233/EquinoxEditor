defmodule EquinoxAdapters.UTAUDiffSingerCompatTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.Voicebank
  alias EquinoxAdapters.UTAUDiffSingerCompat, as: DSCompat
  alias EquinoxDomain.Command.RenderRequest

  @yaml_fixture Path.expand("../fixtures/utau_diffsinger", __DIR__)
  @json_fixture Path.expand("../fixtures/utau_diffsinger_json", __DIR__)

  test "load/1（dsconfig.yaml）：帧网格 float、模型路径、params 推导" do
    assert {:ok, {DSCompat, %{voicebank: %Voicebank{} = vb}}} = DSCompat.load(@yaml_fixture)

    assert vb.id == "utau_diffsinger"
    assert vb.engine == :utau_diffsinger
    assert vb.engine_version =~ ~r/^[0-9a-f]{12}$/

    # 帧网格：44100/512 非整数帧率（D3）
    assert vb.timing.frame_rate == 44100 / 512
    assert vb.timing.hop == 512

    assert vb.models == %{
             acoustic: "acoustic.onnx",
             vocoder: "nsf_hifigan",
             dur: "dsdur/dur.onnx",
             linguistic: "dsdur/linguistic.onnx",
             pitch: "dspitch/pitch.onnx",
             variance: "dsvariance/variance.onnx"
           }

    assert vb.dictionary.phonemes == ["AP", "SP", "a", "i", "sh"]

    assert vb.capabilities.supported_channels == [:phoneme_timing, :curve]
    assert vb.capabilities.supported_params == [:pitch, :energy, :breathiness, :tension]
  end

  test "load/1（dsconfig.json 回退）：缺省推导与整除帧率" do
    assert {:ok, {DSCompat, %{voicebank: vb}}} = DSCompat.load(@json_fixture)

    # 48000/480 = 100.0；无 pitch/variance 且 predict_* 显式 false → 无 params
    assert vb.timing == %{frame_rate: 100.0, hop: 480}
    assert vb.models == %{acoustic: "acoustic.onnx", vocoder: "nsf_hifigan"}
    assert vb.dictionary.phonemes == []
    assert vb.capabilities.supported_params == []
  end

  test "load/1：缺 dsconfig 响亮报错" do
    assert {:error, {:dsconfig_not_found, _}} =
             DSCompat.load(Path.expand("../fixtures/nope", __DIR__))
  end

  test "五回调（帧网格模态 + globals 规则形状 + adoptables）" do
    {:ok, {DSCompat, config}} = DSCompat.load(@yaml_fixture)

    assert DSCompat.engine_key(config) =~ ~r/^utau_diffsinger@[0-9a-f]{12}$/
    assert DSCompat.timing_spec(config) == {:ok, %{frame_rate: 44100 / 512, hop: 512}}
    assert DSCompat.adoptables(config) == [:phoneme_timing, :curve]

    # key_shift 取 augmentationArgs range；speaker 为 enum（去扩展名 atom）
    assert DSCompat.globals(config) == %{
             key_shift: {:range, -5.0, 5.0},
             speaker: {:enum, [:speaker_a, :speaker_b]}
           }

    # channels：两个 spec 都是 arity-2 target——phoneme_timing 走 DiffSinger
    # 窗口打包扇出（Packaging），curve 是光栅化模态（非透传）
    assert %{
             phoneme_timing: %{target: pt_target},
             curve: %{target: target}
           } =
             DSCompat.channels(config)

    assert is_function(pt_target, 2)
    assert is_function(target, 2)
  end

  test "globals 缺省：无 augmentationArgs / speakers 时" do
    {:ok, {DSCompat, config}} = DSCompat.load(@json_fixture)

    assert DSCompat.globals(config) == %{key_shift: {:range, -12, 12}}
  end

  test "与 UTAU 的曲线模态对拍：光栅化 vs 透传（D1 双模态边界）" do
    {:ok, {DSCompat, ds_config}} = DSCompat.load(@yaml_fixture)

    {:ok, {_, utau_config}} =
      EquinoxAdapters.UTAUCompat.load(Path.expand("../fixtures/utau_cv", __DIR__))

    payload = %{
      param: :pitch,
      adapter: "Elixir.Coconut.Curve.Adapter.CatmullRom",
      points: [
        %{tick: 0, value: 60.0, handle_left: nil, handle_right: nil},
        %{tick: 480, value: 61.0, handle_left: nil, handle_right: nil}
      ]
    }

    # UTAU（无帧网格）：payload 原样透传
    utau_target =
      utau_config
      |> EquinoxAdapters.UTAUCompat.channels()
      |> Map.fetch!(:curve)
      |> Map.fetch!(:target)

    assert [{{:port, :synth, :pitch}, ^payload}] = utau_target.(payload, :fake_request)

    # DiffSinger（帧网格）：target 调 CurveRaster——空 tempo 切片走
    # rasterize 的 {:error, :empty_tempo_segments} → 目标闭包 {:ok, _} 匹配
    # 失败（MatchError），证明它不是透传
    ds_target = ds_config |> DSCompat.channels() |> Map.fetch!(:curve) |> Map.fetch!(:target)
    {:ok, empty_request} = RenderRequest.new(track_id: "t", tempo_segments: [], tpqn: 480)

    assert_raise MatchError, fn -> ds_target.(payload, empty_request) end
  end
end
