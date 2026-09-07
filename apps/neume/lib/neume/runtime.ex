defmodule Neume.Runtime do
  @moduledoc """
  Neume 编辑语义与具体合成运行时之间的稳定边界。

  运行时负责把声库 entry 编译成执行状态、声明 CoconutOi 端口映射，并消费
  已裁决的 score/phonology/correspondence pin。运行时内部的模型、后端、seed
  与缓存身份不得进入 Neume pin 身份。
  """

  alias Coconut.Render.Engine.Snapshot

  @type state :: term()

  @typedoc """
  runtime 执行输入（lowering 产物）。形状由 runtime 自定——`lower_pins/4`
  的实现方决定；legacy 兼容形状为 `%{pitch: map(), duration: map()}`。
  """
  @type pins :: term()

  @callback compile(keyword()) :: {:ok, state()} | {:error, term()}
  @callback engine_config(state(), term()) :: map()
  @callback voicebank_digest(state()) :: String.t() | nil

  @doc """
  legacy 兼容入口：从 Oi assemble 数据抽取 pins。仅供未实现
  `lower_pins/4` 的 runtime 消费纯 legacy 批次时由 Editor 回退调用；
  新 runtime 应实现 `lower_pins/4`，不必再伪装旧 Oi 数据入口。
  """
  @callback checked_pins(map()) :: pins()

  @callback analyze_phrases(state(), Snapshot.t(), pins(), map(), term()) ::
              {:ok, list(), [map()]} | {:error, term()}
  @callback phonemes(state(), Snapshot.t(), term()) :: {:ok, map()} | {:error, term()}
  @callback render(state(), Snapshot.t(), pins(), map(), term()) ::
              {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  @callback render_checked(state(), Snapshot.t(), list(), map(), term()) ::
              {:ok, Neume.RenderArtifact.t()} | {:error, term()}

  @doc """
  把裁决侧构造的 `Neume.Pin.Resolved` 列表降为本 runtime 的执行输入
  （`pins()` 形状）。runtime 可委托 `Neume.Pin.Lower`（默认 lowering：
  legacy 透传、`note_tick` 平移为绝对 tick）；不支持的 payload schema
  必须返回 `{:error, {:unsupported_pin_schema, schema}}`，不静默猜解。

  未实现本回调的 runtime 只能消费纯 legacy 批次（Editor 回退
  `checked_pins/1` 兼容入口）；批次中出现 v2 schema 时由 Editor 直接以
  `{:unsupported_pin_schema, schema}` 拒绝。
  """
  @callback lower_pins(state(), Snapshot.t(), [Neume.Pin.Resolved.t()], term()) ::
              {:ok, pins()} | {:error, term()}

  @optional_callbacks render_checked: 5, lower_pins: 4, checked_pins: 1
end
