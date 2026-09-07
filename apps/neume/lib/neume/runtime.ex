defmodule Neume.Runtime do
  @moduledoc """
  Neume 编辑语义与具体合成运行时之间的稳定边界。

  运行时负责把声库 entry 编译成执行状态、声明 CoconutOi 端口映射，并消费
  已裁决的 score/phonology/correspondence pin。运行时内部的模型、后端、seed
  与缓存身份不得进入 Neume pin 身份。
  """

  alias Coconut.Render.Engine.Snapshot

  @type state :: term()
  @type pins :: %{pitch: map(), duration: map()}

  @callback compile(keyword()) :: {:ok, state()} | {:error, term()}
  @callback engine_config(state(), term()) :: map()
  @callback voicebank_digest(state()) :: String.t() | nil
  @callback checked_pins(map()) :: pins()
  @callback analyze_phrases(state(), Snapshot.t(), pins(), map(), term()) ::
              {:ok, list(), [map()]} | {:error, term()}
  @callback phonemes(state(), Snapshot.t(), term()) :: {:ok, map()} | {:error, term()}
  @callback render(state(), Snapshot.t(), pins(), map(), term()) ::
              {:ok, Neume.RenderArtifact.t()} | {:error, term()}
  @callback render_checked(state(), Snapshot.t(), list(), map(), term()) ::
              {:ok, Neume.RenderArtifact.t()} | {:error, term()}

  @optional_callbacks render_checked: 5
end
