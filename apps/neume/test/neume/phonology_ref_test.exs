defmodule Neume.Phonology.RefTest do
  use ExUnit.Case, async: true

  alias Neume.Phonology.Ref

  # {note_id, start_tick, end_tick, 续音旗标}
  @notes [
    {"a", 0, 480, false},
    {"b", 480, 960, true},
    {"c", 960, 1440, true},
    {"d", 1920, 2400, false}
  ]

  # 与 @notes 对应的逐音符音素序列（runtime probe 形状）。
  @note_phonemes %{
    "a" => [["zh", "l"], ["zh", "a"]],
    "b" => [["zh", "a"]],
    "c" => [["zh", "a"]],
    "d" => [["zh", "m"], ["zh", "i"]]
  }

  describe "memberships/1 与 units/1" do
    test "组头 note_id 即 unit ref，成员按组内序号排序" do
      memberships = Ref.memberships(@notes)

      assert memberships["a"].head_id == "a"
      assert memberships["c"].member_index == 2
      assert memberships["d"].head_id == "d"

      assert Ref.units(memberships) == %{
               "a" => ["a", "b", "c"],
               "d" => ["d"]
             }
    end
  end

  describe "segment/2" do
    test "由成员资格派生 segment ref" do
      memberships = Ref.memberships(@notes)

      assert Ref.segment(memberships["a"], 1) == %{unit: "a", member: 0, index: 1}
      assert Ref.segment(memberships["c"], 0) == %{unit: "a", member: 2, index: 0}
      assert Ref.segment(memberships["d"], 0) == %{unit: "d", member: 0, index: 0}
    end
  end

  describe "resolve/3" do
    test "解析 unit 内任意成员的音素（含延续元音）" do
      units = @notes |> Ref.memberships() |> Ref.units()

      assert Ref.resolve(%{unit: "a", member: 0, index: 0}, units, @note_phonemes) ==
               {:ok, ["zh", "l"]}

      assert Ref.resolve(%{unit: "a", member: 2, index: 0}, units, @note_phonemes) ==
               {:ok, ["zh", "a"]}

      assert Ref.resolve(%{unit: "d", member: 0, index: 1}, units, @note_phonemes) ==
               {:ok, ["zh", "i"]}
    end

    test "任何一级解析失败都返回 tagged error，不静默选错" do
      units = @notes |> Ref.memberships() |> Ref.units()

      unknown_unit = %{unit: "zzz", member: 0, index: 0}

      assert Ref.resolve(unknown_unit, units, @note_phonemes) ==
               {:error, {:unknown_segment_ref, unknown_unit}}

      member_oob = %{unit: "a", member: 3, index: 0}

      assert Ref.resolve(member_oob, units, @note_phonemes) ==
               {:error, {:unknown_segment_ref, member_oob}}

      index_oob = %{unit: "a", member: 1, index: 1}

      assert Ref.resolve(index_oob, units, @note_phonemes) ==
               {:error, {:unknown_segment_ref, index_oob}}

      no_sequence = %{unit: "d", member: 0, index: 0}

      assert Ref.resolve(no_sequence, units, Map.delete(@note_phonemes, "d")) ==
               {:error, {:unknown_segment_ref, no_sequence}}
    end
  end

  describe "ref 漂移（组归属变化的后果，由 base 裁决兜底）" do
    test "删头晋升：旧 unit ref 失效，新 unit 以晋升者为头" do
      # 删掉头音符 "a"："b" 的旗标失去贴接对象，晋升为新组头。
      after_delete = tl(@notes)
      units = after_delete |> Ref.memberships() |> Ref.units()

      assert units == %{"b" => ["b", "c"], "d" => ["d"]}

      old_ref = %{unit: "a", member: 2, index: 0}

      assert Ref.resolve(old_ref, units, @note_phonemes) ==
               {:error, {:unknown_segment_ref, old_ref}}

      assert Ref.resolve(%{unit: "b", member: 1, index: 0}, units, @note_phonemes) ==
               {:ok, ["zh", "a"]}
    end

    test "出缝断组：续音符晋升为新组头，原 unit 只剩头部成员" do
      # "c" 移出缝隙（不再贴接 "b"），旗标失效、自成组头。
      moved =
        Enum.map(@notes, fn
          {"c", _start, _end, flag} -> {"c", 1500, 1980, flag}
          other -> other
        end)

      units = moved |> Ref.memberships() |> Ref.units()

      assert units == %{"a" => ["a", "b"], "c" => ["c"], "d" => ["d"]}

      drifted = %{unit: "a", member: 2, index: 0}

      assert Ref.resolve(drifted, units, @note_phonemes) ==
               {:error, {:unknown_segment_ref, drifted}}
    end
  end
end
