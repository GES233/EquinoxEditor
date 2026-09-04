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
- 工程保存/加载；History 和最近一次 check 不持久化。
- 无声库时使用确定性的 mock 管线。
- OpenUtau DiffSinger 声库严格扫描：配置、八个 ONNX 模型、语言/音素
  字典、speaker embedding、统一帧网格和路径逃逸检查。
- 声库是仓库外资产；工程仅保存 `{name, engine, digest}`，打开时重新扫描并
  核对摘要。
- 中文歌词通过声库 `dsdict-zh.yaml` 和 `pypinyin` 自动音素化，也支持音符
  metadata 中的显式 `[[language, phoneme]]`。
- 常驻 NDJSON Python worker；ONNX session 按 Python、声库路径、声库摘要和
  worker 路径隔离，摘要变化后不会复用旧 session。
- 稀疏 pitch 控制点，经 note-local pin 投影到实际帧网格。
- 逐音素 duration pin：指定音素固定为给定 tick 时长，其余音素按预测比例
  吸收剩余帧；该 patch 支持 undo/redo。
- OpenUtau 式元音锚定：支持任意数量的词内音素，首辅音向前回排，首个元音
  onset 对齐音符起点；C-G-V 结构以 glide 为锚。
- `RenderArtifact` 返回 WAV 信息、lead-in、逐音素时长，以及带 `note_id` 的
  实际绝对帧边界；展示数据与模型消费的 `ph_dur` 是同一份结果。
- `Editor.analyze/1`：analyze/align 闭环——不运行 acoustic/vocoder 即可取得
  G2P 结果、duration/pitch 预测和元音锚定后的音素边界（`Neume.Analysis`）。
  走独立的 `ScorePlan → Analysis` 编译图（同一 cluster 内 Oi 不分 stage，
  checkpoint 无法停在 Synthesis 前）。
- `Editor.check/1`：稳定的检查 API——先 Coconut 静态 check（patch resolve、
  port 装配、globals 门禁），再跑模型级 probe；所有失败聚合为
  `{:error, {:check_failed, entries}}`，模型侧 entry 形如 `%{kind: :model, ...}`。
  模型检查不再只藏在 render 执行路径里。
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

## 验证基线

- `mix compile --force --warnings-as-errors`：通过。
- 根目录 `mix test`：`53 passed, 5 excluded`（excluded 为真声库集成测试）。
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

- 仅单轨、单声部；同轨重叠音符会明确报错。
- 渲染按窗增量，但 analyze/check 仍是全轨一次性 probe；render 在分窗
  渲染前也会先跑一次全轨 probe 做 pin 身份裁决（probe 须够快，分窗
  probe 是曲目变长后的后备优化）。
- 当前只有 pitch 和 phoneme duration 两种生成参数编辑。
- 分窗规则不含 slice_flag 手动覆盖（音符 metadata 覆盖未移植）。
- 工程读档后 History 从空树重新开始。
- 没有声库注册表、多轨混音、播放/导出管理或 UI。

## 声库处置

当前本机技术验证使用 Asaritsu。它不进入仓库，也不作为未来公开版本的默认
配布资产。公开给其他人使用前，再替换或重新确认适合分发、展示和联投的声库；
此决定不阻塞当前内核开发。

## 下一步

1. 扩展 energy、breathiness、voicing 等曲线 channel，并保持参数语义位于
   adapter，不硬编码进 CoconutOi。增量型曲线干预（"抹平这段颤音"）走
   output base（钉 stage 输出数值，§6.6 第三档）。
2. 增加声库发现/注册表、多轨调度、播放和导出管理。
3. 在 headless API 稳定后接最小钢琴卷帘、音素边界编辑和播放 UI。

## 不变量

- Coconut 是编辑状态、History、patch 与序列化的事实来源。
- CoconutOi 只翻译 Coconut intervention 与 Oi data，不拥有音素对齐语义。
- 音素类型、帧网格、G2P 和元音锚定属于 DiffSinger adapter/worker。
- pin 底料是 probe 物化的音素序列（身份底料）；其物化与 digest 裁决在
  引擎 probe 期，Coconut 静态 check 不过问。
- 声库路径不持久化，模型和生成 WAV 不提交。
- melisma 必须由显式 syllable group 表达，不在 worker 中启发式猜测。
