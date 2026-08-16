# Coconut 迁移设计(zongzi → coconut + tamale)

> 分支 `zongzi-to-coconut` 的迁移基准文档。2026-08-14 定稿。
> 依据:coconut `docs/design-2026-07-editor-core.md`(equinox 是集成参照系)、
> tamale `docs/zh/guide/caller-guide-zh.md` §8(equinox Track 迁移对照表)。

## 0. 已定决策

1. **domain 瘦身**:coconut 已收纳领域模型(Workspace/Track/Operations/History/Pickle),
   `EquinoxDomain` 只保留 coconut 没有的 equinox 特有物:windowing、slice_flag、
   轨道元数据(mix/preset/ui_state)、Preset、Phoneme、per-window RenderRequest、
   PhonemeTiming channel。
2. **Windowing 由 equinox 自实现**:移植 zongzi `RestSplit3Beats` 语义 + slice_flag
   两遍修正,数据源为 coconut `Track.view/1` 的 `[{id, Note, {start, end}}]` 投影。
   维持 per-window 渲染分发,前端 `SegmentData` 契约不变。
3. **写路径接 `Coconut.Edit.History`**:`Session.Server` 持有 History(纯数据),
   编辑 API 走 `Operations.*` / `Command` → `History.apply/run`。
   undo/redo 地基提前兑现(原 Phase 3 目标)。equinox 元数据侧表不进 History。

## 1. 依赖形态

三个子项目统一本地 path 依赖(coconut 的 tamale 声明指向 github,需 override 到本地):

```elixir
# domain/mix.exs、kernel/mix.exs、ui_shell/mix.exs 一致:
{:coconut, path: "../../coconut"},
{:tamale, path: "../../tamale", override: true}
```

- ui_shell 之前靠传递依赖白嫖 zongzi,现在显式声明 coconut/tamale。
- 原 domain(hex `~> 0.3`)与 kernel(path)的 SCM 不一致问题随之消除。

## 2. 概念映射总表

| zongzi / 旧 equinox | coconut / tamale / 新 equinox |
|---|---|
| `Zongzi.Timeline` + `notes_by_seq` + `interventions`(Caller 三件套) | `Coconut.Edit.Track`(Space + spans_by_version + elements_by_id + patches) |
| `Zongzi.Anchor.NoteTriplet` / `TripletMatch.scrub_triplet` | 显式构造 `Tamale.Anchor.Ordinal/Relative`(意图已知,无需猜) |
| `Zongzi.Intervention` + `Declaration` | `Coconut.Edit.Patch`(anchor + `Tamale.Patch` + channel)+ `Coconut.Render.Channel` 行为 |
| `Anchor.rebase_all` | Workspace 写时 transport + 死 patch 墓地(`take_dead_patches`) |
| `Declaration.resolve_within`(kernel check) | `Tamale.Patch.resolve/2`(投影 digest 零容差比对,参考 `Coconut.Render.Resolve`) |
| `Zongzi.Windowing.Strategy` / `RestSplit3Beats` / `Segment` | **equinox 自实现** `EquinoxDomain.Windowing`(见 §4) |
| `Zongzi.Util.Model` / `Util.Object` 宏 | 消亡;手写 `new/1` + `update/2`(coconut 风格,`Coconut.Util.Helpers`) |
| `Zongzi.Util.ID` | `Coconut.Util.ID` |
| `Zongzi.Score.{Note, Tick, Tempo*, TimeSig*, Record*, Grid, Key.*}` | `Coconut.Score.*` 同名(注意:Note 不带 tick,时序在 spans 表) |
| `Zongzi.Curve.*` | `Coconut.Curve.*`（2026-08-15 已接入 `:curve` channel + `CurveRaster`；`RasterCache`/`Douglas-Peucker`/`Curve.Chunk` pickle 仍 deferred） |
| `EquinoxDomain.Pickle.*` | `Coconut.Pickle.*`(Registry + Workspace/Track/Project codec) |

### coconut 与 zongzi 的硬差异(实施时注意)

- **Note 无时序字段**:`{id, key, lyric, annotation, metadata}`;start/duration 在
  track 的 spans 表。所有"note + tick"的下游消费(RenderRequest、presenter)
  必须携带 span `{start_tick, end_tick}`。
- **tempo 是一条轨**:`workspace.globals["global:tempo"]` 里的 `Track.Tempo`,
  元素为 `%{bpm: milli_bpm}`;`Workspace.tempo_map/1` 现编译。
  time_sig 不是轨,是 `Workspace.time_sigs`(bar 锚定),`set_time_sigs` 走 Command。
