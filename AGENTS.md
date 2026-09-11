# AGENTS.md

## Project Status

Equinox is the singing-synthesis editor (this Mix umbrella). **Neume** names the editing paradigm — the Tamale/Coconut edit model (History, pin interventions, check/repatch discipline) — and its Elixir implementation: the kernel apps `coconut`, `coconut_oi`, `neume`, `neumu`. Concrete synthesis runtimes live in separate adapter apps such as `neume_opu_ds`. The deliverable is the paradigm itself plus its technical reports/videos; the editor is its host. `apps/neume_lab` is development tooling (Livebook bench), not the product UI. There is no active Phoenix/Svelte UI shell in this branch.

The source of truth for implementation status is the **Neume Implementation Status** section at the end of this file (migrated from the retired `apps/neume/STATUS.md`).

## Repository Layout

- `apps/coconut/` — engine-agnostic editor core. It owns score/edit state, History, Patch/Resolve, and persistence. It was imported from the archived standalone Coconut repository and is now maintained as part of this umbrella.
- `apps/coconut_oi/` — intentionally small bridge from `Coconut.Render.Engine` requests and interventions to Oi data and `Oi.execute/2`.
- `apps/neume/` — stable editor and pin semantics: editor facade, runtime/provider contracts, History-facing identity/check/repatch, windowing, cache, mix, debug export, and render artifacts. It has no concrete DiffSinger or OpenUTAU dependency.
- `apps/neume_opu_ds/` — OpenUTAU DiffSinger adapter: voicebank scanning and Stock/Modified variants, Pure-FP preparation, Oi analysis/synthesis graph, Python worker, ONNX inference, and adapter-specific tests.
- `apps/neumu/` — OTP application service over Neume: per-project `ProjectServer` processes (one `Neume.MultiTrack` value each), async render via `Task.Supervisor`, runtime `ArtifactStore`, and the three small event shapes. No playback device, cancellation, persistence, or UI.
- `apps/neume_lab/` — Livebook/Kino 实验台（开发工具，非产品 UI）。`Kino.JS.Live` 面板验证 Neumu facade 契约闭环（编辑/冲突/repatch/按 pin 渲染/试听），自带 fixture 声库、假 DiffSinger client 与正弦演示渲染器。notebook 在 `apps/neume_lab/notebooks/lab.livemd`，以 Attached Node 方式附着到 umbrella 节点运行。
- `config/` — shared umbrella configuration.

The repository must build without sibling Coconut or CoconutOi checkouts. Tamale, Oi, and Orchid packages remain external dependencies resolved by Mix.

## Architecture Boundaries

```text
Coconut (edit/history/patch/persistence)
        ↓
CoconutOi (intervention-to-Oi translation only)
        ↓
Neume runtime/pin contracts
        ↓
NeumeOpuDs Oi graphs and engine steps
        ↓
DiffSinger worker / ONNX / artifacts
```

- Coconut must remain engine-agnostic. Do not add DiffSinger, Oi graph, playback, mixing, or UI semantics to it.
- CoconutOi must remain a thin adapter. Do not add engine compilation, phoneme alignment, track scheduling, mixing, buses, playback, or export management to it.
- Neume owns stable score/phonology/correspondence pin meaning and runtime/provider contracts. Do not add concrete voicebank package scanning, DiffSinger model topology, Python worker, FP surgery, backend, or seed semantics to it.
- NeumeOpuDs owns the OpenUTAU package and current DiffSinger execution runtime. Runtime execution identity must not enter Neume pin identity.
- Multi-track scheduling, mixing, buses, and export aggregation are implemented as Neume-owned Oi graphs/steps.
- Phoneme types, frame grids, G2P, vowel anchoring, and model probes belong to the Neume DiffSinger adapter/worker.
- Coconut History remains the only entry for persistent score, patch, track-extras, and undoable edits.
- 现有 legacy pitch/duration pin 底料是 `pin_input_v1` 输入事实签名（歌词/显式音素/melisma 归属/声库摘要），推导为纯函数、不经引擎；digest 裁决在 probe 期统一冲突界面，Coconut 静态 check 不过问。`Pin<S>` / `Pin<Ph>` / `Pin<Co<S,Ph>>` 解耦设计见 `apps/neume/docs/design-2026-09-pin-carriers.md`：批次 A 协议骨架（`Neume.Pin.Descriptor/Context/Semantics/Schema`）、批次 B（`score_pitch_v2` note_tick envelope + `score_region_v1` 底料、`Neume.Pin.Resolved`/`Neume.Pin.Lower` 与 `Neume.Runtime.lower_pins/4` lowering 边界、facade probe 令牌不再携带底料）、批次 C（stable phonology ref 确定性派生、字典级 phonology digest 回调）与批次 D（`phoneme_duration_v2` segment ref envelope + `phoneme_correspondence_v1` 底料、repatch ref 重定向、`replace_pin` 手势）与批次 E（`pitch_curve_v2` note_tick Bezier envelope，`mount_pitch_curve` 默认产 v2）已实施。legacy 双轨是迁移期兼容层，不长期保留；旧工程读档兼容不变。
- melisma 必须由显式 syllable group 表达，不在 worker 中启发式猜测。
- Model paths, generated models, caches, and WAV files are not committed.

