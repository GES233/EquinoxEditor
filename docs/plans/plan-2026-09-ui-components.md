# 草案：UI 组件清单与消息契约（2026-09）

> 状态：**草案，评审中**。本文只定"有什么组件、每个组件说什么话"，不定
> 宿主（LiveView hook 还是 SPA）与视觉设计。
>
> 前置阅读：`apps/neumu/docs/facade-protocol.md`（facade 契约，本文所有
> 数据形状的唯一真相）、根 `CONTEXT.md`（术语正名表）。

## 定位与原则

UI 是 Neumu facade 的薄壳。三条纪律（即 `Neumu.RefClient` 的全部纪律，
任何宿主的前端客户端都照此实现）：

1. 组件持有的是**镜像**：权威状态来自 `snapshot/1` 与各只读查询，本地
   编辑预览（如卷帘上的拖拽）只是缓存，不许发明语义；
2. intent 落笔才提交；编辑类回复 `{:ok, history_pin}` 后镜像失效，按
   `project_changed` 事件或显式 sync 重拉；
3. pin 族手势遇 `{:error, {:stale_pin, _}}` 重新预检后按最新镜像重放。

横切约定：

- **组件之间不直接通信**，都经过 facade。例：历史组件跳了 cursor →
  一次 `project_changed` → 卷帘/混音等各自重拉，天然一致。
- 事件只携 identity（`project_id`/`history_pin`/`job_id`/`artifact_id`），
  不携状态本体；制品 WAV 不进事件，经 `artifact/1` 单独取。
- UI 不复制音频、check 或任务语义；structured tagged error 保持机器
  可判，tuple→list 的 JSON-safe 化只在壳层末端做（参考
  `NeumeLab.Board` 的 sanitize 段）。
- 组件对宿主的接口收窄为：**入** = 快照投影子集 + 查询回复 + 三种事件；
  **出** = facade 封闭命令集的子集。组件不认识 Phoenix/Elixir。

## 组件清单

### 第一档：facade 现成支撑，可直接开工

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
- **C5 试听**第一版只做"渲染完成 → 播整个 WAV 制品"（`<audio>` 级），
  不做 seek-to-tick——播放/定位需要 playback 契约，本版本没有
  （AGENTS.md 当前限制）。多制品并排 A/B 靠 `source_pin` 标注。

### 第二档：组件想得通，需先补小的后端契约

| # | 组件 | 缺口 |
|---|---|---|
| C7 | **历史记录（树视图）** | History 是**undo 树**（不是 DAG：每节点单 `parent`，分叉只在"undo 后另写"处产生，遍历按全局 seq），节点有 `label`/checkpoint，窗口 `root_seq..seq`。facade 已透出 `history_pin`/`can_undo`/`can_redo` 与只读查询 **`history_tree/1`**（已实施：plain-data 节点列表 + cursor + 窗口界）。剩余缺口：cursor 跳转手势（现在只有 undo/redo 逐步走；`MultiTrack.at_pin/2` 只服务渲染物化，不动 cursor）——封闭命令集的小扩展，不破坏现有契约 |

C7 的 `history_tree/1` 形状（已实施）：

```text
{:ok, %{
  root_seq: integer,          # 窗口根（squash 后最老保留节点）
  seq: integer,               # 最新 seq
  cursor: integer,            # = 当前 history_pin
  nodes: [%{seq, parent, label | nil, has_checkpoint: boolean}]
}}
```

只读、不产生历史边、不派发事件；undo/redo/跳转后由 `project_changed`
驱动重拉。

### 第三档：占位，等 Oi 接管后再立项

| # | 组件 | 约束 |
|---|---|---|
| C8 | **渲染管线 DAG 视图** | 渲染管线才是真 DAG（Oi 图）。但今天渲染对 UI 只暴露 `RenderJob` 状态机 + 逐窗 `:hit/:miss`；dynamic DAG 依赖 AGENTS.md 下一步第 1 条（Oi 接管多轨调度与层级缓存），图的形状/缓存键/取消语义未定，现在设计等于赌未定的契约。本版本只做 C5 内的"任务列表 + 逐窗缓存命中"展示 |

## 事件流总图

```text
组件 intent → facade 命令 → ProjectServer 落历史边
                          ↘ 查询类：纯读取，不落边
落边 → {:project_changed, project_id, history_pin} → 各组件镜像失效 → 重拉
渲染 → {:render_changed, job_id, status} / {:artifact_ready, job_id, artifact_id, source_pin}
```

## 开放问题队列

1. ~~C9 归属：卷帘子交互 vs 独立面板~~ **已拍板（2026-09 评审）**：冲突
   与 pin 参数编辑都收进卷帘（C1），不设独立冲突中心/时长面板。
2. ~~C7 的历史树只读查询~~ 已实施（`Neumu.history_tree/1`）。剩余：
   cursor 跳转手势是否进下一批 facade 手势计划
   （`apps/neume/docs/plan-2026-09-ui-facade-gestures.md`）。
3. 宿主选型（LiveView + JS hook vs SPA + Channel）——按"组件先行、
   宿主后接"，不影响本文任何组件契约。
4. 组件实现技术（canvas vs SVG）在 C1 原型阶段定，契约层不关心。
