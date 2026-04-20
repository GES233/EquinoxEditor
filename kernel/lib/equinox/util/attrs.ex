defmodule Equinox.Util.Attrs do
  @moduledoc """
  数据的来源之一是序列化而必需的工具函数。
  """

  @type attributes :: map() | keyword()

  @doc "标准化 Attrs 。"
  # TODO: String.to_atom(k) 可能造成内存泄露风险
  # 需要引入 struct 的 fields 或其他手段作为可被转化为原子的白名单
  def normalize(map_or_kw) do
    map_or_kw
    |> Enum.into(%{})
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end
end