## Development Rules

- Use forward slashes in portable documentation and commands where practical.
- Search before acting; do not assume paths from the previous Equinox architecture.
- Source code, comments, and project documentation are written in Chinese unless an external contract requires otherwise.
- Return tagged results for expected failures instead of raising at public boundaries.
- Preserve exact/canonical values at Tamale-facing boundaries; do not feed raw floats into anchors or digests.
- Do not revive code from CoconutIntervention wholesale. Extract only behavior required by the current production path, place it in the owning app, and cover it with focused tests.

## Dependencies

Umbrella apps use `in_umbrella: true`:

```elixir
{:coconut, in_umbrella: true}
{:coconut_oi, in_umbrella: true}
```

Do not replace these with sibling checkout paths. Keep one resolved version/source for Tamale, Oi, and Orchid dependencies across the umbrella.

## Validation

From the repository root:

```powershell
mix deps.get
mix deps.tree
mix compile --force --warnings-as-errors
mix test
mix format --check-formatted
mix dialyzer
git diff --check
```

Neume real-voicebank tests are excluded by default. Run them explicitly only with the required external voicebank and Python environment:

```powershell
cd apps/neume_opu_ds
mix test --include integration test/neume_opu_ds/diff_singer_integration_test.exs
```

Python worker tests must run from `apps/neume_opu_ds` with the inference dependencies installed.

## Neume Implementation Status

更新日期：2026-09-11（迁移自 `apps/neume/STATUS.md`；不变量已并入上文 Architecture Boundaries，验证命令见 Validation 一节）。

### 当前定位

Neume 已完成无界面 SVS 内核的第一条真实纵向闭环，并具备 analyze/align、
稳定 check API 与分窗增量渲染，但还不是可交互编辑器：

```text
Neume.Editor
→ Coconut Session / History / Resolve
→ CoconutOi.OrchidAdapter（静态 check）
→ Oi（ScorePlan → Analysis → Synthesis）
→ 常驻 Python worker
→ DiffSinger duration / pitch / variance / acoustic / vocoder
→ 窗口 WAV 缓存 → 拼接 WAV + 全局音素边界
```

### 已完成

- 单人声轨音符插入、内容修改、拖动和删除。
- Coconut History 驱动的 undo/redo；所有音符和 patch 写入均经过 Coconut。
- 工程保存/加载（v2 信封）：undo/redo 历史随档恢复（`Coconut.Pickle.History`
  + `History.restore/1`，present 不入档、restore 时从最近 checkpoint 重
  fold 派生；v1 旧档读入为新鲜历史）；最近一次 check 不持久化。
- 无声库时使用确定性的 mock 管线。
- OpenUtau DiffSinger 声库严格扫描：配置、八个 ONNX 模型、语言/音素
  字典、speaker embedding、统一帧网格和路径逃逸检查。
- 声库是仓库外资产；多根目录发现由 `Neume.Voicebank.Registry` 负责。Stock
  与 Modified 是两个独立 entry/工程身份（`:diffsinger_stock` /
  `:diffsinger_modified`）；发现只读取已有修改 manifest，不执行模型修改，构建
  必须显式调用 `Registry.prepare_modified/3`。工程保存 `{name, engine, digest}`，打开时由注册表解析。
- 多语言歌词 G2P（worker 侧 `g2p.py` 纯函数，字典是声库事实、查不到
  loud error 不静默降级）：中文经 `dsdict-zh.yaml` + `pypinyin`；英文整词
  查 `dsdict-en.yaml`，未收录词不猜测、不拆分；日文假名自动罗马音化（拗音、促音 っ→`cl`、长音
  ー→重复前一拍元音、ん→`n`）后逐拍查 `dsdict-ja.yaml`，罗马音可直接
  书写，汉字须显式音素。任何语言可用音符 metadata 中的显式
  `[[language, phoneme]]` 完全绕过 G2P。
