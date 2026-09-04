# 多轨运行时、Oi、NIF 与 UI 职责

状态：设计决定（首版）  
范围：Neume/Neumu 多轨渲染、混音、播放与导出  

## 术语

- **Neume**：本仓库 `apps/neume` 的 headless 领域与引擎内核；现有 Elixir 模块
  仍使用 `Neume.*`。
- **Neumu**：面向用户的产品外壳/应用。如果以后以单独 OTP app 或 UI shell
  落地，它消费 Neume 的稳定命令、查询、事件和制品接口，不复制引擎语义。
- **UI**：Neumu 的具体交互层；只拥有展示和用户意图，不是任务、播放状态或
  音频算法的事实来源。

当前仓库没有活动中的 Phoenix/Svelte UI，因此本文只固定接口所有权，不选择
前端框架。

## 已确定的运行边界

```text
Coconut Project / History
  └─ Vocal Track extras（voicebank、mix 参数）
          ↓
Neume.MultiTrack（领域编排）
  ├─ track × phrase check/render
  └─ 声明 Neume Oi graph
          ↓
Oi（执行、并发、取消、缓存、任务生命周期）
          ↓
Neume audio NIF（PCM 热路径，可替换实现）
          ↓
TrackArtifact / MixArtifact / Playback source
          ↓
Neumu application service
          ↓
UI
```

### Coconut

Coconut 继续作为持久编辑事实与 History 的唯一入口：

- 音符、patch、track extras 和可撤销参数；
- 跨轨编辑的一条原子 History 边；
- 工程序列化。

Coconut 不拥有声库解析、Oi 图、渲染任务、PCM、播放设备或 UI 状态。

### Neume

Neume 拥有领域语义并声明图：

- `{track_id, phrase}` 工作单元；
- 每轨声库 signature → Registry entry；
- check veto、错误定位和制品契约；
- gain/pan/mute/solo 的音频语义；
- track、mix、master、export 节点及其 cache identity；
- sample rate、声道、格式与导出约束。

Neume 不自行再造通用 executor、任务池、取消协议或缓存调度器。

### Oi

以下能力交给 Oi 的运行时/执行层，而不是在 `Neume.MultiTrack` 中用零散 Task、
Agent 或自建 ETS 调度：

1. `track × phrase` fan-out 与 track/mix/master fan-in；
2. 并发上限、背压、进度和 cooperative cancellation；
3. phrase/track/mix/master 节点缓存，以及依赖变更后的选择性失效；
4. solo 导致的图输入选择、跳过静音轨和下游失效传播；
5. 任务状态与失败传播。

Neume 提供业务 key、节点输入和策略；Oi 决定何时、在哪个执行器上运行，以及
如何复用结果。若当前 Oi 缺少所需通用能力，应扩展 Oi，而不是在 Neume 内放一套
只服务本产品的第二执行器。

## 多轨 Session 与 History

`Neume.MultiTrack` 已收束为整个工程唯一的 Coconut session/history：

- 一个工程只有一个 Coconut session/history；
- 多轨编辑、mix 参数和声库重绑定都写入这一 session；
- Neume track runtime 只持有可重建的 pipeline/worker/cache handle；
- undo/redo 后，以同一工程快照刷新所有受影响 runtime；
- 多轨工程文件保存并恢复这份唯一 History。

逐轨 check/render 时，`Neume.Editor` 只在调用期间把 `Neume.TrackRuntime`
临时绑定到根 Session 的当前 History 快照和该轨 engine 配置；调用结束后不保留
第二份可写 Session。该实现属于 Neume session facade 与 Coconut 已有多轨 batch
能力的接线，没有把渲染或混音语义加入 Coconut。Oi 后续根据变化后的业务
identity 只失效相关 track/phrase 和下游 mix/master。

## 缓存层次

缓存节点由 Neume 声明、由 Oi 执行：

```text
PhraseProbe
  key = voicebank + phrase score + probe globals + identity inputs

PhraseRender
  key = PhraseProbe inputs/result identity + pins + seed + synthesis opts

TrackAssemble
  key = ordered phrase artifacts + absolute offsets

TrackGainPan
  key = track artifact + gain + pan + mute

Mix
  key = ordered audible track artifacts + solo selection

Master
  key = mix artifact + master parameters

Export
  key = master artifact + container/encoding specification
```

缓存内容和临时 WAV/PCM 都是仓库外运行制品。UI 不能自己缓存一份具有不同
identity 规则的结果。

## Solo

Solo 是工程/会话中的轨道路由事实，不是 UI 过滤器。Neume 定义其规则：

- 没有 solo 时，所有非 mute 轨进入 Mix；
- 存在 solo 时，只有 solo 且非 mute 的轨进入 Mix；
- 被排除轨可跳过 render，或复用已有 track artifact；
- solo/mute 变化只失效路由之后的相关节点，不应使声学 phrase cache 失效。

