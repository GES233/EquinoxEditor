# 草案：UI 组件清单与消息契约（2026-09）

> 状态：**草案，评审中**。本文只定"有什么组件、每个组件说什么话"，不定
> 宿主（LiveView hook 还是 SPA）与视觉设计。
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
2. 宿主选型（LiveView + JS hook vs SPA + Channel）：组件原型可先行，
   事件桥与制品播放接入在宿主选定后落实。
3. 组件实现技术（canvas vs SVG）在 C1 原型阶段定。
