defmodule EquinoxDomain.Helpers do
  @doc "创建动态 ID 。"
  # 先这么用着，后面再进行升级。
  def dynamic_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  @doc "标准化序列数据的工具函数。"
  def normalize_attrs(map_or_kw, maybe_namespace) do
    allowed_set =
      MapSet.new(maybe_namespace, fn
        k when is_atom(k) ->
          Atom.to_string(k)

        k when is_binary(k) ->
          k

        other ->
          raise ArgumentError, "namespace key must be atom or string, got: #{inspect(other)}"
      end)

    for {k, v} <- map_or_kw,
        key_str = if(is_atom(k), do: Atom.to_string(k), else: k),
        key_str in allowed_set,
        into: %{} do
      {String.to_existing_atom(key_str), v}
    end
  end
end
