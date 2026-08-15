defmodule Equinox.Kernel.VoicebankTest do
  use ExUnit.Case, async: true

  alias Equinox.Kernel.Voicebank

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{id: "qiyu_v2", engine: :diffsinger, engine_version: "0.9.1"},
      overrides
    )
  end

  describe "new/1 + validate/1" do
    test "必填三元组 + 缺省载荷" do
      assert {:ok, vb} = Voicebank.new(base_attrs())
      assert vb.id == "qiyu_v2"
      assert vb.engine == :diffsinger
      assert vb.engine_version == "0.9.1"
      assert vb.models == %{}
      assert vb.dictionary == %{}
      assert vb.capabilities == %{}
      assert vb.timing == %{}
    end

    test "必填缺失 / 类型非法报错" do
      assert {:error, {:invalid_id, nil}} = Voicebank.new(Map.delete(base_attrs(), :id))
      assert {:error, {:invalid_id, ""}} = Voicebank.new(base_attrs(%{id: ""}))

      assert {:error, {:invalid_engine, "diffsinger"}} =
               Voicebank.new(base_attrs(%{engine: "diffsinger"}))

      assert {:error, {:invalid_engine_version, nil}} =
               Voicebank.new(base_attrs(%{engine_version: nil}))

      assert {:error, {:invalid_models, _}} = Voicebank.new(base_attrs(%{models: []}))
      assert {:error, {:invalid_timing, _}} = Voicebank.new(base_attrs(%{timing: 100}))
    end

    test "capabilities 消费键须为 atom 列表；timing 帧网格键须为正整数" do
      assert {:error, {:invalid_capabilities, {:supported_channels, _}}} =
               Voicebank.new(
                 base_attrs(%{capabilities: %{supported_channels: ["phoneme_timing"]}})
               )

      assert {:error, {:invalid_capabilities, {:supported_params, :pitch}}} =
               Voicebank.new(base_attrs(%{capabilities: %{supported_params: :pitch}}))

      assert {:error, {:invalid_timing, {:frame_rate, 0}}} =
               Voicebank.new(base_attrs(%{timing: %{frame_rate: 0}}))

      assert {:error, {:invalid_timing, {:hop, 1.5}}} =
               Voicebank.new(base_attrs(%{timing: %{hop: 1.5}}))

      assert {:ok, _vb} =
               Voicebank.new(
                 base_attrs(%{
                   capabilities: %{
                     pitch_range: 40..80,
                     supported_channels: [:phoneme_timing],
                     supported_params: [:pitch, :energy]
                   },
                   timing: %{frame_rate: 100, hop: 512}
                 })
               )
    end
  end

  test "engine_key/1 是 id@engine_version 版本戳" do
    {:ok, vb} = Voicebank.new(base_attrs())
    assert Voicebank.engine_key(vb) == "qiyu_v2@0.9.1"
  end

  describe "dump/load" do
    test "往返" do
      {:ok, vb} =
        Voicebank.new(
          base_attrs(%{
            models: %{acoustic: "models/acoustic.onnx", vocoder: "models/nsf_hifigan.bin"},
            dictionary: %{phonemes: ["a", "i", "SP"], languages: [:zh, :ja]},
            capabilities: %{supported_channels: [:phoneme_timing]},
            timing: %{frame_rate: 100, hop: 512}
          })
        )

      assert {:ok, dumped} = Voicebank.dump(vb)
      assert is_map(dumped)
      assert {:ok, loaded} = Voicebank.load(dumped)
      assert loaded == vb
    end

    test "load 拒绝非 map / 非法载荷" do
      assert {:error, {:invalid_voicebank_dump, 42}} = Voicebank.load(42)
      assert {:error, {:invalid_id, nil}} = Voicebank.load(%{})
    end
  end
end
