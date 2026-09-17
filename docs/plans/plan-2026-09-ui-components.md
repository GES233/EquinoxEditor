# 草案：UI 组件清单与消息契约（2026-09）

> 状态：**草案，评审中**。本文只定"有什么组件、每个组件说什么话"，不定
> 完整视觉设计。2026-09-17 已选 Svelte + TypeScript / Phoenix Channel，
> 第一个单音符里程碑落在 `apps/equinox_web`；运行与边界见其 README。
>
> 前置阅读：`apps/neumu/docs/facade-protocol.md`（facade 契约，本文所有
> 数据形状的唯一真相）、根 `CONTEXT.md`（术语正名表）。

## 定位与原则

UI 是 Neumu facade 的薄壳。宿主统一调用 facade、订阅事件并维护一份工程
快照，组件消费投影、提交 intent。沿用 `Neumu.RefClient` 的三条纪律：

1. 宿主持有的是**镜像**：权威状态来自 `snapshot/1` 与各只读查询，本地
   编辑预览（如卷帘上的拖拽）只是缓存，不许发明语义；
2. intent 落笔才提交；编辑类回复 `{:ok, history_pin}` 后镜像失效，按
   `project_changed` 事件或显式 sync 重拉；
3. pin 族手势遇 `{:error, {:stale_pin, _}}` 重新预检后按最新镜像重放。

横切约定：

- `project_changed` 由宿主处理：重拉一次快照，再把同一份快照的投影交给
  卷帘、轨道和混音等组件。选区、缩放、拖拽预览由客户端共享，不经过 facade。
- `check/1`、`note_phonemes/1` 按交互需要查询；回复的 `history_pin`
  与当前镜像不符时失效，不把旧冲突或音素结果画到新谱面上。
- 事件只携 identity（`project_id`/`history_pin`/`job_id`/`artifact_id`），
  不携状态本体；制品 WAV 不进事件，经 `artifact/1` 单独取。
- UI 不复制音频、check 或任务语义；structured tagged error 保持机器
  可判，tuple→list 的 JSON-safe 化只在壳层末端做（参考
  `NeumeLab.Board` 的 sanitize 段）。
- 组件对宿主的接口收窄为：**入** = 快照投影子集 + 查询结果；
  **出** = 编辑或查询 intent，由宿主映射到 facade。组件不认识 Phoenix/Elixir。

## 组件清单

### 第一档：已有 facade 支撑

下表列出宿主需要的数据与调用，不要求每个组件自行订阅或访问后端。

| # | 组件 | 入（消费） | 出（intent → facade 命令） |
|---|---|---|---|
| C1 | **钢琴卷帘**（含 pin 参数编辑与冲突标记） | snapshot `tracks[].notes` 与逐轨 `pins` 投影、`time_sigs`、`tempo_steps`（ruler）、`check/1` 的 entries、`note_phonemes/1` 的 segment ref | 音符手势：`insert_note` / `edit_note` / `move_note` / `delete_note` / `split_note` / `trim_note` / `merge_notes` / `drag_note_across_tracks`；pin 族：`preflight_pin` → `mount_pitch` / `mount_pitch_curve` / `mount_phoneme_duration`，`repatch` / `replace_pin` / `unmount_pin` |
| C2 | 轨道列表 / 混音面板 | snapshot `tracks[]`（id/name/mix/globals/声库绑定） | `add_track` / `remove_track` / `rename_track` / `update_mix` / `update_globals` |
| C3 | 声库选择器 | `list_voicebanks/1` 回复、snapshot 逐轨声库签名 | `rebind_voicebank` |
| C4 | tempo / 拍号编辑器 | snapshot `tempo_steps`、`time_sigs`；物理时长换算 `region_duration_sec/3` | `insert_tempo_step` / `edit_tempo_step` / `delete_tempo_step` / `set_time_sigs` |
| C5 | 试听面板 | `list_render_jobs/1`（`source_pin`/`artifact_id`/status）、`render_changed` / `artifact_ready` 事件、`artifact/1` 取 WAV | `submit_render`（可带 `history_pin:` 做 A/B）、`export_artifact` |
| C6 | 工程管理 | create/load/save 回复 | `create_project` / `load_project` / `save_project` / `close_project` |

