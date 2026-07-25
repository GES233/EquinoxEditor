defmodule EquinoxDomain.Port.Declarations.PhonemeTimingTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias Zongzi.Intervention
  alias Zongzi.Score.Note

  # 投影值是 [onset_sec, duration_sec] 二元 list（plain，满足 dump-safe 契约）
  @projection %{"C" => [0.0, 0.05], "V" => [0.05, 0.10]}

  defp int(overrides \\ []) do
    %Intervention{
      id: "iv_test",
      channel: :phoneme_timing,
      anchor: {nil, 1, nil},
      payload: %{
        range: [0, 480],
        deltas: [%{identity: "V", onset_delta_ms: 20, duration_delta_ms: 0}]
      },
      snapshot: %{"V" => [0.05, 0.10]},
      strategy: nil,
      declaration: PhonemeTiming
    }
    |> struct(overrides)
  end

  test "channel/0" do
    assert PhonemeTiming.channel() == :phoneme_timing
  end

  describe "scope/2" do
    test "把 list 形态的 payload.range 归一为 tick 二元组（喂 zongzi normalize_scope）" do
      assert PhonemeTiming.scope(int(payload: %{range: [960, 1440], deltas: []}), %{}) ==
               {960, 1440}
    end
  end

  describe "snapshot/2" do
    test "按 deltas 的 identity 对投影做 Map.take" do
      assert PhonemeTiming.snapshot(@projection, int()) == %{"V" => [0.05, 0.10]}
    end

    test "投影中缺失的 identity 不进 snapshot" do
      int =
        int(
          payload: %{
            range: [0, 480],
            deltas: [%{identity: "X", onset_delta_ms: 1, duration_delta_ms: 0}]
          }
        )

      assert PhonemeTiming.snapshot(@projection, int) == %{}
    end
  end

  describe "resolve/2" do
    test "snapshot 一致时把 deltas 应用到 fresh_projection" do
      assert {:ok, resolved} = PhonemeTiming.resolve(int(), @projection)

      # 移植旧 apply_deltas 场景：V onset +20ms → [0.07, 0.10]
      assert resolved["V"] == [0.07, 0.10]
      # 未被 delta 覆盖的 identity 原样保留
      assert resolved["C"] == [0.0, 0.05]
    end

    test "duration 下限 1ms 且结果 round 到 4 位小数" do
      int =
        int(
          payload: %{
            range: [0, 480],
            deltas: [%{identity: "V", onset_delta_ms: 0, duration_delta_ms: -999}]
          },
          snapshot: %{"V" => [0.05, 0.10]}
        )

      assert {:ok, resolved} = PhonemeTiming.resolve(int, @projection)
      assert resolved["V"] == [0.05, 0.001]
    end

    test "snapshot 不符时 conflict" do
      fresh = %{"C" => [0.0, 0.05], "V" => [0.06, 0.10]}

      assert {:conflict, {:snapshot_mismatch, snapshot, current}} =
               PhonemeTiming.resolve(int(), fresh)

      assert snapshot == %{"V" => [0.05, 0.10]}
      assert current == %{"V" => [0.06, 0.10]}
    end
  end

  describe "on_rebase/4" do
    test "三元组锚且 notes_by_seq 有当前 note 时刷新 payload.range（list 形态）" do
      {:ok, note} = Note.new(id: "Note_x", start_tick: 1200, duration_tick: 480)
      context = %{notes_by_seq: %{1 => note}}

      assert {:ok, updated} = PhonemeTiming.on_rebase(int(), %{}, nil, context)
      assert updated.payload.range == [1200, 1680]
      # deltas 不动
      assert updated.payload.deltas == int().payload.deltas
    end

    test "notes_by_seq 缺当前 note 时原样返回" do
      assert {:ok, unchanged} = PhonemeTiming.on_rebase(int(), %{}, nil, %{notes_by_seq: %{}})
      assert unchanged == int()
    end

    test "context 无 notes_by_seq 时原样返回" do
      assert {:ok, unchanged} = PhonemeTiming.on_rebase(int(), %{}, nil, %{})
      assert unchanged == int()
    end

    test "非三元组锚原样返回" do
      int = int(anchor: {:some_other_anchor, 1})
      assert {:ok, unchanged} = PhonemeTiming.on_rebase(int, %{}, nil, %{notes_by_seq: %{}})
      assert unchanged == int
    end
  end
end
