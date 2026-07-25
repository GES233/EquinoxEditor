ExUnit.start()

defmodule EquinoxDomain.PickleTestHelper do
  @moduledoc """
  dump 产物的「允许类型」递归断言。

  只允许 map / list / number / binary / atom / boolean / nil
  （map 键限 atom / binary / number）；任何 tuple / struct / fun /
  pid / port / reference 直接 fail。所有 dump 测试都应过一遍。
  """

  import ExUnit.Assertions

  @doc "递归断言 term 是 dump-safe 的 plain 数据，否则 flunk。"
  def assert_plain!(term), do: check!(term)

  defp check!(%_{} = struct), do: flunk("dump 产物含 struct：#{inspect(struct)}")

  defp check!(%{} = map) do
    Enum.each(map, fn {key, value} ->
      check_key!(key)
      check!(value)
    end)
  end

  defp check!(list) when is_list(list), do: Enum.each(list, &check!/1)

  defp check!(term) when is_number(term) or is_binary(term) or is_atom(term), do: :ok

  defp check!(term), do: flunk("dump 产物含不允许的类型：#{inspect(term)}")

  defp check_key!(key) when is_atom(key) or is_binary(key) or is_number(key), do: :ok
  defp check_key!(key), do: flunk("dump 产物含不允许的 map 键：#{inspect(key)}")
end
