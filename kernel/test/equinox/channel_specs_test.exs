defmodule Equinox.Kernel.ChannelSpecsTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.ChannelSpecs

  test ":curve + timing: :none → 透传 spec（payload 原样落 {:port, :synth, param}）" do
    assert {:ok, spec} = ChannelSpecs.build(:curve, "vb@1", timing: :none)
    assert is_function(spec.projection, 2)

    payload = %{
      param: :pitch,
      adapter: "Elixir.Coconut.Curve.Adapter.Bezier",
      points: [%{tick: 0, value: 60.0, handle_left: nil, handle_right: nil}]
    }

    assert spec.target.(payload, :fake_request) == [{{:port, :synth, :pitch}, payload}]
  end

  test ":curve 缺 timing 报 missing_timing；未知 channel 报 unknown_channel" do
    assert {:error, :missing_timing} = ChannelSpecs.build(:curve, "vb@1")
    assert {:error, {:unknown_channel, :nope}} = ChannelSpecs.build(:nope, "vb@1")
  end

  test ":phoneme_timing spec 形状" do
    assert {:ok, %{projection: projection, target: {:port, :synth, :phoneme_timing}}} =
             ChannelSpecs.build(:phoneme_timing, "vb@1")

    assert is_function(projection, 2)
  end
end
