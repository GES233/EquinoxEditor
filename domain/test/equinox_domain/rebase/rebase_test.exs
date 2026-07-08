defmodule EquinoxDomain.RebaseTest do
  use ExUnit.Case, async: true

  alias EquinoxDomain.Rebase.{Patch, Conflict}

  describe "reconcile/2" do
    test "部分匹配：部分存活，部分成为孤儿" do
      patches = Patch.new_many([{"C", 5}, {"V1", -3}, {"V2", 2}])
      new_ids = ["C", "V3", "V2"]

      assert {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, new_ids)

      assert length(surviving) == 2
      assert Enum.any?(surviving, &match?(%Patch{identity: "C", data: 5}, &1))
      assert Enum.any?(surviving, &match?(%Patch{identity: "V2", data: 2}, &1))

      assert length(conflicts) == 1
      assert [%Conflict{identity: "V1", data: -3, reason: :identity_mismatch}] = conflicts
    end

    test "全部匹配：无孤儿" do
      patches = Patch.new_many([{"C", 5}])
      assert {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, ["C", "V1"])
      assert length(surviving) == 1
      assert conflicts == []
    end

    test "无匹配：全部成为孤儿" do
      patches = Patch.new_many([{"C", 5}, {"V1", -3}])
      assert {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, ["X", "Y"])
      assert surviving == []
      assert length(conflicts) == 2
    end

    test "空补丁列表" do
      assert {:ok, [], []} = EquinoxDomain.Rebase.reconcile([], ["C", "V1"])
    end

    test "空 identity 列表：全部成为孤儿" do
      patches = Patch.new_many([{"C", 5}])
      assert {:ok, [], [%Conflict{identity: "C"}]} = EquinoxDomain.Rebase.reconcile(patches, [])
    end

    test "identity 类型：字符串、原子、元组" do
      patches = [
        Patch.new("str", 1),
        Patch.new(:atom, 2),
        Patch.new({:tuple, :a}, 3)
      ]

      {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, ["str", {:tuple, :a}])

      assert length(surviving) == 2
      assert length(conflicts) == 1
      assert hd(conflicts).identity == :atom
    end

    test "顺序保持不变" do
      patches = Patch.new_many([{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}])

      {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, ["a", "c"])

      assert Enum.map(surviving, & &1.identity) == ["a", "c"]
      assert Enum.map(conflicts, & &1.identity) == ["b", "d"]
    end
  end

  describe "reconcile!/2" do
    test "不包裹 :ok 元组" do
      patches = Patch.new_many([{:keep, 1}, {:drop, 2}])
      {surviving, conflicts} = EquinoxDomain.Rebase.reconcile!(patches, [:keep])

      assert length(surviving) == 1
      assert length(conflicts) == 1
    end
  end
end
