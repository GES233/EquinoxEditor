# Engine Adapter 设计：边界定案与短期路线

> 2026-08-15 边界讨论定案。本文记录「无头编辑器」定位从 coconut 迁移到
> equinox kernel 之后的层间边界、Engine Adapter 契约形态，以及短期
> 「跑通全流程」的最小动作。通道三要素（Channel / projection / target）
> 与 check-resolve 生命周期见 `docs/channel-development.md`，本文不重复。

## 1. 定案总览

| 决策点 | 结论 |
|---|---|
| 「无头编辑器」定位 | 从 coconut 迁移到 **equinox kernel**（`Session.Server/Context` 已是事实：History 唯一写入口、具名编辑 API、graphs/cache/tasks） |
| coconut 的 `Render.Engine` / `Resolve` / `Encoder` 栈 | **dormant 保留**：零调用残留（whole-workspace Snapshot 粒度，与 equinox per-window 派发不兼容），不删代码、加 dormant 标注、equinox 不接入 |
| Engine Adapter 契约归属 | **kernel 定义 behaviour**（`Equinox.Kernel.EngineAdapter`），引擎实现放 userland/插件侧（与 Hook 体系同构） |
| Adapter 与 Configurator channel spec 的关系 | **Adapter 打包供给**：Configurator 从 Adapter 派生 channels/globals，单一来源，不再手工注入 channel spec |
| History 持久化 | **短期 A**：History 是会话态，不过夜（存档/读档后 undo 树清零，现状即设计）；**长期 B**：coconut 补 `Pickle.Command` + `Pickle.History`（`Pickle.Op` 已就位），进 coconut 路线图，不动 equinox 侧边界 |

## 2. 层间边界（定案后）

```text
Tamale   = rebase 内核（零依赖）
Coconut  = 纯编辑内核 + 最小契约：Edit.* / Pickle.* / Score.* / Curve.*
           + Render.Channel behaviour
           （dormant：Render.Engine / Resolve / Encoder）
           无进程、无会话、无编排
Domain   = 薄纯数据层：Project/TrackMeta、Windowing、RenderRequest/AdoptRequest、
           channel 实现（PhonemeTiming）。不放引擎运行时概念
Kernel   = 无头编辑器 + 引擎接口所在地：
           会话态（History/graphs/compile_cache/blackboard/tasks）
           + 编辑 API + 派发编排（slice → RenderRequest → check → render）
           + EngineAdapter behaviour（契约）
UI Shell = 呈现层（Phase 3）
```

红线沿用既有纪律：kernel 不感知具体参数名 / 模型版本 / 帧率（ADR-004），
全部由 Adapter 配置注入；跨 coconut→Oi 边界的只有 resolve 之后的纯数据。

## 3. EngineAdapter 契约（短期最小形态）

```elixir
defmodule Equinox.Kernel.EngineAdapter do
  # 打包供给：一个 Adapter 产出一套 channel specs（projection/target，
  # 形状同现有 Configurator.channel_spec()）
  @callback channels(config :: term()) :: %{atom() => Configurator.channel_spec()}

  # 引擎身份键（声库 id + 引擎版本），进 digest base 的版本戳
  @callback engine_key(config :: term()) :: String.t()

  # 帧网格声明（hop / frame_rate，模型相关；第二刀光栅化时消费）
  @callback timing_spec(config :: term()) :: {:ok, map()} | {:error, term()}

  # 引擎级旋钮声明（coconut Engine.info 的 globals 概念迁到 kernel，kernel 校验）
  @callback globals(config :: term()) :: %{atom() => {:range, _, _} | {:enum, [_]}}

  # 产出侧：哪些 artifact 可采纳、落哪个 channel
  # （与 EquinoxDomain.Port.Preset 的 allow_adopt 对齐）
  @callback adoptables(config :: term()) :: [atom()]
end
```

Configurator 派生（单一来源）：

```elixir
Configurator.new(engine: {MyAdapter, config})
# 内部展开为 channels: MyAdapter.channels(config)、globals 校验规则等
```

