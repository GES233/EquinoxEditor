# 通道开发指南（Channel Development Guide）

本文面向两类开发者，说明 Equinox 中「可编辑数据通道」的契约与生命周期。

- **管线开发方**：给合成 DAG 加节点（声学模型、vocoder、工具 step）。你只跟 Oi 打交道，
  干预到达你手里时已经是 resolve 之后的纯数据——**不需要读 coconut/tamale**。
- **通道定义方**：定义一个新的可编辑通道（新曲线参数、音素时序、可编辑 G2P……）。
  可编辑性 = coconut/tamale 约束，可执行性 = Oi 约束，你需要理解下述三要素。

## 1. 数据流总览

```text
编辑批次结束 → History.run(Command)（唯一写入口；写时 transport 判定结构死活，
               死 patch 进墓地，由 History.take_dead_patches/1 排干上浮）
             → Score.Track.slice/3（equinox 自实现 Windowing；Metric 锚 patch 的
               tick 区间作 extra_spans 撑窗）
             → 每窗口 RenderRequest.from_window/3（锚 ∩ 窗口过滤存活 patch：
               Ordinal/Relative 按 refs ∩ note_ids，Metric 按 tick 区间相交）
             → 【check】Runner 按 channel 分组 → projection.(request, patch) →
               Tamale.Patch.resolve/2（digest 零容差比对）
               ├─ 全部 {:ok, payload} → 经 target 绑定为 data interventions → 执行
               └─ 任何 conflict/配置错误 → {:error, {:check_failed, entries}}，一个窗口都不执行
             → 【render】Oi.execute/2（Stratum 按输入内容哈希缓存）
```

关键性质：**干预只在 resolve 之后、以普通输入数据的形态跨过 coconut→Oi 边界**。
过了界，Stratum 的内容哈希缓存自动获得正确的失效语义。

另：`Coconut.Edit.History` 的 op tree 同时是 undo/redo 的地基（随 coconut 迁移落地）。

## 2. 管线开发方：你看到的契约

执行单元按 `{track_id, window_start_tick}` 寻址。你的 step 输入有两种来源：

- 图内边：上游节点的输出，Oi 自动流转。
- **data interventions**：channel 的 resolved artifact 被绑定到某个端口后，
  按既有装配规则注入——
  - 目标端口**无入边**（dangling input）：作为 memory 输入喂入，等价于上游产物已在黑板上；
  - 目标端口**有入边**（producer override）：以 `{:override, value}` 覆盖该 producer
    输出的全部下游消费端口。

值的形状由 channel 自己定义（Opaque to Kernel）。resolved 产物即 patch payload
本体——`Tamale.Patch.resolve/2` 只判 digest，通过则原样返回 payload。例如
phoneme_timing 的 payload 是 `%{deltas: [%{identity, onset_delta_ms, duration_delta_ms}]}`，
把 delta 施加到引擎新鲜投影上（换算成最终 onset/duration）是消费方（引擎 Hook）
的职责；曲线通道（第二刀）将是 `%{param, start_tick, end_tick, stride, samples}`。

## 3. 通道定义方：三要素

### 3.1 Channel（coconut 侧，编辑语义）

实现 `Coconut.Render.Channel` behaviour，回答两个问题：

- `projection/2` — `(Workspace.t(), Patch.t()) -> {:ok, base} | {:error, _}`：
  产出 patch 锚区的新鲜 base slice（digest 输入）。base 必须是 canonical term
  （`Tamale.Digest` 拒绝 float / struct / tuple——归一化是 channel 模块自己的职责，
  参考 `PhonemeTiming.canonicalize/1`）。check 时 `Tamale.Patch.resolve/2` 对它取
  digest，与挂载时记录的 base_digest **零容差**比对：失配即 conflict（如
  `:base_changed`），通过则原样返回 payload。
- `target/0` 或 `target/1`（至少实现其一）— resolved payload 的落点（见 §3.3）。
  `target/1` 额外收 patch，用于锚派生端口（如 per-note `{:port, note_id, :pitch}`）。