- 常驻 NDJSON Python worker；ONNX session 按 Python、声库路径/摘要、
  FP manifest/噪声版本/seed 和 worker 路径隔离，摘要或渲染上下文变化后
  不会复用旧 session。
- 本机实验后端：`Neumu.create_project/2` / `load_project/3` 可透传
  `diffsinger_backend: :openvino`（默认 `:cpu`），GPU/f32 运行
  variance/acoustic/vocoder，pitch 保留 CPU；模型动态编译实例在 worker 内
  常驻，后端进入 worker/窗口键身份。因不保证 GPU 字节确定性，实验模式
  强制关闭窗口 WAV 缓存，不静默回退 CPU。后端不持久化、不改变 pin 底料；
  disclaimer、依赖与真 GPU 验证入口见 `apps/neumu/docs/openvino-local.md`。
  本批只接现有协议，未更换为 Symbiont 生命周期管理。
- DiffSinger Modified 变体当前采用 Pure-FP 工艺：本地手术把 pitch/variance/acoustic/vocoder
  图内随机算子改成 host-noise 输入，worker 按固定 seed 生成 NumPy float32
  噪声；Stock 需作为另一个声库 entry 显式选择。派生模型只写 gitignored `tmp/`，
  原声库只读，分发与商用权限仍取决于具体声库许可证。
- identity-base pitch intervention：兼容稀疏绝对 tick/MIDI 折线，并支持
  Coconut Bezier 控制点容器；Bezier 在宿主侧按真实声学帧对应 tick 栅格化，
  Python worker 只消费逐帧绝对 MIDI，曲线数学不重复实现。
- 逐音素 duration pin：指定音素固定为给定 tick 时长，其余音素按预测比例
  吸收剩余帧；该 patch 支持 undo/redo。
- OpenUtau 式元音锚定：支持任意数量的词内音素，首辅音向前回排，首个元音
  onset 对齐音符起点；C-G-V 结构以 glide 为锚。
- `RenderArtifact` 返回 WAV 信息、lead-in、逐音素时长，以及带 `note_id` 的
  实际绝对帧边界；展示数据与模型消费的 `ph_dur` 是同一份结果。
- `Editor.analyze/1` / `check/1` 按 RestSplit3Beats 乐句逐窗 probe：所有乐句都会
  执行，错误统一聚合并携带 `track_id`、`phrase_id`、`span`、`note_ids`；
  `Neume.Analysis.merge/1` 把逐窗音符、预测和音素边界投影回整曲绝对帧轴。
  同一次 `render/1` 直接把已检查的 plan/probe 交给独立 Synthesis Oi 图，
  不再重复模型 probe。
- 多轨 runtime（`Neume.MultiTrack`）：整个工程只持有一个 Coconut
  Session/History；音符、pin、mix、globals、声库重绑定和增删轨都进入同一全局
  History，undo/redo 跨轨按提交顺序工作，工程文件一并保存/恢复该 History。
  声库签名保存在各 Vocal track 的 `extras[:neume][:voicebank]`；每轨只保留
  可重建的 `Neume.TrackRuntime`（独立 pipeline、worker 与乐句缓存），多轨
  check 聚合所有轨道/乐句错误。
- 最小渲染任务/事件契约：`Neume.RenderJob` 是钉住工程 History node id 的纯值
  状态机（`queued -> running -> completed | failed`），不持有进程、Oi handle
  或调度策略；`Neume.Event` 只产生 `project_changed`、`render_changed` 和
  `artifact_ready` 三种 identity tuple。制品内容留在权威存储中，事件只传
  `artifact_id`，并沿用任务创建时的 `source_pin`。
- Neumu 最小纵向闭环（`apps/neumu` OTP application service）：监督树含
  `Neumu.ProjectRegistry`（按 `project_id` 定位）、`Neumu.EventRegistry`
  （事件订阅）、`Neumu.RenderSupervisor`（`Task.Supervisor`）、
  `Neumu.ArtifactStore` 与 `Neumu.ProjectSupervisor`；`ProjectServer`
  一工程一进程、持有唯一 `Neume.MultiTrack` 值，渲染在 GenServer 外
  异步执行并回落 `RenderJob` 状态与 `artifact_id`；renderer 可注入，
  生产默认走 `Neume.MultiTrack.render/1`。重复 `job_id` 返回
  `{:error, {:job_already_exists, job_id}}`（在途/终态均不覆盖），未知
  job 返回 `{:error, {:job_not_found, job_id}}`；订阅幂等（同一进程
  重复订阅每个事件只投递一次）；关闭工程时在途渲染任务随
  `ProjectServer` 终止一并回收，不泄漏到应用级 `RenderSupervisor`。
