defmodule EquinoxDomain.Rebase.Phoneme.TimingTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Rebase.Phoneme.Timing

  describe "to_patches / from_patches 互转" do
    test "转为泛型 Patch 并转回" do
      deltas = [
        %Timing{identity: "C", onset_delta_ms: 5, duration_delta_ms: 0},
        %Timing{identity: "V", onset_delta_ms: -3, duration_delta_ms: 10}
      ]

      patches = Timing.to_patches(deltas)
      assert length(patches) == 2

      back = Timing.from_patches(patches)
      assert length(back) == 2
      assert Enum.map(back, &{&1.identity, &1.onset_delta_ms, &1.duration_delta_ms}) ==
               [{"C", 5, 0}, {"V", -3, 10}]
    end
  end

  describe "reconcile/2" do
    test "音节锚定 identity 部分失配" do
      deltas = [
        %Timing{identity: "syl_la/syl/0", onset_delta_ms: 5},
        %Timing{identity: "syl_la/syl/1", onset_delta_ms: -10}
      ]

      # 歌词变更： "la" → "si"
      {:ok, surviving, conflicts} =
        Timing.reconcile(deltas, ["syl_si/syl/0", "syl_si/syl/1"])

      assert surviving == []
      assert length(conflicts) == 2
    end

    test "melisma：音节 identity 在音符级变化下存活" do
      deltas = [
        %Timing{identity: "syl_la/syl/0", onset_delta_ms: 0},
        %Timing{identity: "syl_la/syl/1", onset_delta_ms: 30}
      ]

      {:ok, surviving, conflicts} =
        Timing.reconcile(deltas, ["syl_la/syl/0", "syl_la/syl/1"])

      assert length(surviving) == 2
      assert conflicts == []
      assert Enum.any?(surviving, &(&1.identity == "syl_la/syl/1" and &1.onset_delta_ms == 30))
    end

    test "melisma 断裂：'+' → 新歌词产生冲突" do
      deltas = [%Timing{identity: "syl_la/syl/1", onset_delta_ms: 30}]

      {:ok, surviving, conflicts} =
        Timing.reconcile(deltas, ["syl_la/syl/0", "syl_ra/syl/0", "syl_ra/syl/1"])

      assert surviving == []
      assert [%{identity: "syl_la/syl/1", reason: :identity_mismatch}] = conflicts
    end

    test "opaque identity：adapter 所有的元组格式" do
      deltas = [
        %Timing{identity: {:phoneme, "n1", 0}, onset_delta_ms: 3},
        %Timing{identity: {:phoneme, "n1", 1}, onset_delta_ms: -2}
      ]

      {:ok, surviving, conflicts} = Timing.reconcile(deltas, [{:phoneme, "n1", 0}])

      assert length(surviving) == 1
      assert hd(surviving).identity == {:phoneme, "n1", 0}
      assert length(conflicts) == 1
    end
  end

  describe "apply_deltas/2" do
    test "应用 onset delta" do
      base = %{"C" => {0.0, 0.05}, "V" => {0.05, 0.10}}
      deltas = [%Timing{identity: "V", onset_delta_ms: 20}]

      result = Timing.apply_deltas(base, deltas)
      assert result["V"] == {0.07, 0.10}
    end

    test "应用 duration delta" do
      base = %{"V" => {0.05, 0.10}}
      deltas = [%Timing{identity: "V", duration_delta_ms: -30}]

      result = Timing.apply_deltas(base, deltas)
      assert result["V"] == {0.05, 0.07}
    end

    test "缺失 identity 使用默认 100ms" do
      result = Timing.apply_deltas(%{}, [%Timing{identity: "X", onset_delta_ms: 10}])
      assert result["X"] == {0.01, 0.10}
    end

    test "duration 下限为 1ms" do
      base = %{"V" => {0.0, 0.01}}
      deltas = [%Timing{identity: "V", duration_delta_ms: -100}]

      result = Timing.apply_deltas(base, deltas)
      assert elem(result["V"], 1) == 0.001
    end
  end
end
