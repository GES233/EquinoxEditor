defmodule EquinoxDomain.Pickle.InterventionTest do
  use ExUnit.Case, async: true

  import EquinoxDomain.PickleTestHelper

  alias EquinoxDomain.Pickle
  alias EquinoxDomain.Port.Declarations.PhonemeTiming
  alias Zongzi.Anchor.NoteTriplet
  alias Zongzi.Intervention

  defp intervention(overrides \\ %{}) do
    {:ok, int} =
      Intervention.new(
        Map.merge(
          %{
            id: "iv_1",
            channel: :phoneme_timing,
            anchor: {nil, 1, 2},
            payload: %{
              range: [0, 480],
              deltas: [%{identity: "V", onset_delta_ms: 20, duration_delta_ms: 0}]
            },
            snapshot: %{"V" => [0.05, 0.10]},
            declaration: PhonemeTiming
          },
          overrides
        )
      )

    int
  end

  test "dump/load round-trip 结构相等且产物 plain（anchor 三元组 → list）" do
    int = intervention()

    assert {:ok, dump} = Pickle.Intervention.dump(int)
    assert_plain!(dump)

    assert dump.anchor == [nil, 1, 2]
    assert dump.strategy == nil
    assert dump.declaration == PhonemeTiming
    assert dump.payload == int.payload
    assert dump.snapshot == int.snapshot

    assert {:ok, loaded} = Pickle.Intervention.load(dump)
    assert loaded == int
  end

  test "strategy {mod, map_opts} round-trip 结构相等" do
    int = intervention(%{strategy: {NoteTriplet, %{match_threshold: 1}}})

    assert {:ok, dump} = Pickle.Intervention.dump(int)
    assert_plain!(dump)
    assert dump.strategy == [NoteTriplet, %{match_threshold: 1}]

    assert {:ok, loaded} = Pickle.Intervention.load(dump)
    assert loaded == int
  end

  test "strategy {mod, struct_opts} 摊平为 map，load 还原为 plain map opts" do
    int = intervention(%{strategy: {NoteTriplet, %NoteTriplet.Options{match_threshold: 1}}})

    assert {:ok, dump} = Pickle.Intervention.dump(int)
    assert_plain!(dump)

    assert dump.strategy == [
             NoteTriplet,
             %{match_threshold: 1, allow_follow_merge: false, orphan_direction: :never}
           ]

    assert {:ok, loaded} = Pickle.Intervention.load(dump)

    assert loaded.strategy ==
             {NoteTriplet,
              %{match_threshold: 1, allow_follow_merge: false, orphan_direction: :never}}

    # struct opts 之外字段不变
    assert loaded.anchor == int.anchor
    assert loaded.payload == int.payload
  end

  test "load 缺 declaration 经 Intervention.new/1 校验报错" do
    int = intervention()
    assert {:ok, dump} = Pickle.Intervention.dump(int)

    assert {:error, {:declaration_invalid, nil}} =
             Pickle.Intervention.load(Map.delete(dump, :declaration))
  end
end