锚不再需要三元组匹配猜测：挂载时按意图显式构造 `Tamale.Anchor.Ordinal` /
`Relative` / `Metric`（见 §5）；结构死活由写时 transport 判定，死 patch 进
History 墓地（graveyard）而不是冲突列表。

参考实现：`EquinoxDomain.Port.Channels.PhonemeTiming`；coconut 自带
`Coconut.Render.Channels.{Lyric, Duration, Pitch}`。

### 3.2 projection（Host 侧，投影供给）

check 时需要一份「同一引擎、当前输入下的新鲜投影」与 snapshot 比对。
projection provider 是 Host 注入的函数，签名：

```elixir
(RenderRequest.t() -> {:ok, projection :: term()} | {:error, term()})
```

投影必须**确定性可复现**：同引擎同版本下相同输入逐位一致。引擎/模型升级 =
全部快照失配 = conflict 风暴——这是显式接受的最坏情形（见 zongzi
`declaration-projection-resolution`）。

### 3.3 target（Host 侧，端口绑定）

resolved artifact 绑到哪个端口。两种形态：

```elixir
# 静态：整条 artifact 绑一个端口
{:port, node_id, port}

# 函数：fan-out / 形状转换，返回 PortRef—值 对列表
fn artifact -> [{{:port, :vocoder, :f0_override}, artifact}, ...] end
```

### 3.4 注册：Configurator.channels

三要素经 `Configurator` 注入（Kernel 不感知任何具体 channel 名）：

```elixir
Runner.run(dispatch, board,
  channels: %{
    phoneme_timing: %{
      projection: &MyEngine.Timing.project/1,
      target: {:port, :acoustic_model, :durations}
    }
  }
)
```

将来 UI/插件系统的通道注册也走同一份配置（`plugins:` 与 `channels:` 正交：
前者是 recipe 级变换，后者是 data 级绑定）。

## 4. check 失败：`{:check_failed, entries}`

check 全量聚合，先 check 后 render——有任何 entry，一个窗口都不执行。
entry 形状：

```elixir
%{unit_id: {track_id, window_start_tick},
  channel: atom(),
  kind: :conflict | :unknown_channel | :projection_failed,
  reason: term()}
```

- `:conflict` — `Declaration.resolve/2` 判 snapshot 失配（带 `intervention_id`）。
  **用户可决议**：将来 UI 展示后由用户选择重放/放弃（Phase 3）。
- `:unknown_channel` — 干预存在但未注册 channel spec（reason `:no_channel_spec`）。
  配置错误，响亮失败——静默丢弃用户编辑不可接受。
- `:projection_failed` — projection provider 返回 `{:error, reason}`。引擎侧故障。

当前 check 失败只到 `Session.Server` 日志；UI 决议回路归 Phase 3。

## 5. 采纳：`Server.adopt_intervention/4`

引擎产出默认是 Artifact，不落为领域事实。显式采纳：

```elixir
Server.adopt_intervention(server, track_id,
  %{channel: :phoneme_timing, declaration: MyDeclaration, seq_id: seq, payload: payload},
  projection)
# → {:ok, track, intervention} | {:error, _}
```

内部：`AdoptRequest.new/1` → `AdoptRequest.adopt/3` →
`Track.mount_intervention/5`（派生 NoteTriplet 锚 + 写 snapshot）。采纳的不是
tick 区间数据块，而是一条锚在音符上的 channel 干预——结构死活归后续 rebase，
语义有效性归 check 时 resolve。

## 6. 第二刀预告（曲线通道）

- 通用曲线 Declaration（连续数据原型：控制点 + 边界维护，覆盖 pitch/energy/… 全部
  连续参数，新参数零 zongzi 代码）；
- 帧网格 `timing_spec` 声明机制（模型相关的 hop/frame rate 由插件侧声明，
  Caller 光栅化时查询，Kernel 不硬编码）；
- RasterCache + Douglas-Peucker（光栅缓存指纹含网格 spec；原始笔画先简化再进 History）。