`Runner.run/3` 的 check/render 两段流程不变——Adapter 只是 channel spec 的
打包供给方，不是新的执行层。

**版本纪律**：引擎/模型升级 = 全部 digest 失配 = conflict 风暴，这是显式
接受的最坏情形（tamale caller guide）。Adapter 的 `config` 必须包含引擎版本，
projection 供给的确定性按版本对齐。

## 4. 短期「跑通全流程」最小动作

目标闭环：

```text
编辑 → History → slice → RenderRequest → check（Adapter 供给 projection + resolve）
     → render（Oi 执行合成 DAG）→ Artifact（默认不落领域事实）
     → adopt（显式采纳为 patch，回挂 History）
```

1. ~~kernel 定义 `Equinox.Kernel.EngineAdapter` behaviour + Configurator 派生逻辑~~
   （已落地，含 `engine_key/1` 版本戳回调）；
2. ~~写一个 stub/mock adapter（只接 `PhonemeTiming` channel 的伪引擎）把上述闭环
   端到端跑通~~（已落地：`kernel/test/support/stub_engine_adapter.ex` +
   `kernel/test/equinox/engine_adapter_test.exs`，per-track 派发 + 盖戳对拍 +
   版本升级 conflict + capabilities 门控全绿）；
3. coconut 侧给 `Render.Engine` / `Resolve` / `Encoder` 加 dormant 标注
   （一句话 moduledoc，不删代码）——**未做**，归 coconut 仓库；
4. 全流程 green 以 `cd kernel && mix precommit` 为准（已绿）。

## 5. 开放细节（设计阶段再钉）

- **artifact 的具体形状**：目前只有「引擎产出默认 Artifact、不落领域事实」的
  原则；形状与 `adoptables` 的对应关系待第一个真实引擎接入时定。
- **globals 校验挂点**（已定案 2026-08-15，见下「globals 与 capabilities
  定案」）。
- **curve channel**：已落地（2026-08-15，`EquinoxDomain.Port.Channels.Curve` +
  kernel `CurveRaster`，`timing_spec` 消费即帧网格光栅化；细节见
  `docs/channel-development.md` §6）。**RasterCache / Douglas-Peucker** 沿用
  deferred 状态。

### globals 与 capabilities 定案（2026-08-15）

**globals 校验挂点：Runner check 阶段**，与 patch check 共用 one-vote
全量聚合语义（entry kind `:global`，带 `:track_id` / `:key`，无
`:unit_id` / `:channel`——旋钮是轨级判断，不是窗口级）。落选方案
（Configurator 构造期 fail-fast）与 check 聚合语义分裂，弃。

值与规则的分工：

- **值**存 `TrackMeta.globals` 侧表（per-track、可序列化、不进 History、
  不可 undo，与 mix 同级）；写入走 `Server.update_track_globals/3`
  （逐键合并，nil 值删键）。**写时不知、查时有责**：写入侧不校验取值
  （kernel 写入路径不感知引擎规则），违例在 check 阶段聚合上浮。
- **规则**由 Adapter `globals/1` 声明，`prepare_dispatch` 按轨派生挂进
  dispatch `track_global_rules`；缺条目回落 `Configurator.global_rules`
  （同从 Adapter 派生）；规则为 nil = 无 Adapter 声明，**不门控**。
  声明空规则（`%{}`）则任何值都 `:unknown_global`（声明制：不声明即
  不接受，对齐 coconut `Render.Engine` 语义；reason 形状
  `:unknown_global` / `{:out_of_range, {lo, hi}}` / `:not_a_number` /
  `{:not_in_enum, allowed}` 亦对齐）。

**capabilities 校验责任：kernel 门控、Adapter 声明制**。两个挂点：

- check 侧：Adapter 不供给的 channel → `:unknown_channel` 响亮失败
  （既有语义，不变）。
- adopt 侧：`Server.adopt_intervention/3` 对照该轨 Adapter 的
  `adoptables/1`，未命中 `{:error, {:not_adoptable, channel}}`；
  无 Adapter 供给的轨不门控（userland 自管）。channel atom 取模块
  `channel/0`（equinox channel 约定，与 `AdoptRequest.channel_of/2`
  同源）。

