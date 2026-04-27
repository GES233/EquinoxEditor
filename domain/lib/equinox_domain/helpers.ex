defmodule EquinoxDomain.Helpers do
  # 适用于 Entity 以及 VO
  def normalize_attrs(map_or_kw, fields) do
    allowed_set =
      MapSet.new(fields, fn
        {k, _} when is_atom(k) ->
          k

        k when is_atom(k) ->
          k

        other ->
          raise ArgumentError, "field must be atom or {atom, default}, got: `#{inspect(other)}`"
      end)

    for {k, v} <- map_or_kw,
        normalized_key = normalize_key(k),
        normalized_key in allowed_set,
        into: %{} do
      {normalized_key, v}
    end
  end

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_key(_), do: nil

  # 仅用于 Entity
  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
