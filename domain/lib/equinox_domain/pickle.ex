defmodule EquinoxDomain.Pickle do
  @moduledoc """
  原生对象序列化（dump/load codec）约定。

  每种类型一对 `dump/1` / `load/1`：

  - `dump(struct) :: {:ok, map()} | {:error, term()}`
  - `load(map) :: {:ok, struct()} | {:error, term()}`

  equinox 自有 struct（`Track` / `Project` / `Preset`）的 dump/load 放在模块自身；
  zongzi 自有 struct 的 codec 放在 `EquinoxDomain.Pickle.*` 下。

  ## dump 产物的允许类型

  只允许：**map、list、number、binary、atom、boolean、nil**。

  禁止 **tuple / struct / fun / pid**：tuple 一律编码为 list（如 `[a, b, c]`），
  struct 一律摊平为 map。map 键允许 atom / binary / integer
  （如 `notes_by_seq` 的整数 seq 键、Note.metadata 的 binary 键），
  其余键类型同样禁止。

  满足本约定的产物可直接 `:erlang.term_to_binary/1` 落盘，
  将来转 JSON 也只是机械转换，不需要额外 codec 层。

  ## 契约

  - Intervention 各 channel 的 Declaration 必须保证 `payload` / `snapshot`
    是可 dump 的原生对象（本 codec 对它们只做原样透传，不做深度规整）。
  - `Zongzi.Score.Tempo.Segment` 的 event context 必须是无 struct 的 plain map。
  """

  @doc "把领域 struct 摊平为仅含允许类型的 plain map。"
  @callback dump(term()) :: {:ok, map()} | {:error, term()}

  @doc "从 plain map 重建领域 struct（经各模型的 new/1 校验）。"
  @callback load(map()) :: {:ok, term()} | {:error, term()}
end
