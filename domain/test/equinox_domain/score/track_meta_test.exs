defmodule EquinoxDomain.Score.TrackMetaTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.PickleTestHelper
  alias EquinoxDomain.Port.Preset
  alias EquinoxDomain.Score.TrackMeta

  describe "new/1 + validate/1" do
    test "缺省值" do
      assert {:ok, meta} = TrackMeta.new()
      assert meta.mix_automation == %{}
      assert meta.gain == 1.0
      assert meta.pan == 0.0
      assert meta.mute == false
      assert meta.solo == false
      assert meta.presets == %{}
      assert meta.active_preset == nil
      assert meta.voicebank_id == nil
      assert meta.globals == %{}
      assert meta.ui_state == %{}
      assert meta.metadata == %{}
    end

    test "非法字段类型报错" do
      assert {:error, {:invalid_gain, _}} = TrackMeta.new(gain: "loud")
      assert {:error, {:invalid_pan, _}} = TrackMeta.new(pan: :left)
      assert {:error, {:invalid_mute, _}} = TrackMeta.new(mute: 1)
      assert {:error, {:invalid_solo, _}} = TrackMeta.new(solo: "yes")
      assert {:error, {:invalid_voicebank_id, _}} = TrackMeta.new(voicebank_id: 42)
      assert {:error, {:invalid_globals, _}} = TrackMeta.new(globals: [:gender])
    end

    test "presets 逐个校验" do
      {:ok, preset} = Preset.new(name: "p1", channels: %{phoneme_timing: PhantomModule})
      assert {:ok, meta} = TrackMeta.new(presets: %{"p1" => preset}, active_preset: "p1")
      assert meta.active_preset == "p1"

      assert {:error, {:invalid_preset, "bad", _}} =
               TrackMeta.new(presets: %{"bad" => %{not: "a preset"}})
    end
  end

  describe "update/2" do
    test "更新字段并复验；多余键报错" do
      {:ok, meta} = TrackMeta.new()
      assert {:ok, updated} = TrackMeta.update(meta, gain: 0.5, mute: true)
      assert updated.gain == 0.5
      assert updated.mute == true

      assert {:error, {:extra_attrs, [:nope]}} = TrackMeta.update(meta, nope: 1)
      assert {:error, {:invalid_gain, _}} = TrackMeta.update(meta, gain: nil)
    end
  end

  describe "dump/load" do
    test "往返（含 presets）" do
      {:ok, preset} =
        Preset.new(
          name: "default",
          channels: %{phoneme_timing: EquinoxDomain.Port.Channels.PhonemeTiming},
          artifact: [:phoneme_timing],
          allow_adopt: [:phoneme_timing]
        )

      {:ok, meta} =
        TrackMeta.new(
          gain: 0.8,
          pan: 0.1,
          mute: false,
          solo: true,
          presets: %{"default" => preset},
          active_preset: "default",
          voicebank_id: "qiyu_v2",
          globals: %{gender: 0.5, phoneme_mode: :auto},
          ui_state: %{"collapsed" => false},
          metadata: %{"color" => "cyan"}
        )

      {:ok, dumped} = TrackMeta.dump(meta)
      PickleTestHelper.assert_plain!(dumped)

      assert {:ok, loaded} = TrackMeta.load(dumped)
      assert loaded == meta
    end

    test "load 拒绝非 map" do
      assert {:error, {:invalid_track_meta_dump, _}} = TrackMeta.load(42)
    end
  end
end
