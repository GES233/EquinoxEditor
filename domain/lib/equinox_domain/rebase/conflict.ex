defmodule EquinoxDomain.Rebase.Conflict do
  @moduledoc """
  调和过程中 identity 消失的补丁。

  冲突从不被静默丢弃或应用——上层（Editor / UX）决定如何处理。
  """

  alias EquinoxDomain.Rebase.Patch

  @type t :: %__MODULE__{
          identity: Patch.identity(),
          data: term(),
          reason: :identity_mismatch
        }

  defstruct [:identity, :data, reason: :identity_mismatch]

  @doc false
  def from_patch(%Patch{identity: id, data: data}) do
    %__MODULE__{identity: id, data: data}
  end
end
