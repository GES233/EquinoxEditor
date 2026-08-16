defmodule EquinoxAdapters.StubTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.Voicebank
  alias EquinoxAdapters.Stub

  @flat %{voicebank_id: "ui_stub", engine_version: "0.1.0", channels: [:phoneme_timing, :curve]}

  test "engine_key：平铺键为 id@version" do
    assert Stub.engine_key(@flat) == "ui_stub@0.1.0"
  end

  test "channels：按声明供给 spec（projection 一元 + target）" do
    specs = Stub.channels(@flat)

    assert Map.keys(specs) |> Enum.sort() == [:curve, :phoneme_timing]
    assert is_function(specs.phoneme_timing.projection, 2)
    assert specs.phoneme_timing.target == {:port, :synth, :phoneme_timing}
    assert is_function(specs.curve.projection, 2)
    # 曲线为 arity-2 fan-out（借窗口上下文光栅化）
    assert is_function(specs.curve.target, 2)
  end

  test "timing_spec / globals / adoptables 缺省与覆写" do
    assert Stub.timing_spec(%{}) == {:ok, %{frame_rate: 100, hop: 512}}
    assert Stub.globals(%{}) == %{}
    assert Stub.adoptables(%{}) == [:phoneme_timing]

    config = %{globals: %{gain: {:range, 0.0, 1.0}}, adoptables: [:phoneme_timing, :curve]}
    assert Stub.globals(config) == %{gain: {:range, 0.0, 1.0}}
    assert Stub.adoptables(config) == [:phoneme_timing, :curve]
  end

  test "声库描述符优先于平铺键" do
    {:ok, vb} =
      Voicebank.new(
        id: "desc_vb",
        engine: :stub,
        engine_version: "9.9.9",
        capabilities: %{supported_channels: [:phoneme_timing], supported_params: []},
        timing: %{frame_rate: 50, hop: 256}
      )

    config = Map.put(@flat, :voicebank, vb)

    assert Stub.engine_key(config) == "desc_vb@9.9.9"
    assert Stub.channels(config) |> Map.keys() == [:phoneme_timing]
    assert Stub.timing_spec(config) == {:ok, %{frame_rate: 50, hop: 256}}
  end
end
