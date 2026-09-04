# Neume 开发状态

更新日期：2026-09-03
分支：`neumu-demo`

## 当前定位

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

## 已完成

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
- 中文歌词通过声库 `dsdict-zh.yaml` 和 `pypinyin` 自动音素化，也支持音符
  metadata 中的显式 `[[language, phoneme]]`。
- 常驻 NDJSON Python worker；ONNX session 按 Python、声库路径/摘要、
  FP manifest/噪声版本/seed 和 worker 路径隔离，摘要或渲染上下文变化后
  不会复用旧 session。
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
  第二档）：duration/pitch pin 的 digest 钉 probe 物化的**词内音素序列**
  （头=自身 G2P 序列，续音=派生延续元音单元素序列），不再钉 score 内容。
  爆炸半径：改词/显式音素修改/melisma 晋升断组/声库字典变化会炸；改音高、
  拖动、邻居编辑不炸。coconut 侧新增 channel `resolve_stage/0`（`:probe`
  跳过静态 digest 裁决）与 `Coconut.mount` 的 `:base` 显式签名；挂载经
  轻量 probe（worker `expand` action，G2P+组展开不跑模型；mock 为纯
  Elixir 派生），裁决在 `check`/`analyze`/`render` 的 probe 之后统一执行
  （`Neume.Identity`），冲突 entry 形如
  `%{kind: :conflict, stage: :probe, patch: ...}`，与静态冲突共用同一界面。
- `Editor.repatch/2` 批量重挂手势：payload 在新底料上仍可表达（下标在
  界内等）则保留重签，否则降级报告 `:degraded`（旧 patch 原样保留）；
  整批经 coconut `Command.repatch_patches` 落**一条历史边**（undo 一次
  全还原）。
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

## 验证基线

- `mix compile --force --warnings-as-errors`：通过。
- `apps/neume` 的 `mix test`：`84 passed, 7 excluded`（excluded 为真声库集成测试）。
- Asaritsu Pure-FP 真机门禁：关闭缓存后 seed 0 重复 WAV SHA-256 均为
  `a4876ac3…`；seed 1 为 `8cd1a7ae…`；stock/FP 短样本 RMS 相对差
  `43.6%`，通过 2× 包络门禁。
- `mix dialyzer`：`Total errors: 0`。
- Python 纯对齐测试：10 项通过，覆盖 V/CV/CCV/CVC、C-G-V、休止、melisma
  组展开/多 slot 锚定与 `note_phonemes` 按 owner 归并。
- Asaritsu 真声库集成测试（5 例）：整轨渲染与 WAV 输出；analyze 边界与
  render 一致；check 聚合模型错误；多窗编辑后仅受影响窗重渲（缓存
  `:hit/:miss` 逐窗断言）；melisma 一词两音符（延续元音锚在成员起点、
  头元音在成员起点截止、analyze/render 边界一致）。96 tick 的首辅音被
  量化为 9 帧，后续元音仍落在音符起点 ±1 帧。
- `git diff --check`：通过。

真声库测试默认排除，显式运行：

```powershell
cd apps/neume
mix test --include integration test/neume/diff_singer_integration_test.exs
```

可用 `DS_VOICEBANK` 和 `DS_PYTHON` 覆盖本机路径。

## 当前限制

- 同一 Vocal track 仍是单声部；同轨重叠音符会明确报错。
- 当前只有 pitch 和 phoneme duration 两种生成参数编辑。
- 分窗规则不含 slice_flag 手动覆盖（音符 metadata 覆盖未移植）。
- Oi 尚未接管多轨 fan-out/fan-in 的并发、取消、solo 路由与 mix/master
  节点缓存；当前图已声明混音步骤，但轨道调度仍是同步 facade。
- PCM 热路径仍是纯 Elixir reference 实现，尚未引入 Rust NIF。
- 没有 Neumu application service、播放设备适配或 UI。

## 声库处置

当前本机技术验证使用 Asaritsu。它不进入仓库，也不作为未来公开版本的默认
配布资产。公开给其他人使用前，再替换或重新确认适合分发、展示和联投的声库；
此决定不阻塞当前内核开发。

## 下一步

详细职责决定见 [`docs/design-2026-09-multitrack-runtime.md`](docs/design-2026-09-multitrack-runtime.md)。

1. 多轨并发/取消、solo 路由和 phrase/track/mix/master 缓存交给 Oi；Neume
   只声明业务图、identity、veto 与 artifact 契约。
2. 增加 `Neume.Audio` facade，以当前纯 Elixir 算法为 reference backend，
   引入 Rust NIF 承担 PCM 解码/增益/equal-power pan/混合/限幅等热路径。
3. 先定义 Neume job/event 与 playback/export 契约，再建立 Neumu application
   service；UI 只提交意图并展示权威状态，不复制音频、check 或任务语义。
4. ~~逐帧曲线 channel（energy/breathiness/voicing 的手绘编辑）~~本版本不做。

## 不变量

- Coconut 是编辑状态、History、patch 与序列化的事实来源。
- CoconutOi 只翻译 Coconut intervention 与 Oi data，不拥有音素对齐、轨道调度或混音语义。
- 多轨调度、混音、总线和导出汇聚由 Neume 声明的 Oi graph/steps 实现。
- 音素类型、帧网格、G2P 和元音锚定属于 DiffSinger adapter/worker。
- pin 底料是 probe 物化的音素序列（身份底料）；其物化与 digest 裁决在
  引擎 probe 期，Coconut 静态 check 不过问。
- 声库路径不持久化，模型和生成 WAV 不提交。
- melisma 必须由显式 syllable group 表达，不在 worker 中启发式猜测。