持久性待产品决策：如果 solo 只是监听状态，可放 session runtime；如果导出也应
服从 solo，则必须作为明确的 export routing 参数，不能由 UI 当前按钮状态暗中决定。

## 音频 NIF 边界

可以引入 Rust NIF，但 NIF 是 Neume/Oi step 的计算后端，不是新的领域层。

优先迁入 NIF 的纯热路径：

- PCM16/float32 解码与编码；
- mono → stereo；
- equal-power pan；
- gain、mute、求和、饱和/限幅；
- 不同长度 buffer 的对齐与混合；
- 后续需要时的重采样、meter/RMS/peak。

保留在 Elixir 的部分：

- graph 与 step 声明；
- track/phrase identity；
- 参数校验与 tagged error；
- 路由、缓存 key、任务状态；
- artifact metadata 和文件生命周期。

建议接口保持后端可替换：

```elixir
Neume.Audio.mix(tracks, opts)
Neume.Audio.pan(samples, pan, law: :equal_power)
Neume.Audio.master(samples, opts)
```

首版可由纯 Elixir reference backend 对照 NIF；NIF 必须覆盖边界值、clipping、
声道交错和逐样本/容差一致性测试。不要把声库路径、Oi context 或 UI 对象传进 NIF。

## Equal-power Pan：Neume 与 UI

Equal-power pan 的**算法和规范**属于 Neume：

- 参数域固定为 `[-1, 1]`；
- 中央与两端的增益律由 Neume 定义；
- NIF/Elixir backend 必须实现同一契约；
- 参数参与 `TrackGainPan` cache identity。

UI 只负责：

- knob/slider 的视觉与手势；
- 显示单位、中心吸附和无障碍输入；
- 把用户意图提交为 Neume command；
- 展示 Neume 返回的规范化值和错误。

UI 不计算最终左右声道增益，也不拥有一套独立 pan law。

## 播放与导出：Neumu 与 UI

### Neume 拥有

- render/export 请求规格和合法性；
- job identity、状态机和进度事件的领域契约；
- Oi execution handle 与取消；
- MixArtifact/ExportArtifact 生命周期；
- 播放源（文件/PCM stream）的格式与时间轴；
- seek、loop、playhead 与渲染版本之间的一致性规则；
- 导出路径、格式、覆盖和失败语义。

### 最小 Job/Event 契约

`Neume.RenderJob` 是纯值状态机，不是进程，也不拥有 Oi execution handle：

```text
queued -> running -> completed
                  \-> failed
```

任务创建时保存 `project_id` 与 Coconut History cursor node id（`source_pin`）。
后续编辑不改写该 pin；完成态持有实际 `RenderArtifact` 或 `MixArtifact`，失败态
持有原因，终态不能再次转换。调度失败若需进入任务生命周期，应先把任务标记为
running，再以明确原因结束为 failed；当前不提前加入 cancellation 状态。

`Neume.Event` 的公开事件固定为三个小 tuple：

```elixir
{:project_changed, project_id, history_pin}
{:render_changed, job_id, status}
{:artifact_ready, job_id, artifact_id, source_pin}
```

事件只负责通知订阅者重新查询权威状态，不携带工程快照、制品内容、Orchid step
路径、report stream、进度 payload 或 UI 展示数据。`artifact_ready` 的
`source_pin` 从已完成 job 取得，`artifact_id` 由未来 application service 的制品
存储分配。Oi/Orchid 的内部进度以后可以聚合成 `render_changed`，无需改变事件
形状。

### Neumu application service 拥有

- 把 Neume job/event 映射到产品级会话；
- 播放设备/系统音频适配器的生命周期；
- 多窗口或多客户端订阅；
- 最近导出、通知和产品策略；
- UI 断开后任务继续还是取消的策略。

### UI 拥有

- transport controls、时间线和进度展示；
- 文件选择器和导出表单；
- 发出 play/pause/seek/cancel/export 意图；
- 订阅并渲染权威状态；
- 乐观视觉反馈，但最终以 Neumu/Neume 事件校正。

UI 不直接启动 Task、不直接调用 NIF、不把浏览器本地播放状态当成工程或任务事实，
也不自行决定导出是否绕过 check。

## 下一实现顺序

1. 为 Oi 定义/补齐可取消 fan-out/fan-in execution 与节点缓存；
2. 将现有 TrackGainPan/Mix/Master 的纯 Elixir 实现保留为 reference backend，
   增加 `Neume.Audio` facade 和 Rust NIF backend；
3. 由 Oi graph 实现 solo 路由和 mix/master cache；
4. 补齐 playback/export 请求契约，在已有 Neume job/event 协议上建立 Neumu
   application service；
5. 最后让 UI 只消费命令、查询和事件接口。

## 非目标

- 不在 CoconutOi 中实现调度、混音、播放或任务管理；
- 不让 NIF 持有工程、声库 Registry 或 UI 生命周期；
- 不在 UI 内复制 pan、cache identity、check 或 export 语义；
- 本决定不选择具体 UI 技术栈或系统播放库。