### 声库（voicebank）设计草案

> 2026-08-15 讨论稿。核心判断：**声库是引擎侧的资产描述，不是领域
> 事实**——不进 Domain struct、不进 History、不参与 undo，与 TrackMeta 的
> presets/ui_state 同级。落地状态：TrackMeta `voicebank_id` 字段、
> per-track 解析（`Context.engine_for/2`）、digest 版本戳
> （`Channel.stamp_base/2` + `AdoptRequest :engine` 选项 +
> `EngineAdapter.engine_key/1`）已实现；描述符 VO 落地为
> `Equinox.Kernel.Voicebank`（下方形状的代码化，`engine_key/1` 即
> `"id@engine_version"` 约定；stub adapter 演示从描述符派生
> channels/timing/engine_key 的消费方式）。发现 / 注册机制仍属
> userland 运行时职责。

三层拆分：

1. **声库描述符（纯数据 VO，userland/Adapter 侧定义）**：

   ```elixir
   %Voicebank{
     id: "qiyu_v2",
     engine: :diffsinger,                 # 引擎种类
     engine_version: "0.9.1",
     models: %{acoustic: path, vocoder: path},  # 资产引用，不内嵌二进制
     dictionary: %{phonemes: [...], languages: [:zh, :ja]},
     capabilities: %{
       pitch_range: 40..80,
       supported_channels: [:phoneme_timing],   # 将来扩 curve channel
       supported_params: [:pitch, :energy]      # Adapter 据此派生 channel specs
     },
     timing: %{frame_rate: 100, hop: 512}       # 喂给 timing_spec
   }
   ```

   VO 校验纪律（`Voicebank.new/1`）：三元组 `id` / `engine` /
   `engine_version` 必填；`capabilities.supported_channels` /
   `supported_params` 若存在须为 atom 列表；`timing.frame_rate` / `hop`
   若存在须为正整数；`models` / `dictionary` 对 kernel 不透明（只校验
   是 map）。dump/load 为 plain map codec（与 Coconut.Pickle 约定一致）。

2. **挂载点：Adapter config**。声库不进 kernel 状态机，作为
   `Configurator.new(engine: {MyAdapter, %{voicebank: vb}})` 的 config 一部分。
   Adapter 用 `capabilities.supported_channels` 派生 `channels/1`，用 `timing`
   实现 `timing_spec/1`，用模型资产实现 `globals/1`。「换声库 = 换 Adapter
   config」，kernel 零感知，守住单一来源原则。

3. **每轨选择：TrackMeta 侧表**。某轨用哪个声库存 `TrackMeta`（新增
   `voicebank_id` 字段）——不可撤销、可序列化、与 mix/gain/pan 同级。派发时
   Session 按轨取 `voicebank_id`，组装对应 Adapter config 进 `prepare_dispatch`。

两条纪律（先于实现钉死）：

- **版本即 digest 灾难**：声库/模型升级 = projection 输入变化 = 全部
  `base_digest` 失配 = conflict 风暴，这是本文 §3 已显式接受的最坏情形。
  `id` + `engine_version` 必须进 projection 的 digest base，让升级
  「全死可见」而不是「静默错位」。
- **帧率归声库，不归 kernel**：`frame_rate`/`hop` 从声库描述符经
  `timing_spec/1` 流出，kernel 第二刀光栅化时才消费，绝不硬编码。
- **无存量 pickle 数据**（2026-08-15 确认，pre-release）：digest base 改动
  不需要迁移路径，直接改投影实现即可。

已定案：

- **Adapter 粒度 = per-track**（2026-08-15）：每轨一个 Adapter config，
  `prepare_dispatch` 按轨解析 `voicebank_id` 组装，check 聚合按轨分组。
  混库编辑是一等场景，不接受「每会话单声库」的简化。
- **globals 校验挂点 + capabilities 校验责任**（2026-08-15）：见上方
  「globals 与 capabilities 定案」——`TrackMeta.globals` 存值、Runner
  check 门控；kernel 门控、Adapter 声明制。