- Neumu UI-facing backend facade（`Neumu` 模块）：`create_project` /
  `load_project` / `save_project` 复用 `Neume.MultiTrack` 与 Coconut
  Pickle 持久化（不另造文件格式）；`snapshot/1` 返回当前 History cursor
  下的权威只读投影（`Neumu.ProjectSnapshot`：轨道、音符、mix/globals、
  `history_pin`），只含 plain data，不泄露 PID、worker、Session 或
  Oi compiled graph。编辑命令（音符增删改移、轨道增删、声库重绑定、
  mix/globals 更新、undo/redo）以封闭命令集串行进入对应
  `ProjectServer`；成功且实际产生 History 边时返回新 `history_pin`
  并派发一次 `{:project_changed, project_id, history_pin}`，无变化的
  编辑（如无改动的 globals 合并）不落边也不派发，失败编辑返回
  tagged error、不改状态、不派发事件。查询不产生 History 边。
  试听支撑（2026-09-05）：`list_voicebanks/1` 列出可选声库（plain
  data）；`check/1` 在 ProjectServer 外执行权威 check 并返回
  plain-data 冲突投影（patch 只留 patch_id/channel/note_id），让
  冲突/降级可占 UI 一等位置；`submit_render/2` 支持 `:pin` 渲染指定
  历史状态（`Neume.MultiTrack.at_pin/2` 物化，被 squash 的 pin 返回
  tagged error），`list_render_jobs/1` 枚举任务的 `source_pin` 与
  `artifact_id`，支撑"按 pin 试听对比"。`export_artifact/2` 把制品
  WAV 完整复制到指定路径（在线播放走壳层 chunk/range 流式送文件）。
  facade 契约冻结于 `apps/neumu/docs/facade-protocol.md`；
  `Neumu.RefClient`（test/support）是瘦客户端参考实现（镜像快照 +
  事件同步 + stale 重放），`contract_test.exs` 跑通完整契约回路。
- 组展开一致性黄金向量（`apps/neume/test/fixtures/expand_vectors.json`）：
  真 worker（`test_alignment.py` 的 `ExpandVectorsTest`）、neume/neumu
  两侧的假 client 测试消费同一份 fixture；"末音素当延续元音"的替身
  近似在不成立的情形（末音素非元音）由前置断言 loudly 报错
  （mock pipeline 返回 `{:unsupported_continuation_head, _, _}`，假
  client raise `ArgumentError`），不再静默选错。
- Neume-owned Oi 混音图（`Neume.MixPipeline`）：`TrackGainPan → Mix → Master →
  Export`，支持逐轨 mute/gain/pan、sample-rate 门禁、PCM16 master 限幅与立体声
  WAV 导出；mix 配置保存在 track extras，并经 Coconut History 更新。
- 分窗增量渲染：RestSplit3Beats 规则切窗（空档 < 3 拍粘连，≥ 3 拍切开、
  前 1 拍归前窗、后 2 拍归后窗、更长留死区）；窗口级 WAV 缓存
  （key 覆盖声库摘要、globals、窗内音符内容与 pins），编辑只失效内容变化
  的窗口；各窗 WAV 按绝对采样偏移拼接成整轨制品。缓存边界保持粗粒度，
  ONNX 中间张量不跨 Orchid step、进程或 ETS。`RenderArtifact.windows`
  报告逐窗 `:hit | :miss`。
- melisma（跨音符音节组）：续音音符携带 `metadata["melisma"] == "continue"`
  且与前一音符贴接时并入其组（`Neume.Syllable` 纯派生；删头自动晋升、
  出缝自动断组）；组打包为单 word 多 slot——头音素 + 每成员一个延续
  元音，逐音素 midi 各带成员音高，延续元音锚在成员起点；worker 侧
  `expand_groups` 展开（音素类型是声库事实，不猜测）；duration pin 保持
  per-note Ordinal 锚，Analysis 平移到词内下标并按组总时长校验预算；
  `Editor.split_note/4` 拆分右子自动补旗标（单一历史边，undo 一步还原）。
