defmodule EquinoxDomain.Command.Editing do
  @moduledoc "可逆编辑用例。仅用于需要事务一致性或跨对象协作的操作。"

  # 修改事件
  @callback apply_command(term()) :: {:ok, term()} | {:error, term()}

  @callback undo_command(term()) :: {:ok, term()} | {:error, term()}
end
