defmodule EquinoxDomain.Util.ID do
  @doc "声明 ID"
  @type t :: binary()
  # 用于说明是什么对象的 ID
  @type t(_t) :: binary()

  @spec generate_id(nil | binary()) :: t()
  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