- pin 身份底料（coconut `design-2026-08-orchid-intervention.md` §6.6
  第二档，2026-09-05 起改为**输入事实签名**）：duration/pitch pin 的
  digest 钉"决定语音学身份的输入事实"——歌词、显式音素、生效 melisma
  归属（续音 = 头的输入事实）、声库内容摘要——不钉 probe 物化的音素
  序列（G2P/组展开是引擎内部协议，不进身份层）。底料推导是纯函数
  （`Neume.Identity.base_by_note/2`，不跑 G2P、不调 worker），挂载不再
  依赖 probe。爆炸半径：改词/显式音素修改/melisma 晋升断组/声库内容
  变化会炸；改音高、拖动、邻居编辑不炸。已知取舍：同音字改词等"输入
  变了但 G2P 输出不变"的编辑会假冲突，由 repatch 重签兜住。coconut 侧
  channel `resolve_stage/0`（`:probe` 跳过静态 digest 裁决）与
  `Coconut.mount` 的 `:base` 显式签名不变；裁决仍在
  `check`/`analyze`/`render` 的统一冲突界面聚合（`Neume.Identity`），
  冲突 entry 形如 `%{kind: :conflict, stage: :probe, patch: ...}`；
  probe 物化序列继续服务于 duration pin 的可表达性校验（re-patch 时
  的下标界内判定）。
- `Editor.repatch/2` 批量重挂手势：payload 在新底料上仍可表达（下标在
  界内等）则保留重签，否则降级报告 `:degraded`（旧 patch 原样保留）；
  整批经 coconut `Command.repatch_patches` 落**一条历史边**（undo 一次
  全还原）。
- pin carrier 协议骨架（`design-2026-09-pin-carriers` 批次 A）：
  `Neume.Pin.Descriptor` / `Context` / `Semantics` / `Schema` 落地；
  `PitchPin` / `DurationPin` 按 payload 分派 descriptor（legacy 点列、
  `pitch_curve_v1` 与旧 duration list 均仍签 `pin_input_v1`），
  `Identity.adjudicate/3` 与 re-patch 计划改为按 channel semantics
  分派（整轨底料经 `Context.legacy_bases` 预计算共享；probe 需求按
  `requires_probe?/2` 判定，纯 pitch 批不调 `pipeline.phonemes/3`；
  语义入口校验不完整实现为 `{:missing_pin_semantics, _}` tagged
  error）；digest、工程文件与 facade 行为不变。
- pin carrier 批次 B（pitch v2，2026-09-07，§11.1 拍板 `note_tick`）：
  点列 mount 默认产出 `score_pitch_v2` envelope（`%{schema, coordinates:
  "note_tick", values: [[offset, midi]]}`，挂载时按当前 span 起点从绝对
  tick 换算），签 `score_region_v1` 底料（只钉 track/note/坐标系——
  改词、换声库、改音高、拖动均不炸；merge 锚重定签与跨轨移动冲突，
  repatch = 显式重签）；survival matrix 逐手势钉死（见设计文档 §6），
  trim/split 越界点在消费边界 loud 报错、repatch 经 `expressible?/4`
  降级。Bezier envelope 本批保持 legacy `pitch_curve_v1`。lowering
  边界（B0）：`Neume.Pin.Resolved` 由 Editor 从存活 patch 直接构造
  （不经 Oi assemble 数据反推），runtime 经 optional callback
  `Neume.Runtime.lower_pins/4` 降为执行输入——mock 与 `neume_opu_ds`
  委托 `Neume.Pin.Lower`（legacy 透传、note_tick 平移为绝对 tick，
  worker 协议不变）；runtime 未实现时纯 legacy 批次回退
  `checked_pins/1`，含 v2 schema 的批次在统一冲突界面返回
  `{:unsupported_pin_schema, schema}`（kind `:pin` entry）。facade
  probe 令牌只携 `track_id`/`note_id`/`pin`，底料由 server 经 channel
  语义现场推导，客户端传回的 base 一律拒绝。legacy payload 不自动
  升级；升级如将来提供必须是显式、可报告、可撤销手势。
- pin carrier 批次 C（phonology ref，2026-09-11，§11.2/11.3 拍板）：
  stable segment ref 确定性派生（`Neume.Phonology.Ref`：unit = 组头
  note_id，segment = `%{unit, member, index}` 成员内序号，不引入持久化
  ID；删头晋升/出缝断组的 ref 漂移已钉测试）；`NeumeOpuDs.Voicebank.
  Manifest` 扫描期增算字典级 `phonology_digest`（inventory/languages/
  dsdict 词典，不覆盖模型/embedding——模型刷新与 Stock/Modified 切换
  不炸 Ph/Co pin），`Neume.Runtime.phonology_digest/1` 回调由 provider
  混入 G2P 算法版本戳（`opu-g2p/1`，改 `g2p.py` 规则时必须递增）；
  `Context.voicebank_identity` 扩为 `%{digest, phonology_digest}` 并全程
  透传，legacy 路径只读全量 digest（旧工程兼容不动）；双 runtime ref
  契约向量（`PhonologyRefVectorsTest` 复用 `expand_vectors.json`）钉住
  真身/替身序列上 ref 解析一致。无用户可见 payload 变化，duration v2
  属批次 D。
