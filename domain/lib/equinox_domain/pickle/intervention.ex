defmodule EquinoxDomain.Pickle.Intervention do
  @moduledoc """
  `Zongzi.Intervention` 的原生对象 codec。

  - `anchor` 三元组 → 三元素 list（nil 保留）；非 tuple 锚原样透传。
  - `strategy` — nil 原样；`{mod, opts}` → `[mod, opts_map]`
    （opts 是 struct 时 `Map.from_struct` 摊平，load 回来是 plain map——
    zongzi 各 Strategy 的 rebase 本就兼容 map opts）。
  - `declaration` 模块 atom 直出。
  - `payload` / `snapshot` 原样透传——契约（见 `EquinoxDomain.Pickle`）要求
    Declaration 保证它们是 plain 对象。

  load 经 `Zongzi.Intervention.new/1` 重建（校验生效）。
  """

  @behaviour EquinoxDomain.Pickle

  alias Zongzi.Intervention

  @impl true
  def dump(%Intervention{} = int) do
    {:ok,
     %{
       id: int.id,
       channel: int.channel,
       anchor: dump_anchor(int.anchor),
       payload: int.payload,
       snapshot: int.snapshot,
       strategy: dump_strategy(int.strategy),
       declaration: int.declaration
     }}
  end

  @impl true
  def load(%{} = data) do
    data
    |> Map.update(:anchor, nil, &load_anchor/1)
    |> Map.update(:strategy, nil, &load_strategy/1)
    |> Intervention.new()
  end

  defp dump_anchor(anchor) when is_tuple(anchor), do: Tuple.to_list(anchor)
  defp dump_anchor(anchor), do: anchor

  defp load_anchor(anchor) when is_list(anchor), do: List.to_tuple(anchor)
  defp load_anchor(anchor), do: anchor

  defp dump_strategy(nil), do: nil
  defp dump_strategy({mod, %_{} = opts}), do: [mod, Map.from_struct(opts)]
  defp dump_strategy({mod, opts}), do: [mod, opts]

  defp load_strategy(nil), do: nil
  defp load_strategy([mod, opts]) when is_atom(mod), do: {mod, opts}
  defp load_strategy(other), do: other
end
