defmodule EquinoxDomain.Command.Editing do
  # 修改事件
  @callback apply_command(term()) :: {:ok, term()} | {:error, term()}

  @callback undo_command(term()) :: {:ok, term()} | {:error, term()}
end
