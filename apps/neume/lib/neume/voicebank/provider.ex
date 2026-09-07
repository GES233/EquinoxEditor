defmodule Neume.Voicebank.Provider do
  @moduledoc """
  声库包格式 provider 契约。

  Neume registry 只保存通用 entry 与持久化签名；目录扫描、变体构建和具体
  runtime 选择均由 provider 实现。
  """

  alias Neume.Voicebank.{Entry, Registry}

  @callback discover([Path.t()] | Path.t(), keyword()) :: {:ok, Registry.t()} | {:error, term()}
  @callback entry_from_path(Path.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  @callback prepare_modified(Entry.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
end
