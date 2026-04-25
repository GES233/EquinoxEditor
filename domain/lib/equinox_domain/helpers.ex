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
        k in allowed_set,
        into: %{} do
      case k do
        k when is_atom(k) -> {k, v}
        k when is_binary(k) -> {String.to_existing_atom(k), v}
      end
    end
  end

  # 仅用于 Entity
  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
