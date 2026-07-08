defmodule EquinoxDomain.Rebase do
  @moduledoc """
  基于 identity 的补丁调和——当上游重新计算其 identity 序列时（歌词变更、模型升级），
  判断哪些用户补丁存活、哪些变为冲突。

  ## 示例

      iex> patches = EquinoxDomain.Rebase.Patch.new_many([{"C", 5}, {"V1", -3}, {"V2", 2}])
      iex> {:ok, surviving, conflicts} = EquinoxDomain.Rebase.reconcile(patches, ["C", "V3", "V2"])
      iex> Enum.map(surviving, & &1.identity)
      ["C", "V2"]
      iex> Enum.map(conflicts, & &1.identity)
      ["V1"]

  identity 可以是任意 term——字符串、原子、元组。生成 identity 的 adapter 拥有其 schema 定义权。
  """

  alias EquinoxDomain.Rebase.{Patch, Conflict}

  @doc """
  将补丁列表与新的 identity 列表进行调和。

  返回 `{:ok, surviving_patches, conflicts}`。
  """
  @spec reconcile([Patch.t()], [Patch.identity()]) :: {:ok, [Patch.t()], [Conflict.t()]}
  def reconcile(patches, new_identities) when is_list(patches) and is_list(new_identities) do
    id_set = MapSet.new(new_identities)

    {surviving, conflicts} =
      Enum.reduce(patches, {[], []}, fn %Patch{identity: id} = patch, {surv, con} ->
        if MapSet.member?(id_set, id) do
          {[patch | surv], con}
        else
          {surv, [Conflict.from_patch(patch) | con]}
        end
      end)

    {:ok, Enum.reverse(surviving), Enum.reverse(conflicts)}
  end

  @doc """
  同 `reconcile/2`，但不包裹 `:ok` 元组，直接返回 `{surviving, conflicts}`。
  """
  @spec reconcile!([Patch.t()], [Patch.identity()]) :: {[Patch.t()], [Conflict.t()]}
  def reconcile!(patches, new_identities) do
    {:ok, surviving, conflicts} = reconcile(patches, new_identities)
    {surviving, conflicts}
  end
end
