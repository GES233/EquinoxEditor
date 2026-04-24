defmodule EquinoxDomain.Util.ID do
  def generate, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