C1 卷帘的展开（**评审拍板 2026-09：冲突与 pin 参数都在卷帘上，不设独立
冲突中心**）：

- **音符编辑**是交互重心：拖拽/框选/本地预览全在客户端，落笔才发
  intent；`{:error, {:stale_pin, _}}` 只出现在 pin 族，音符手势不涉及。
  melisma 续音（`metadata["melisma"] == "continue"`）的显示归卷帘。
- **pin 参数编辑**为卷帘上的音符子交互：选中音符 → pitch 点列/Bezier
  直接绘在卷帘 pitch 层；音素时长为音符下方的音素条（segment ref 来自
  `note_phonemes/1`，UI 拿着 ref 直接撰写 `phoneme_duration_v2`
  envelope）。
- **冲突标记**：check entries 携 `track_id`/`note_id`/`span`，标注在卷帘
  对应音符上；repatch/replace/unmount 从标记处发起。两阶段挂载手势
  （预检令牌 → 挂载 → stale 重放）同样从卷帘发起。
- **C5 试听**第一版只做"渲染完成 → 播整个 WAV 制品"（`<audio>` 级）。
  `artifact/1` 返回服务端文件路径，宿主需提供可播放的 URL 或本地文件桥接
  （见 facade 协议的播放/导出契约）。谱面 tick 联动定位留待后续；
  多制品并排 A/B 靠 `source_pin` 标注。

### 第二档：可先只读展示的历史树

| # | 组件 | 现有支撑与边界 |
|---|---|---|
| C7 | **历史记录（树视图）** | `history_tree/1` 已提供节点、父子关系与 cursor，形状见 facade 协议。History 每节点单 `parent`，undo/redo 按全局 seq 遍历，可能跨分支；树边表达状态来源，不表达 undo 的下一步。可先展示树与当前 cursor，沿用现有 undo/redo。点击节点跳转尚无 facade 命令，`MultiTrack.at_pin/2` 只物化状态、不移动工程 cursor |

C7 显示时由宿主按需查询；`project_changed` 后失效并重查，回复的 cursor
须与当前快照的 `history_pin` 一致。

## 事件流总图

```text
组件 intent → 宿主 → facade 命令或查询
工程变化 → project_changed → 宿主重拉快照 → 各组件消费同一快照的投影
渲染变化 → render_changed / artifact_ready → 宿主查询任务或制品 → 试听面板
```

## 开放问题队列

1. cursor 跳转手势是否进下一批 facade 手势计划
   （`apps/neume/docs/plan-2026-09-ui-facade-gestures.md`）。
2. 第一个里程碑采用 Svelte + TypeScript / Phoenix Channel；事件桥已接通，
   制品播放接入仍待施工。
3. C1 原型采用 SVG；更大工程规模的性能验证与 Canvas 取舍留待后续。
4. 用户澄清 pitch intervention 的目标是修改模型给出的 pitch 结果。
   当前谱面绝对 pin 尚未覆盖此目标；需明确模型输出底料、时域/对齐依赖、
   漂移裁决与重挂规则。见下方 Path 2 试用记录及纠正。

## 首个里程碑（2026-09-17）

已接线：工作区骨架、单音符横向拖动与歌词/音高表单、撤销/重做、声库
选择器、组件状态样例页、真实 Neumu 提交与快照刷新、断线重连。
演示条目使用内置 mock runtime，服务重启后重新起步；无声学推理和保存 UI。
外围声库组件交给 Kimi Code，主代理统一数据契约、宿主、卷帘与集成验收。

## Path 2：音高干预闭环（2026-09-17）