- **Tempo 结构层只认 Step**(milli-bpm 整数);`Tempo.Linear` 仅是消费侧插值。
- **Vocal 轨同轨不重叠**(半开区间,相邻合法),insert/drag/trim/merge 在
  gesture 校验期拒绝重叠——旧 equinox 允许重叠后 merge 的语义不存在了。
- **拖动 = `[Move, Retime]` 同批**(tamale 硬纪律),由 `Operations.DragNote` 保证。
- **纯内容编辑(歌词等)无 op**,只写侧表(`Operations.EditNote`)。
- 坐标进 tamale 内核必须精确有理数,**float 一律被拒**;digest 输入必须 canonical。

## 3. domain/ 目标模块图

### 删除

- `EquinoxDomain.Pickle` 及 `Pickle.{Note, Intervention, Timeline, TempoEvents, TimeSigEvents}`
  (由 `Coconut.Pickle.*` 取代)
- `EquinoxDomain.Score.SlicePolicy`(zongzi Windowing.Strategy 实现)
- 旧 `EquinoxDomain.Score.Track` 聚合(Timeline 三件套版)

### 保留/重写

- **`EquinoxDomain.Score.Project`** — 重写。struct `{id, workspace, tracks_meta, metadata}`:
  - `workspace :: Coconut.Edit.Workspace.t()` — 全部音符/干预/tempo/time_sig 真相。
  - `tracks_meta :: %{track_id => TrackMeta.t()}` — equinox 侧表(不进 History、不可 undo)。
  - API:`new/1`、`add_track/2`(建 `Track.Vocal` 进 workspace + 初始化 meta)、
    `remove_track/2`、`fetch_track/2`、`track_meta/2`、`put_track_meta/3`、
    `tempo_map/1`、`time_sig_map/1`、`view/2`(代理 `Coconut.Edit.Track.view`)、
    `dump/1` / `load/1`(组合 `Coconut.Pickle.Workspace` + TrackMeta codec)。
  - **Project 是纯数据查询层**;一切音符/干预/tempo 写操作不在此层
    (kernel 经 History + Operations/Command 写)。
- **`EquinoxDomain.Score.TrackMeta`** — 新。`{mix_automation, gain, pan, mute, solo,
  voicebank_id, globals, presets, active_preset, ui_state, metadata}`;手写 new/update/validate + dump/load。
  `voicebank_id` 用于按轨选择 `Session.Context` 中的引擎适配器；`globals` 存放引擎级旋钮值（写时不校验，Runner check 阶段按适配器规则门控）。
- **`EquinoxDomain.Score.Track`** — 重写为**无状态门面**(对 workspace 的查询函数):
  `notes(project, track_id) :: [{id, Note.t(), span}]`、`note/3`、`slice/3`(见 §4)。
- **`EquinoxDomain.Score.SliceFlag`** — 保留语义,改在 `Coconut.Score.Note.metadata` 上。
- **`EquinoxDomain.Windowing`** + **`EquinoxDomain.Windowing.Window`** — 新(§4)。
- **`EquinoxDomain.Score.Phoneme`** — 保留,去掉 `Zongzi.Util.Object`,手写 new/update。
- **`EquinoxDomain.Segment`** — 保留(rendering-context VO),去掉 zongzi 依赖,
  类型改引 `Coconut.Score.{Tick, Tempo}`。
- **`EquinoxDomain.Port.Preset`** — 保留;registry 的 value 从 declaration 模块改为
  `Coconut.Render.Channel` 实现模块。手写 new/update + dump/load。
- **`EquinoxDomain.Port.Channels.PhonemeTiming`** — 由 `Port.Declarations.PhonemeTiming`
  改写,实现 `Coconut.Render.Channel`(`projection/2` + `target/0`);
  归一化(无 float canonical 形)职责在本模块。delta payload 语义沿用。
- **`EquinoxDomain.Command.RenderRequest`** — 重写(§5)。
- **`EquinoxDomain.Command.AdoptRequest`** — 重写(§5)。
- **`EquinoxDomain.Command.Editing`** — 删除(coconut Operations/History 取代)。
- **`EquinoxDomain.Session`** — 删除(占位符,coconut 时代由 kernel Session 全权负责)。

## 4. Windowing(equinox 自实现)

`EquinoxDomain.Windowing.Window`:`{start_tick, end_tick, note_ids}`(左闭右开)。

`Windowing.slice(items, opts)`:

- `items :: [{note_id, Coconut.Score.Note.t(), {start_tick, end_tick}}]`(来自 Track.view)。
- 基准规则移植 `RestSplit3Beats`:相邻 content 空档 `gap < 3 * beat_ticks` 粘连;
  `gap >= 3 * beat_ticks` 切开,**前 1 拍归前窗、后 2 拍归后窗**,更长空隙中间留死区;
  `beat_ticks` 取 `opts[:beat_ticks] || opts[:tpqn] || 480`。
