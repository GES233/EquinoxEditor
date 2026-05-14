defmodule EquinoxDomain.Util.ID do
  @typedoc "声明 ID"
  @type t :: binary()
  @typedoc "用于说明是什么对象的 ID"
  @type t(_t) :: binary()

  @doc "动态生成新对象的 ID"
  @spec generate_id(nil | binary()) :: t()
  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
