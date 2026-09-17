defmodule Coconut.Render.Channel do
  @moduledoc """
  Channel contract for `Coconut.Render.Resolve`.

  A channel is one data facet the engine consumes (lyric, phoneme, phoneme
  duration, pitch, ...). Channels are deliberately *not* hardcoded: any
  module implementing this behaviour can be registered in the channel map
  passed to `Coconut.Render.Resolve.run_check/3`.

  Each channel supplies:

  - `projection/2` — produces the fresh base slice for a patch's anchor
    region: a canonical term (see `Tamale.Digest`). `Tamale.Patch.resolve/2`
    digests it and compares against the patch's `base_digest` with zero
    tolerance.
  - `target/0` or `target/1` — where a resolved payload lands: a single
    `port_ref`, or a function fanning the payload out to
    `[{port_ref, value}]` pairs. `target/1` additionally receives the
    patch, for ports derived from the anchor (e.g. per-note ports like
    `{:port, note_id, :pitch}`). At least one of the two must be exported.
  - `resolve_stage/0`（可选，默认 `:static`）——`:probe` 表示 digest
    裁决交给宿主，Coconut 只做 anchor transport 并原样折叠 payload。
    该标签不要求底料来自模型输出，也不要求执行异步 probe；例如 Neume
    从谱面输入事实与声库摘要纯派生底料，在自己的 check 中裁决。
    宿主必须在消费前以 `Tamale.Patch.resolve/2` 完成这一步；挂载时需
    显式传 `:base`（`Coconut.mount/6`），`projection/2` 保持纯 workspace。
  """

  alias Coconut.Edit.{Patch, Workspace}
  alias Coconut.Render.Resolve

  @callback projection(Workspace.t(), Patch.t()) :: {:ok, term()} | {:error, term()}

  @callback target() :: Resolve.port_ref() | (term() -> [{Resolve.port_ref(), term()}])

  @callback target(Patch.t()) ::
              Resolve.port_ref() | (term() -> [{Resolve.port_ref(), term()}])

  @callback resolve_stage() :: :static | :probe

  @optional_callbacks target: 0, target: 1, resolve_stage: 0
end
