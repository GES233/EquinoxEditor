# Neume 开发状态

更新日期：2026-09-03
分支：`neumu-demo`

## 当前定位

Neume 已完成无界面 SVS 内核的第一条真实纵向闭环，但还不是可交互编辑器：

```text
Neume.Editor
→ Coconut Session / History / Resolve
→ CoconutOi.OrchidAdapter
→ Oi（ScorePlan → Inference）
→ 常驻 Python worker
→ DiffSinger duration / pitch / variance / acoustic / vocoder
→ WAV + 实际音素边界
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

## 验证基线

- `mix compile --force --warnings-as-errors`：通过。
- 根目录 `mix test`：`11 passed, 1 excluded`。
- `mix dialyzer`：`Total errors: 0`。
- Python 纯对齐测试：4 项通过，覆盖 V/CV/CCV/CVC、C-G-V 和休止。
- Asaritsu 真声库集成测试：完整推理和 WAV 输出通过；96 tick 的首辅音被
  量化为 9 帧，后续元音仍落在音符起点 ±1 帧。
- `git diff --check`：通过。

真声库测试默认排除，显式运行：

```powershell
cd apps/neume
mix test --include integration test/neume/diff_singer_integration_test.exs
```

可用 `DS_VOICEBANK` 和 `DS_PYTHON` 覆盖本机路径。

## 当前限制

- 仅单轨、单声部、整轨渲染；同轨重叠音符会明确报错。
- 没有 phrase/window 增量渲染和缓存，每次修改仍执行完整推理。
- 当前只有 pitch 和 phoneme duration 两种生成参数编辑。
- 音素边界随 WAV 返回，尚无独立的“只预测对齐、不生成音频”API。
- CoconutOi 的 check 负责静态 channel/port 检查；模型输入检查与 duration
  预测仍在 Oi 的 Inference step 执行期间发生。
- 工程读档后 History 从空树重新开始。
- 没有声库注册表、多轨混音、播放/导出管理或 UI。
- 一个音符仍对应一个音节槽；不会根据歌词或音高隐式猜测 melisma。

## 声库处置

当前本机技术验证使用 Asaritsu。它不进入仓库，也不作为未来公开版本的默认
配布资产。公开给其他人使用前，再替换或重新确认适合分发、展示和联投的声库；
此决定不阻塞当前内核开发。

## 下一步

1. 增加独立的 `analyze/align` 闭环：不运行 acoustic/vocoder 即可取得 G2P、
   duration 预测和音素绝对边界，供编辑器读取。
2. 将模型 check 从 render 内部执行路径中明确分离，给错误和对齐结果稳定的
   Editor API。
3. 实现 phrase/window 切分、局部失效、增量渲染和缓存；缓存边界保持粗粒度，
   不让大型 ONNX 中间张量跨 Orchid step、进程或 ETS。
4. 实现跨音符 syllable group：使用显式相邻音符组身份，定义音素到成员音符
   的归属、延音歌词约定，以及成员移动、拆分、删除后的 patch 存活和冲突
   语义。
5. 扩展 energy、breathiness、voicing 等曲线 channel，并保持参数语义位于
   adapter，不硬编码进 CoconutOi。
6. 增加声库发现/注册表、多轨调度、播放和导出管理。
7. 在 headless API 与增量渲染稳定后接最小钢琴卷帘、音素边界编辑和播放 UI。

## 不变量

- Coconut 是编辑状态、History、patch 与序列化的事实来源。
- CoconutOi 只翻译 Coconut intervention 与 Oi data，不拥有音素对齐语义。
- 音素类型、帧网格、G2P 和元音锚定属于 DiffSinger adapter/worker。
- 声库路径不持久化，模型和生成 WAV 不提交。
- melisma 必须由显式 syllable group 表达，不在 worker 中启发式猜测。
