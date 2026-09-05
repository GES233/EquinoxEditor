# Neume 开发状态

更新日期：2026-09-05
分支：`master`

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
- Neumu facade 手势覆盖（`docs/plan-2026-09-ui-facade-gestures.md` 第
  一至三批）：`split_note`（右子自动补 melisma 旗标）、`rename_track`、
  `set_time_sigs`、`trim_note`（melisma 断组自动派生、pin 预算走 check
  裁决）、`merge_notes`（into 留内容原样；`moved_pins` 显式报告被吸收
  音符上重定签到 into 的 pin）、`drag_note_across_tracks`（内容全量
  复制、清 melisma 旗标、pin 不迁移）。pin 族走两阶段挂载：
  `Neumu.probe_pin/3` 在 ProjectServer 外纯派生身份底料（输入事实
  签名，不跑 G2P），返回 plain-data 令牌；三个 mount（pitch 点列、
  Bezier plain map、音素时长）携令牌进 server 做 History pin 校验，
  probe 期间被编辑则 `{:error, {:stale_pin, _}}` 拒绝；
  `Neumu.repatch/3` 按 patch id 批量重挂，回复 `{:ok, pin, results}`；
  `Neumu.unmount_pin/4` 按 `(track_id, note_id, channel)` 卸载。
  快照新增 `time_sigs`、`can_undo`/`can_redo` 与逐轨 `pins`（存活
  patch 的 id/channel/anchor/payload）投影，全部 plain data。

## 验证基线

- `mix compile --force --warnings-as-errors`：通过。
- `apps/neume` 的 `mix test`：`98 passed, 7 excluded`（excluded 为真声库集成测试）。
- `apps/neumu` 的 `mix test`：`62 passed`（工程开闭、渲染成功/失败/崩溃、
  渲染期间查询、source_pin 保留、制品存取、事件订阅幂等与退订、重复
  job_id 拒绝、未知 job tagged error、nil project_id 拒绝、关闭工程终止
  在途渲染；facade：快照与 pin 一致且无运行时对象泄露、查询不产生历史边、
  音符增删改移/拆分/修剪/合并/跨轨拖拽与 mix/globals/轨道增删/重命名/
  拍号/声库重绑定落权威状态、成功编辑只发一次 `project_changed`、失败
  编辑不改状态不发事件、undo/redo 更新 pin 并发事件、globals 无变化不
  落边、保存重开恢复工程与 History、渲染期间编辑不改 `job.source_pin`、
  并发编辑不丢更新、未知工程 tagged error；pin 族：probe 只读不改状态、
  两阶段挂载、stale_pin 拒绝、令牌绑定 track/note、unmount_pin、repatch
  重签/降级/不在册拒绝、合并 moved_pins 报告、快照 pins 投影与保存重开
  恢复；试听支撑：声库列表、check 返回 plain-data 冲突投影且可 repatch
  兜回 :ok、按 pin 渲染历史状态且 source_pin 钉住、非法/未知 pin 拒绝、
  list_render_jobs 枚举 source_pin/artifact_id 并净化失败原因；契约回路：
  参考客户端跑通 建工程→编辑→stale 重放→冲突 check→repatch→按 pin
  渲染对比→导出落盘；黄金向量钉住替身与真身的 expand 一致性）。
- Asaritsu Pure-FP 真机门禁：关闭缓存后 seed 0 重复 WAV SHA-256 均为
  `a4876ac3…`；seed 1 为 `8cd1a7ae…`；stock/FP 短样本 RMS 相对差
  `43.6%`，通过 2× 包络门禁。
- `mix dialyzer`：`Total errors: 0`。
- Python 纯对齐测试：11 项通过，覆盖 V/CV/CCV/CVC、C-G-V、休止、melisma
  组展开/多 slot 锚定与 `note_phonemes` 按 owner 归并，以及黄金向量
  fixture（`ExpandVectorsTest`）。
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
- Neumu application service（`apps/neumu`）：工程按 `project_id` 注册、
  一工程一 `ProjectServer` 持有唯一 `Neume.MultiTrack`、渲染经
  `Task.Supervisor` 在 GenServer 外执行、制品入运行时 `ArtifactStore`；
  UI-facing facade 已就位（只读快照含 time_sigs/can_undo/can_redo/pins
  投影、封闭编辑命令集含拆音/修剪/合并/跨轨拖拽与 pin 族两阶段挂载、
  `project_changed` 派发、工程创建/加载/保存入口）。仍无播放设备适配、
  export 请求、渲染取消、tempo 编辑或 UI。

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
3. 在 Neumu application service 上补齐 playback/export 请求契约（编辑
   facade 与 `project_changed` 派发已完成）；UI 只提交意图并展示权威状态，
   不复制音频、check 或任务语义。手势缺口与施工批次见
   [`docs/plan-2026-09-ui-facade-gestures.md`](docs/plan-2026-09-ui-facade-gestures.md)。
4. ~~逐帧曲线 channel（energy/breathiness/voicing 的手绘编辑）~~本版本不做。

## 不变量

- Coconut 是编辑状态、History、patch 与序列化的事实来源。
- CoconutOi 只翻译 Coconut intervention 与 Oi data，不拥有音素对齐、轨道调度或混音语义。
- 多轨调度、混音、总线和导出汇聚由 Neume 声明的 Oi graph/steps 实现。
- 音素类型、帧网格、G2P 和元音锚定属于 DiffSinger adapter/worker。
- pin 底料是输入事实签名（歌词/显式音素/melisma 归属/声库摘要），推导为
  纯函数、不经引擎；digest 裁决在 probe 期统一冲突界面，Coconut 静态
  check 不过问；G2P/组展开只服务于消费边界与 re-patch 可表达性。
- 声库路径不持久化，模型和生成 WAV 不提交。
- melisma 必须由显式 syllable group 表达，不在 worker 中启发式猜测。
