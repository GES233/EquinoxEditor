defmodule Neume.Pin.Semantics do
  @moduledoc """
  pin 语义 behaviour（`design-2026-09-pin-carriers` §4）。

  第一版保持"一个 channel 模块同时实现 Coconut transport
  （`Coconut.Render.Channel`）与 Neume 语义（本 behaviour）"的形状，
  不引入额外注册表。

  约束：

  - `describe/1` 必须按 payload 分派，不能用模块级 `carrier/0`——同一
    channel 在迁移期会同时承载多个 payload/base schema；
  - v2 `Pin<S>` 的 `base/4` 与 `expressible?/4` 不得读取
    `Context.phonology` 或 `Context.legacy_probe`；legacy 路径为保持旧
    digest 行为可继续读取旧输入事实；
  - `Pin<Co<S,Ph>>` 可在 repatch/消费边界读取 `legacy_probe`，但挂载
    是否需要异步 probe 由具体 payload schema 决定。
  """

  alias Neume.Pin.{Context, Descriptor}

  @doc "按 payload 分派出其 descriptor（carrier + payload/base schema）。"
  @callback describe(term()) :: {:ok, Descriptor.t()} | {:error, term()}

  @doc "推导该 payload 在当前上下文中的签名底料。"
  @callback base(Context.t(), Tamale.Anchor.t(), Descriptor.t(), term()) ::
              {:ok, term()} | {:error, term()}

  @doc "re-patch 的可表达性校验：payload 在新底料/上下文上仍可表达则 `:ok`。"
  @callback expressible?(Context.t(), Tamale.Anchor.t(), Descriptor.t(), term()) ::
              :ok | {:error, term()}

  @doc """
  该 payload 的可表达性校验是否需要 probe 物化序列（`Context.legacy_probe`）。

  按 descriptor/payload schema 判定，不由 channel 一刀切：纯 `Pin<S>`
  返回 `false` 时，re-patch 不强迫引擎实现音素展开（`phonemes/3`）。
  """
  @callback requires_probe?(Descriptor.t(), term()) :: boolean()

  @optional_callbacks requires_probe?: 2

  @doc """
  入口校验：module 是否实现了本 behaviour 的全部必填回调。

  裁决与 re-patch 在调用语义回调前先做此检查；不完整实现的 channel
  得到 tagged error（`{:missing_pin_semantics, module}`），而不是
  `UndefinedFunctionError`。
  """
  @spec implemented?(module()) :: boolean()
  def implemented?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :describe, 1) and
      function_exported?(module, :base, 4) and
      function_exported?(module, :expressible?, 4)
  end
end
