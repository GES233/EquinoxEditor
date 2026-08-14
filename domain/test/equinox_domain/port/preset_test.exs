defmodule EquinoxDomain.Port.PresetTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.PickleTestHelper
  alias EquinoxDomain.Port.Preset

  @channels %{phoneme_timing: EquinoxDomain.Port.Channels.PhonemeTiming}

  test "new/1：name 必填；channels 注册表" do
    assert {:ok, preset} = Preset.new(name: "default", channels: @channels)
    assert preset.channels == @channels

    assert {:error, {:invalid_preset_name, _}} = Preset.new(%{})
    assert {:error, {:invalid_preset_name, _}} = Preset.new(name: 42)
  end

  test "validate：artifact / allow_adopt 必须落在 channels 注册表内" do
    assert {:error, {:artifact_not_in_channels, [:pitch]}} =
             Preset.new(name: "p", channels: @channels, artifact: [:pitch])

    assert {:error, {:adopt_not_in_channels, [:pitch]}} =
             Preset.new(name: "p", channels: @channels, allow_adopt: [:pitch])

    assert {:error, {:adopt_not_in_artifact, [:phoneme_timing]}} =
             Preset.new(name: "p", channels: @channels, allow_adopt: [:phoneme_timing])

    assert {:ok, _} =
             Preset.new(
               name: "p",
               channels: @channels,
               artifact: [:phoneme_timing],
               allow_adopt: [:phoneme_timing]
             )
  end

  test "update/2 多余键报错" do
    {:ok, preset} = Preset.new(name: "p")
    assert {:error, {:extra_attrs, _}} = Preset.update(preset, declarations: %{})
  end

  test "dump/load 往返" do
    {:ok, preset} =
      Preset.new(
        name: "default",
        channels: @channels,
        artifact: [:phoneme_timing],
        allow_adopt: [:phoneme_timing],
        metadata: %{vendor: "equinox"}
      )

    {:ok, dumped} = Preset.dump(preset)
    PickleTestHelper.assert_plain!(dumped)

    assert {:ok, loaded} = Preset.load(dumped)
    assert loaded == preset
  end
end
