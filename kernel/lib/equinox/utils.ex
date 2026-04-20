defmodule Equinox.Utils do
  defmodule ID do
    def generate, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defmodule AttributesHelper do
    @moduledoc "因为数据的来源之一是序列化而必须的一些函数。"

    @doc "标准化 Attrs （顺便处理成 atom 或 binary ）"
    def normalize(map_or_kw, mode \\ :atom)

    def normalize(map_or_kw, :atom) do
      map_or_kw
      |> Enum.into(%{})
      |> Map.new(fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} when is_atom(k) -> {k, v}
      end)
    end

    def normalize(map_or_kw, :string) do
      map_or_kw
      |> Enum.into(%{})
      |> Map.new(fn
        {k, v} when is_binary(k) -> {k, v}
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      end)
    end
  end
end
