defmodule EquinoxDomain.Util.ID do
  @type t :: binary()

  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
