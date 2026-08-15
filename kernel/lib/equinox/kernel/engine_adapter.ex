defmodule Equinox.Kernel.EngineAdapter do
  @moduledoc """
  引擎适配器契约——channel spec / timing / globals / adoptables 的
  **打包供给方**（`docs/engine-adapter-design.md` 2026-08-15 边界定案）。

  kernel 只定义 behaviour，引擎实现放 userland / 插件侧（与 Hook 体系同构）。
  红线：kernel 不感知具体参数名 / 模型版本 / 帧率（ADR-004），全部由
  Adapter 的 `config` 注入；config 对 kernel 是不透明 term。

  一个 Adapter 实例 = 一份引擎 + 声库配置。**粒度 per-track**：每轨经
  `TrackMeta.voicebank_id` 从 `Session.Context.engines` 注册表解析到自己的
  `{adapter, config}`，`prepare_dispatch` 按轨派生 channel specs 挂进
  dispatch 的 `track_channels`。

  ## 版本纪律

  `engine_key/1` 的产出（约定 `"声库id@引擎版本"`）必须进 digest base：
  挂载侧经 `AdoptRequest.build_patch/3` 的 `:engine` 选项盖戳，check 侧
  `channels/1` 供给的 spec projection 用同一版本戳组合（两者共用
  `EquinoxDomain.Port.Channel.stamp_base/2`）。引擎 / 声库升级 = 全部
  digest 失配 = conflict 风暴——显式接受的最坏情形。
  """

  alias Equinox.Kernel.Configurator

  @doc "打包供给一套 channel specs（形状同 `Configurator.channel_spec()`）。"
  @callback channels(config :: term()) :: %{atom() => Configurator.channel_spec()}

  @doc "引擎身份键（声库 id + 引擎版本），进 digest base 的版本戳。"
  @callback engine_key(config :: term()) :: String.t()

  @doc "帧网格声明（hop / frame_rate，模型相关；第二刀光栅化时消费）。"
  @callback timing_spec(config :: term()) :: {:ok, map()} | {:error, term()}

  @doc "引擎级旋钮声明（kernel 校验规则；校验挂点待钉，见设计文档开放细节）。"
  @callback globals(config :: term()) :: %{
              atom() => {:range, term(), term()} | {:enum, [term()]}
            }

  @doc "产出侧：哪些 artifact 可采纳、落哪个 channel（对齐 `Port.Preset.allow_adopt`）。"
  @callback adoptables(config :: term()) :: [atom()]
end