- **extra_spans**(`opts[:extra_spans]`,默认 `[]`):外部传入的 content span
  (如 Metric 锚 patch 的 tick 区间),与 note span 合并参与切分——对应 zongzi 的
  "scope 撑窗"语义。kernel 组装时负责从 patch 锚推导。
- slice_flag 两遍修正(移植旧 SlicePolicy):`:force_merge` 并窗、`:force_slice`
  在 flagged note 前切窗;退化切分(零长半窗,如和弦同 start)跳过。
- 纯函数,无任何 coconut 写路径耦合;Window 瞬态,不持久化。

## 5. RenderRequest / AdoptRequest

`RenderRequest` 字段:`{track_id, note_ids, notes, time_range, tempo_segments,
patches, channels}`。

- `notes :: [{note_id, Coconut.Score.Note.t(), span}]`(**带 span**,coconut Note 无 tick)。
- `tempo_segments`:`Coconut.Score.TempoMap.slice/3`(coconut 版编译图自带 tpqn,注意签名变化)。
- `patches`:窗口过滤——Ordinal/Relative 锚按 refs ∈ window.note_ids;Metric 锚按
  区间相交。只含**结构存活**的 patch;语义判定在 kernel check 阶段。
- `channels :: %{channel_atom => module}`(从 patches 派生 + Preset 注册表)。
- `from_window/3` 签名调整为吃 workspace 投影,不再吃旧 Track 聚合。

`AdoptRequest`:`build_patch/3`(纯)——由 channel 投影算 base_digest、显式构造锚
(Ordinal/Relative),产出 `Coconut.Edit.Patch.t()`;挂载动作由 kernel 经
`History.run(Command.attach_patches(...))` 完成(domain 不碰写路径)。

## 6. kernel/ 改造要点

- `Session.Context`:`project :: EquinoxDomain.Score.Project.t()` 保留为查询投影;
  新增 `history :: Coconut.Edit.History.t()` 为**唯一写入口**;`graphs` 维持现状。
- `Session.Server` 编辑 API 改写:
  - `add_track` / `remove_track` → `History.run(Command.add_track/remove_track)`
    + 元数据侧表同步;
  - 音符编辑(`replace_window_notes` 等)→ `Operations.*` 经 `History.apply/4`;
    优先评估 `Coconut.Edit.Diff`(before/after 反推 op)能否直接承接 UI 的整窗替换;
  - `update_track_mix` / `update_track_ui_state` → 纯侧表更新,不进 History;
  - `adopt_intervention` → `AdoptRequest.build_patch` + `History.run(Command.attach_patches)`;
  - 死 patch 墓地排水 `History.take_dead_patches/1` **当前仅记录到日志**，UI 暴露推迟到 Phase 3。
- `Runner` check 阶段:`Zongzi.Intervention.Declaration.resolve_within` →
  逐 patch `Tamale.Patch.resolve(patch, projection.(request))`,产出形状维持
  `%{port_ref => %{input: value}}`(与 `Coconut.Render.Resolve` 同构);
  conflict 全量聚合一票否决语义不变。Blackboard / Oi.execute 不动。

## 7. ui_shell/ 改造要点

- `ProjectPresenter`:`NoteData` 从 `Track.view` 项组装(id、span → start/duration、
  `Coconut.Score.Key.to_midi/1`、lyric);`SegmentData` 从 `EquinoxDomain.Windowing`
  的 Window 组装,`"w<start_tick>"` id 约定与窗口相对 tick 换算不变——**前端零改动**。
- `EditorLive`:`Zongzi.Score.Key.TwelveET` → `Coconut.Score.Key.TwelveET`;
  tempo 事件字面量 → coconut 的 `%{bpm: milli_bpm}`(经 `Coconut.Score.Tempo.cast_bpm/1`);
  `Zongzi.Util.ID` → `Coconut.Util.ID`。

## 8. 阶段与验收

1. mix.exs 依赖切换(三个子项目 `mix deps.get` 通过)。
2. domain 重写 → `cd domain && mix precommit` 绿(测试同步重写)。
3. kernel 改造 → `cd kernel && mix precommit` 绿。
4. ui_shell 改造 → `cd ui_shell && mix precommit` 绿。
5. AGENTS.md / docs 更新(分层图、里程碑、ADR 表指向 coconut/tamale 文档)。

验收对照 tamale caller-guide §10 自验清单:所有写走 Op 批次、drag 带 Retime、
patch at_version 只由 transport 推进、transport/resolve 非 ok 有去处、
digest 输入全 canonical。