- pin carrier 批次 D（duration v2，2026-09-11）：`phoneme_duration_v2`
  envelope（stable segment ref `%{unit, member, index}`）签
  `phoneme_correspondence_v1` 底料（track/note + unit 全组输入事实 +
  phonology digest；改音高/拖动/模型刷新存活，改词/词典变化/melisma
  晋升断组/split 加成员冲突）；repatch 升级为"segment 可重定向"——
  `Semantics.redirect/4` 按当前 membership 机械重写 ref 后同边重签
  （结果报告 `redirected: true`），不成立则降级；`Neume.Pin.Lower` 把
  ref 降为成员内下标（worker 协议不变），ref 失配 loud 报错且与身份
  冲突在同一 check 界面聚合。`Editor.replace_pin/4` 接线：丢弃在册
  patch + 挂载新 payload 一条历史边（undo 一次还原），允许同 schema
  替换与 legacy → v2 升级、拒绝 v2 → legacy 降级
  （`{:pin_schema_downgrade, _, _}`），facade `Neumu.replace_pin/4`
  透出。legacy duration 行为不变。
- pin carrier 批次 E（pitch curve v2，2026-09-11）：`pitch_curve_v2`
  envelope（anchor 为 `note_tick` 相对 tick，handle 保持相对 anchor
  偏移，value 绝对 MIDI）签 `score_region_v1` 底料（与 `score_pitch_v2`
  同构）；`mount_pitch_curve` 默认产 v2（绝对 tick 入参按 span 起点
  换算，显式 v2 envelope 透传），legacy curve 仅经 `mount_pitch` 兼容
  路径透产；`Neume.Pin.Lower` 平移回绝对 tick 的 `pitch_curve_v1`
  plain map（栅格化、mock steps 与 worker 协议零改动）；`replace_pin`
  支持 `pitch_curve_v1` → `pitch_curve_v2` 显式升级、拒绝反向。
- 调试导出（`Editor.export_debug/2` → `Neume.DebugExport`）：Track 维度 +
  可选 `span` tick 裁剪（多轨适配预留），打包 `neume-debug/1` schema 的
  debug.json——notes（秒轴）、帧级 pitch（有效/可选 `raw?: true` 无干预
  对照）、音素绝对边界、tempo 段，以及 `meta.patches`（存活 pin 的锚点
  投影：kind/refs/at_version + 解析出的 tick 区间 + payload）和 `curves`
  （pitch pin 的绝对 tick → MIDI 控制点投影，与模型消费契约一致）。
  `tools/plot_render.py`（vendored 自 coconut_intervention，扩展了
  frames_origin/span 默认缩放/pin 铆钉标记）用 matplotlib 画钢琴卷帘 +
  pitch + 音素时序，`-o` 扩展名决定 PNG/SVG/PDF。导出前走完整
  check+probe，冲突即失败。
- 全局表现旋钮（轨道挂载，不经 tamale patch）：`:energy` / `:breathiness`
  / `:voicing` 是 variance 预测曲线的乘性系数（`1.0` 中立，合法范围
  0.0–2.0），`Editor.update_globals/2` key 合并（nil 删除）后写入
  `track.extras[:neume][:globals]`——经 `Command.put_track_extras` 落一条
  可 undo 历史边，随工程持久化；读档与 undo/redo 后从 extras 重新派生
  会话 render 配置（编译期默认在下、轨道旋钮在上）。globals 门禁在 check
  聚合（`%{kind: :global, ...}`），有效值进入窗口缓存键与 worker 调用。
  逐帧表现曲线本版本不做（见"下一步"）。
