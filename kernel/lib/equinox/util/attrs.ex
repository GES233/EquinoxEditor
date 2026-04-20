defmodule Equinox.Util.Attrs do
  @moduledoc "因为数据的来源之一是序列化而必需的一些函数。"

  @type attributes :: map() | keyword()

  @doc "标准化 Attrs 。"
  def normalize(map_or_kw) do
    map_or_kw
    |> Enum.into(%{})
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end
end