已接 C1 的音高点列草稿、挂载/替换、异步 check、卷帘内标记、
repatch 降级提示和移除/撤销；默认新建 `score_pitch_v2`。v2 改词不冲突，
浏览器用越界控制点验收检查/修复；legacy 身份冲突与重签由 Channel 测试覆盖。
点列表单初稿由 Kimi Code 后台完成，宿主接线与验收由主代理完成。
path 1（扩展音符/工程操作）和 path 3（渲染/试听）等待进一步设计。

### 试用记录：改谱面音高后干预仍存活（2026-09-17）

用户在 C4（MIDI 60）音符上添加音高点列，再将谱面音高改为 B♭3
（MIDI 58）：蓝线保持原来的纵向位置，检查通过。这符合当前已实现的
`score_pitch_v2` 语义：横轴是相对音符起点的 tick，纵轴是绝对 MIDI。
横移音符会携带曲线一起移动；修改谱面音高不会自动移调曲线。底料
`score_region_v1` 钉住 track/note/坐标系，不签谱面音高。

“检查通过”表示当前检查范围内没有阻止应用的身份或可表达性问题，
不表示干预曲线贴合谱面音高，也不评价音乐效果。演示使用 mock runtime，
该结果不构成真实声学模型的验证。依据见
[pin carrier 设计](../../apps/neume/docs/design-2026-09-pin-carriers.md) 的
survival matrix、`Neume.Pin.Lower` 的时间平移实现，以及
`apps/neume/test/neume/score_pitch_v2_test.exs` 的“改音高与邻居编辑存活”测试。

初步讨论中的假设（随后由用户纠正）：“音高调校”可能被理解成“在谱面音高基础上叠加起伏”。
若按这个意图操作，C4 降至 B♭3 时曲线应整体下降 2 个半音；这需要相对
谱面音高的偏移语义，当前原型未实现。候选方向是明确区分“固定音高”
和“相对谱面音高偏移”，并说明各自随谱面编辑的行为。是否同时提供、
默认项和具体文案均待定；本记录不改变现有载体定义或 UI 行为。

### 目标纠正：基于模型 pitch 结果的干预（同日）

用户明确：最初的 pitch intervention 是基于 pitch 模型给出的结果进行
修改，这也是设计 Pure-FP ONNX 的动机。改歌词可能改变 phoneme duration，
进而改变 pitch 的有效域及对齐；控制点仍落在音符区间内，并不足以证明
原修改仍成立。这是干预底料的缺口，不只是 UI 文案或绝对/相对值的选择。

原始依据是 [Coconut 干预设计 §6.3](../../apps/coconut/docs/design-2026-08-orchid-intervention.md#63-参数曲线extract--edit--land已定)：
extract 提取 stage 输出投影，edit 修改，land 将干预绑定到提取时的底料；
上游编辑使底料漂移时需裁决。§6.6 后来区分了不依赖预测值的绝对 pin
与依赖 output base 的修改；当前 v2 与 UI 只实现前者，不能据其测试通过
宣称用户要求的模型结果编辑已完成。

数值编码和依赖关系必须分开：即使编辑后保存绝对 MIDI，修改仍可能依赖
用户当时看到的预测曲线与时域；改成相对谱面音高偏移也不能补足这份依赖。
Pure-FP 使固定完整执行条件下的预测底料可复现，避免随机漂移混入裁决，
但不能保证改词或上游 duration 变化后底料不变。

实现方向收敛为复用现有机制：Neume 定义底料与 check/repatch 语义，
`neume_opu_ds` 提供模型输出及对齐，并通过 `OrchidIntervention.Operate`
应用修改；Coconut 继续管理 History，CoconutOi 保持薄翻译。无需另建干预
框架。沿用 §6.6 的有效上游输出原则，不把待验证干预自身的结果循环作为
底料。具体接线后续讨论，现有 schema、实现与历史工程含义不作静默改写。

继续扩展 C1 前需明确两个数据缺口：`note_phonemes` 只有音素和
stable ref，没有预测时长；真实比例音素条及模型参考音高曲线需要带来源
版本的分析投影。多音符原子编辑也没有通用 facade 入口，不能逐个提交来
冒充一次可撤销的批量手势。
