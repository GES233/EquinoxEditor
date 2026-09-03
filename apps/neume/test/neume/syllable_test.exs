defmodule Neume.SyllableTest do
  use ExUnit.Case, async: true

  alias Neume.Syllable

  describe "flagged?/1" do
    test "识别显式续音旗标" do
      assert Syllable.flagged?(%{"melisma" => "continue"})
      refute Syllable.flagged?(%{"melisma" => "other"})
      refute Syllable.flagged?(%{})
      refute Syllable.flagged?(nil)
    end
  end

  describe "derive_groups/1" do
    test "无旗标时每个音符自成组头" do
      assert [first, second] =
               Syllable.derive_groups([
                 {"a", 0, 480, false},
                 {"b", 480, 960, false}
               ])

      assert %{head_id: "a", member_index: 0, continuation?: false} = first
      assert %{head_id: "b", member_index: 0, continuation?: false} = second
    end

    test "贴接的续音旗标并入前音符所在组" do
      assert [_head, member, tail] =
               Syllable.derive_groups([
                 {"a", 0, 480, false},
                 {"b", 480, 960, true},
                 {"c", 960, 1440, true}
               ])

      assert %{head_id: "a", member_index: 1, continuation?: true} = member
      assert %{head_id: "a", member_index: 2, continuation?: true} = tail
    end

    test "链式续音跟随组头而非直接前驱" do
      assert [_, _, third] =
               Syllable.derive_groups([
                 {"a", 0, 480, false},
                 {"b", 480, 960, true},
                 {"c", 960, 1440, true}
               ])

      assert third.head_id == "a"
    end

    test "间隙使旗标失效，音符晋升为新组头（移动出缝断组）" do
      assert [_head, promoted] =
               Syllable.derive_groups([
                 {"a", 0, 480, false},
                 {"b", 960, 1440, true}
               ])

      assert %{head_id: "b", member_index: 0, continuation?: false} = promoted
    end

    test "首音符的旗标无效（删头自动晋升）" do
      assert [promoted, member] =
               Syllable.derive_groups([
                 {"b", 480, 960, true},
                 {"c", 960, 1440, true}
               ])

      assert %{head_id: "b", continuation?: false} = promoted
      assert %{head_id: "b", member_index: 1, continuation?: true} = member
    end

    test "贴接到普通音符中间时续音挂到该音符的组" do
      assert [_a, x, b] =
               Syllable.derive_groups([
                 {"a", 0, 480, false},
                 {"x", 480, 720, false},
                 {"b", 720, 960, true}
               ])

      assert %{head_id: "x", member_index: 0} = x
      assert %{head_id: "x", member_index: 1, continuation?: true} = b
    end
  end
end
