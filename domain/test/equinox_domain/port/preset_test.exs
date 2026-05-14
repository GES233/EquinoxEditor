defmodule EquinoxDomain.PortTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Port.{Preset, Declaration, AdapterRef, OperateRef}

  defp build_decl(target, shape \\ :event_sequence) do
    {:ok, adapter} = AdapterRef.new(scope_key: target, signature: "v1")
    {:ok, operate} = OperateRef.new(signature: "override")

    Declaration.new(
      scope: {:utterance, target},
      target: target,
      adapter: adapter,
      shape: shape,
      operate: operate
    )
  end

  describe "Preset.new/1" do
    test "最少参数创建" do
      {:ok, preset} = Preset.new(name: "synth_vocal")
      assert preset.name == "synth_vocal"
      assert preset.declarations == %{}
      assert preset.artifact == []
      assert preset.allow_adopt == []
    end

    test "带 declarations" do
      {:ok, decl} = build_decl("g2p")
      {:ok, preset} = Preset.new(name: "miku", declarations: %{"g2p" => decl})
      assert map_size(preset.declarations) == 1
    end

    test "declarations key == Declaration.target" do
      {:ok, decl} = build_decl("duration", :continuous)
      {:ok, preset} = Preset.new(name: "t", declarations: %{"duration" => decl})
      paired = Enum.map(preset.declarations, fn {k, v} -> {k, v.target} end)
      assert paired == [{"duration", "duration"}]
    end

    test "artifact + allow_adopt 合法时创建成功" do
      {:ok, g2p} = build_decl("g2p")
      {:ok, dur} = build_decl("duration", :continuous)

      {:ok, preset} =
        Preset.new(
          name: "ok",
          declarations: %{"g2p" => g2p, "duration" => dur},
          artifact: ["g2p"],
          allow_adopt: ["g2p"]
        )

      assert preset.artifact == ["g2p"]
      assert preset.allow_adopt == ["g2p"]
    end

    test "artifact 不在 declarations 中则拒绝" do
      {:ok, g2p} = build_decl("g2p")

      assert Preset.new(
               name: "bad",
               declarations: %{"g2p" => g2p},
               artifact: ["ghost"]
             ) == {:error, {:artifact_not_in_declarations, ["ghost"]}}
    end

    test "allow_adopt 不在 declarations 中则拒绝" do
      {:ok, g2p} = build_decl("g2p")

      assert Preset.new(
               name: "bad",
               declarations: %{"g2p" => g2p},
               artifact: ["g2p"],
               allow_adopt: ["ghost"]
             ) == {:error, {:adopt_not_in_declarations, ["ghost"]}}
    end

    test "allow_adopt 在 declarations 但不在 artifact 中则拒绝" do
      {:ok, g2p} = build_decl("g2p")
      {:ok, dur} = build_decl("duration", :continuous)

      assert Preset.new(
               name: "bad",
               declarations: %{"g2p" => g2p, "duration" => dur},
               artifact: ["g2p"],
               allow_adopt: ["duration"]
             ) == {:error, {:adopt_not_in_artifact, ["duration"]}}
    end

    test "多个错误时优先报 artifact_not_in_declarations" do
      {:ok, decl} = build_decl("g2p")

      assert Preset.new(
               name: "multi",
               declarations: %{"g2p" => decl},
               artifact: ["ghost1"],
               allow_adopt: ["ghost2"]
             ) == {:error, {:artifact_not_in_declarations, ["ghost1"]}}
    end
  end

  describe "Preset.validate/1 (struct! 单元测试)" do
    test "合法 preset" do
      {:ok, preset} = Preset.new(name: "ok")
      assert Preset.validate(preset) == {:ok, preset}
    end

    test "artifact_not_in_declarations" do
      p =
        struct!(Preset, %{
          name: "x",
          declarations: %{},
          artifact: ["x"],
          allow_adopt: [],
          metadata: %{}
        })

      assert Preset.validate(p) == {:error, {:artifact_not_in_declarations, ["x"]}}
    end

    test "adopt_not_in_declarations" do
      p =
        struct!(Preset, %{
          name: "x",
          declarations: %{},
          artifact: [],
          allow_adopt: ["x"],
          metadata: %{}
        })

      assert Preset.validate(p) == {:error, {:adopt_not_in_declarations, ["x"]}}
    end

    test "adopt_not_in_artifact" do
      p =
        struct!(Preset, %{
          name: "x",
          declarations: %{"x" => nil},
          artifact: [],
          allow_adopt: ["x"],
          metadata: %{}
        })

      assert Preset.validate(p) == {:error, {:adopt_not_in_artifact, ["x"]}}
    end
  end
end