- Neumu facade 手势覆盖（`apps/neume/docs/plan-2026-09-ui-facade-gestures.md`
  第一至三批）：`split_note`（右子自动补 melisma 旗标）、`rename_track`、
  `set_time_sigs`、`trim_note`（melisma 断组自动派生、pin 预算走 check
  裁决）、`merge_notes`（into 留内容原样；`moved_pins` 显式报告被吸收
  音符上重定签到 into 的 pin）、`drag_note_across_tracks`（内容全量
  复制、清 melisma 旗标、pin 不迁移）。pin 族走两阶段挂载：
  `Neumu.probe_pin/3` 在 ProjectServer 外纯派生身份底料（输入事实
  签名，不跑 G2P），返回 plain-data 令牌；三个 mount（pitch 点列、
  Bezier plain map、音素时长）携令牌进 server 做 History pin 校验，
  probe 期间被编辑则 `{:error, {:stale_pin, _}}` 拒绝；
  `Neumu.repatch/3` 按 patch id 批量重挂，回复 `{:ok, pin, results}`；
  `Neumu.unmount_pin/4` 按 `(track_id, note_id, channel)` 卸载；
  `Neumu.replace_pin/4`（批次 D）替换在册 pin 的 payload（同 schema
  或 legacy → v2 升级，一条历史边）。
  快照新增 `time_sigs`、`can_undo`/`can_redo` 与逐轨 `pins`（存活
  patch 的 id/channel/anchor/payload）投影，全部 plain data。

### 验证基线

- `mix compile --force --warnings-as-errors`：通过。
- `apps/neume` 核心测试：`155 passed`（含 `score_pitch_v2` survival
  matrix、lowering fallback 规则、批次 B 评审修订：later-write-wins
  顺序、显式 base schema 校验、双入口缺失 tagged error，批次 C 的
  `Neume.Phonology.Ref` 派生/解析与漂移矩阵，批次 D 的
  `phoneme_duration_v2` survival matrix——改词重签/split 加成员/melisma
  晋升断组 redirect/越界降级/存读往返，以及 `replace_pin` 契约：同
  schema 替换一条边可 undo、legacy → v2 升级、v2 → legacy 拒绝，批次 E
  的 `pitch_curve_v2` survival matrix——拖动跟随栅格化不变/trim 越界
  repatch 降级/merge 冲突重签、mount 换算与显式 envelope 透传、lowering
  与 legacy 栅格化逐帧一致、`pitch_curve_v1` → v2 升级与降级拒绝）；
  `apps/neume_opu_ds` 适配器测试：`46 passed, 8 excluded`（excluded 为
  真声库集成测试，含双 runtime lowering 契约——含 v2 duration ref
  降下标与失配 loud 报错、批次 C ref 契约向量与字典级 phonology
  digest 门禁）。
- `apps/neumu` 的 `mix test`：`72 passed, 1 excluded`（工程开闭、渲染成功/失败/崩溃、
  渲染期间查询、source_pin 保留、制品存取、事件订阅幂等与退订、重复
  job_id 拒绝、未知 job tagged error、nil project_id 拒绝、关闭工程终止
  在途渲染；facade：快照与 pin 一致且无运行时对象泄露、查询不产生历史边、
  音符增删改移/拆分/修剪/合并/跨轨拖拽与 mix/globals/轨道增删/重命名/
  拍号/声库重绑定落权威状态、成功编辑只发一次 `project_changed`、失败
  编辑不改状态不发事件、undo/redo 更新 pin 并发事件、globals 无变化不
  落边、保存重开恢复工程与 History、渲染期间编辑不改 `job.source_pin`、
  并发编辑不丢更新、未知工程 tagged error；pin 族：probe 只读不改状态、
  两阶段挂载、stale_pin 拒绝、令牌绑定 track/note、unmount_pin、repatch
  重签/降级/不在册拒绝、replace_pin 同 schema 替换与 legacy→v2 升级
  （降级拒绝）、合并 moved_pins 报告、快照 pins 投影与保存重开
  恢复；试听支撑：声库列表、check 返回 plain-data 冲突投影且可 repatch
  兜回 :ok、按 pin 渲染历史状态且 source_pin 钉住、非法/未知 pin 拒绝、
  list_render_jobs 枚举 source_pin/artifact_id 并净化失败原因、check 条目
  深扫无 tuple（`phrase_id` 等结构化字段降为 list，`:reason` 例外保持
  tagged term）；tempo 族：台阶插/改/删与快照 `tempo_steps` 投影、同
  tick 拒绝、首事件保护、非法输入 tagged error、undo/redo、保存重开、
  时长查询空轨回退 flat 120 BPM 且只读无副作用；契约回路：
  参考客户端跑通 建工程→编辑→stale 重放→冲突 check→repatch→按 pin
  渲染对比→导出落盘；黄金向量钉住替身与真身的 expand 一致性）。
- `apps/neume_lab` 的 `mix test`：`9 passed`（Kino.Test 驱动实验台面板：
  连接全量状态、编辑事件桥、失败命令 command_error 不改状态、冲突四步流
  挂 pin→改词→repatch→恢复、按 pin 渲染与 `{:binary, _, WAV}` 试听下发、
  undo/redo；正弦渲染器产出合法 WAV 制品、空工程 `:no_notes` tagged
  error）。