待钉问题：

- 声库资产的发现/注册机制（扫描目录？显式注册表？）——属 userland 运行时
  职责，equinox 侧只需约定描述符形状。

### Channel 本体与引擎/声库的对齐（草案）

声库回答「引擎能干什么」，Channel 本体回答「用户能编辑什么」——两者按
channel atom 对齐，但归属和版本纪律完全不同：

1. **本体 vs 供给的切分**（channel-development.md §3 的既有边界，此处钉死
   所有权）：
   - **本体**（Channel 模块，coconut 侧）：payload 形状、锚纪律、canonical
     base 形状——编辑语义，随 channel 版本演进，与具体声库无关。住在
     domain/userland 的 channel 定义里。
   - **供给**（projection spec，Host 侧）：引擎新鲜投影——随
     `engine_version` 演进，由 Adapter 按声库供给。
2. **单一 canonical 实现，两个调用点**：挂载时 `AdoptRequest.build_patch/3`
   走 Channel 模块 `projection/2`（workspace 粒度），check 时走 Adapter spec
   的 arity-2 投影（RenderRequest 粒度）。两处必须产出逐位一致的 canonical
   term，否则挂载即 conflict。纪律：Adapter 的 spec projection **委派**给
   Channel 模块的同一实现（外加声库 timing 归一化），不允许平行实现。
3. **atom 命名空间 vs capabilities**：channel atom 是引擎中立的编辑概念
   （`:phoneme_timing` 对所有声库同义）；声库 `capabilities.supported_channels`
   只做可用性门控。轨道 Preset 注册了声库不支持的 channel → check 时
   `:unknown_channel` 响亮失败（既有语义，不新增静默路径）。
4. **payload 演进纪律**：payload 对 resolve 不透明，但随 patch 进 pickle。
   无存量数据，从简：payload 形状变更 = 换 channel atom 或在 payload map
   内嵌版本键，不做迁移框架。
5. **新增一个 channel 的成本清单**（kernel 零代码是红线）：Channel 模块
   （projection canonicalize + target）→ `Port.Preset` 注册 → Adapter
   capabilities 条目 → 测试。参考 `Port.Channels.PhonemeTiming`；曲线通道
   已验证「新参数零 coconut/tamale 代码」的通用性承诺（`Port.Channels.Curve`，
   2026-08-15）。

### MCPAdapter（2026-08-15 落地，Phase 2 收尾）

第一个「真实 adapter」证明：`Equinox.Kernel.MCPAdapter` 经 MCP（stdio）
从外部引擎进程拉取声库描述符。

- **定位 = 能力声明拉取**。I/O 集中在 `fetch/1`（建连、经典握手、
  `resources/read`），注册表构建期调用一次；五回调拿到 enriched config
  后保持纯函数，Runner check 纯性不破。render-over-MCP（tool 调用进
  Orchid 图）明确不做——Hook 领地。
- **MCP client 手写**（`Equinox.Kernel.MCP.StdioClient`，~150 行，零新
  依赖——Jason 已有）：行分隔 JSON-RPC 2.0 over stdio Port，只覆盖
  initialize / notifications/initialized / resources/list / resources/read /
  ping。不引 anubis_mcp（LGPL-3.0 + 全家桶体量 + 规范滞后），不引
  hermes（停更）；若日后演化为全功能 MCP 宿主（tool 调用），再评估换库。
- **描述符线上约定**：resource（缺省 `vb://descriptor`）的 JSON text，
  键同 `Voicebank` 字段字符串形；`capabilities.globals` 规则用列表形
  （`["range", min, max]` / `["enum", [...]]`）；`adoptables` 缺省回落
  `supported_channels`（显式空表 = 全不可采纳，不回落）。
- **channel spec 构造**经 kernel 共享 helper
  `Equinox.Kernel.ChannelSpecs.build/3`（projection 委派 domain channel
  单一实现 + stamp_base 盖戳；曲线 spec 需 `timing:`）；声库声明了无法
  构造的 channel → `channels/1`  raise（配置错误响亮失败）。