- Asaritsu Pure-FP 真机门禁：关闭缓存后 seed 0 重复 WAV SHA-256 均为
  `a4876ac3…`；seed 1 为 `8cd1a7ae…`；stock/FP 短样本 RMS 相对差
  `43.6%`，通过 2× 包络门禁。
- `mix dialyzer`：`Total errors: 0`。
- Python 纯函数测试：47 项通过，覆盖对齐（V/CV/CCV/CVC、C-G-V、休止、
  melisma 组展开/多 slot 锚定与 `note_phonemes` 按 owner 归并、黄金向量
  fixture）、pitch 输入，以及多语言 G2P（en 整词与未收录词 loud error、
  ja 假名罗马音化含促音/长音/鼻音、汉字 loud error、zh pypinyin 通路）。
- Asaritsu 真声库集成测试（6 例）：整轨渲染与 WAV 输出；analyze 边界与
  render 一致；check 聚合模型错误；多窗编辑后仅受影响窗重渲（缓存
  `:hit/:miss` 逐窗断言）；melisma 一词两音符（延续元音锚在成员起点、
  头元音在成员起点截止、analyze/render 边界一致）；多语言歌词（英文
  整词、日文假名含促音 `cl`、中文混排，语言标签与边界断言）。96 tick
  的首辅音被量化为 9 帧，后续元音仍落在音符起点 ±1 帧。
- `git diff --check`：通过。

真声库测试默认排除，运行方式见 Validation 一节；可用 `DS_VOICEBANK` 和
`DS_PYTHON` 覆盖本机路径。

### 当前限制

- 同一 Vocal track 仍是单声部；同轨重叠音符会明确报错。
- 当前只有 pitch 和 phoneme duration 两种生成参数编辑。
- 分窗规则不含 slice_flag 手动覆盖（音符 metadata 覆盖未移植）。
- Oi 尚未接管多轨 fan-out/fan-in 的并发、取消、solo 路由与 mix/master
  节点缓存；当前图已声明混音步骤，但轨道调度仍是同步 facade。
- PCM 热路径仍是纯 Elixir reference 实现，尚未引入 Rust NIF。
- Neumu application service（`apps/neumu`）：工程按 `project_id` 注册、
  一工程一 `ProjectServer` 持有唯一 `Neume.MultiTrack`、渲染经
  `Task.Supervisor` 在 GenServer 外执行、制品入运行时 `ArtifactStore`；
  UI-facing facade 已就位（只读快照含 time_sigs/can_undo/can_redo/pins
  投影、封闭编辑命令集含拆音/修剪/合并/跨轨拖拽与 pin 族两阶段挂载、
  `project_changed` 派发、工程创建/加载/保存入口、制品导出落盘、
  阶梯式 tempo 台阶手势与区间时长查询）。仍无
  播放设备适配或渲染取消；交互界面目前只有
  `apps/neume_lab` 的 Livebook 实验台（`Kino.JS.Live` 面板 + fixture
  声库/假 client/正弦演示渲染，notebook 需 Attached Node 运行），无产品级
  UI。

### 声库处置

当前本机技术验证使用 Asaritsu。它不进入仓库，也不作为未来公开版本的默认
配布资产。公开给其他人使用前，再替换或重新确认适合分发、展示和联投的声库；
此决定不阻塞当前内核开发。

### 下一步

详细职责决定见 [`apps/neume/docs/design-2026-09-multitrack-runtime.md`](apps/neume/docs/design-2026-09-multitrack-runtime.md)。

1. 多轨并发/取消、solo 路由和 phrase/track/mix/master 缓存交给 Oi；Neume
   只声明业务图、identity、veto 与 artifact 契约。
2. 增加 `Neume.Audio` facade，以当前纯 Elixir 算法为 reference backend，
   引入 Rust NIF 承担 PCM 解码/增益/equal-power pan/混合/限幅等热路径。
3. 在 Neumu application service 上补齐 playback/export 请求契约（编辑
   facade 与 `project_changed` 派发已完成）；UI 只提交意图并展示权威状态，
   不复制音频、check 或任务语义。手势缺口与施工批次见
   [`apps/neume/docs/plan-2026-09-ui-facade-gestures.md`](apps/neume/docs/plan-2026-09-ui-facade-gestures.md)。
4. ~~逐帧曲线 channel（energy/breathiness/voicing 的手绘编辑）~~本版本不做。
