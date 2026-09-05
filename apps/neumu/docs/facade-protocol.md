# Neumu facade 协议（UI 契约）

> 状态：当前实现的契约冻结（2026-09-05）。共享前端的开发依据；
> 参考实现见 `apps/neumu/test/support/ref_client.ex`，端到端场景见
> `apps/neumu/test/neumu/contract_test.exs`。改动此文件意味着改动
> 对外契约，需同步参考客户端与场景测试。

## 边界原则

1. UI ↔ Neumu 之间只传**可序列化 plain data**：不含 PID、函数、引用、
   struct（快照与回复都递归满足，有测试锁定）。
2. **结构化数据字段 JSON-safe**（2026-09-05 起）：快照、check 条目、
   任务/声库列举、probe 令牌等投影中不出现 tuple——tagged tuple
   一律降为"位置即标签"的 list（`{1, {4, 4}}` → `[1, [4, 4]]`，
   `{:compound, [2, 3], 8}` → `["compound", [2, 3], 8]`，
   `span: {s, e}` → `[s, e]`，`phrase_id: {track_id, tick}` →
   `[track_id, tick]`）。`Neumu.CheckReport` 对条目做深扫，新增字段
   自动满足；有递归断言锁定（tuple 是 plain data，
   `assert_plain_data` 抓不到这类泄露）。
3. **例外：`reason`/`error` 字段保持结构化 tagged term**——Elixir
   调用方需要机器可判，UI 只展示。壳层推给浏览器前做末端转换
   （tuple→list 或直接 inspect 字符串化），一行递归 walker 的事。
   atom key/值在 JSON 中即字符串。
4. **事件只携带 identity**（重查所需的 id/pin），不携带状态本体；
   收到事件后重新查询权威快照。
5. 所有编辑经封闭命令集串行落账；UI 不持有/修改 `Neume.MultiTrack`。
6. 编辑手势成功且实际产生 History 边 → 返回新 `history_pin` 并派发
   一次 `project_changed`；无变化编辑返回当前 pin、不派发；失败返回
   tagged error、不改状态、不派发。

## 快照 schema（`Neumu.snapshot/1`）

```text
%{
  project_id: term,
  history_pin: integer,          # History cursor node id
  can_undo: boolean, can_redo: boolean,
  time_sigs: [[bar, sig]],          # JSON-safe：[1, [4, 4]]；sig 另有
                                    # [:standard, n, d] / [:compound, g, d] / :san
                                    #（atom 保留，JSON 中即字符串）
  tempo_steps: [%{id, tick, milli_bpm}],  # 阶梯式 tempo（tick 升序）；
                                    # milli-bpm 整数保精确，÷1000 归壳层
  tracks: [%{
    id, name: String.t() | nil,
    voicebank: %{name, engine, digest} | nil,
    mix: %{gain: float, pan: float, mute: boolean},
    globals: map,                 # 已挂载旋钮，%{energy: 1.5} 等
    notes: [%{id, start_tick, end_tick, pitch, lyric, annotation, metadata}],
    pins: [%{id, channel: :pitch|:duration,
             anchor: %{type: :ordinal, refs: [note_id], at_version},
             payload: term}]      # pitch 点列 / Bezier plain map / 时长下标列
  }]
}
```

`pitch` 为精确 MIDI 值；小数微分音为十进制字符串，`nil` 表示无音高。

## 命令 → 回复形状

| 函数 | 回复 |
|---|---|
| `insert_note/6` `edit_note/4` `move_note/5` `delete_note/3` `split_note/5` `trim_note/4` | `{:ok, pin}` |
| `merge_notes/3` | `{:ok, pin, %{moved_pins: [%{id, channel, from_note_id, note_id}]}}` |
| `drag_note_across_tracks/7` | `{:ok, pin}` |
| `add_track/4` `remove_track/2` `rename_track/3` `set_time_sigs/2` `rebind_voicebank/3` `update_mix/3` `update_globals/3` | `{:ok, pin}` |
| `insert_tempo_step/4` `edit_tempo_step/3` `delete_tempo_step/2` | `{:ok, pin}`；`{:error, {:tempo_tick_occupied, tick}}` / `{:tempo_first_protected, id}` / `{:invalid_bpm, _}` / `{:invalid_tick, _}` |
| `undo/1` `redo/1` | `{:ok, pin}`；空栈 `{:error, :nothing_to_undo|:nothing_to_redo}` |
| `mount_pitch/5` `mount_pitch_curve/5` `mount_phoneme_duration/5` | `{:ok, pin}`；`{:error, {:stale_pin, _}}` 见下 |
| `unmount_pin/4` | `{:ok, pin}`；无存活 pin `{:error, {:pin_not_found, _, _}}` |
| `repatch/3` | `{:ok, pin, results}`；results 逐项 `%{patch_id, status: :repatched|:degraded, reason?}`；全部降级不落边 |

## 查询（只读，不产生历史边、不派发事件）

- `snapshot/1`、`history_pin/1`
- `list_voicebanks/1` → `{:ok, [%{id, name, mode, engine, digest}]}`
- `check/1` → `{:ok, %{pin, status: :ok|:failed, entries: [...]}}`；
  冲突条目 plain data（patch 只留 `patch_id`/`channel`/`note_id`），
  在调用方进程执行（真声库较慢），不阻塞 ProjectServer
- `list_render_jobs/1` → `{:ok, [%{job_id, source_pin, status,
  artifact_id, error}]}`
- `artifact/1` → `{:ok, artifact}`（含 WAV `path`、采样率、时长等）
- `region_duration_sec/3` → `{:ok, float}`：`[start_tick, end_tick)` 在
  当前 tempo 阶梯下的物理秒数；空 tempo 轨回退 flat 120 BPM

## 事件（`Neumu.subscribe/1` 订阅，幂等）

- `{:project_changed, project_id, history_pin}` — 落边一次发一次
- `{:render_changed, job_id, status}` — `status` 为 `:running|:completed|:failed`
- `{:artifact_ready, job_id, artifact_id, source_pin}`

## pin 族两阶段挂载与 stale_pin

1. `probe_pin/3` → `{:ok, %{track_id, note_id, pin, base}}`（纯派生、
   即时返回；底料为输入事实签名，见
   `apps/neume/docs/decision-2026-09-pin-input-base.md`）。
2. 三个 mount 携 probe 令牌提交；probe 之后工程被编辑则
   `{:error, {:stale_pin, _}}`——**重新 probe 后重放**，令牌绑定
   track/note，张冠李戴返回 `{:error, {:invalid_pin_probe, _, _, _}}`。

## 乐观交互约定（薄壳/共享前端）

- 客户端持有快照镜像；卷帘上的拖拽等交互**本地先画**，落笔才提交。
- 编辑回复 `{:ok, pin}` 后镜像失效：按 `project_changed` 或显式
  `snapshot/1` 重拉。pin 族手势遇 stale 按上节重放。
- 客户端不发明语义：镜像只是权威快照的缓存。

## 播放/导出契约

- **在线播放（chunk/stream）**：壳层按 `artifact/1` 返回的 `path`
  直接以 chunk/range 流式发送 WAV 文件（Phoenix `send_file`/range
  或 webview 本地文件皆可）；facade 不返回流对象（保持 plain-data
  边界）。
- **导出（完整落盘）**：`export_artifact/2` 把制品引用的音频文件
  完整复制到用户指定路径（目录自动创建）；未知制品
  `{:error, {:artifact_not_found, _}}`，文件错误
  `{:error, {:export_failed, _}}`。

## 错误形状

公开边界一律 tagged error，不抛异常；常见形状：`{:unknown_project, _}`、
`{:unknown_track, _}`、`{:unknown_note, _}`、`{:unknown_node, pin}`、
`{:invalid_source_pin, _}`、`{:stale_pin, _}`、`{:pin_not_found, _, _}`、
`{:patch_not_alive, _}`、`{:check_failed, entries}`、
`{:job_already_exists, _}`、`{:job_not_found, _}`、
`{:voicebank_not_registered, _}`。

## 壳实现参考（已查证）

- **Livebook/Kino**：用 `Kino.JS.Live` 自定义 widget（非 Smart Cell——
  Smart Cell 是"UI 生成代码进 notebook"的语义，与编辑器会话不合）。
  kino server 是类 GenServer 进程：`init/2`、`handle_connect/1`
  （给新客户端初始快照）、`handle_event/3`（收客户端 `ctx.pushEvent`）、
  `handle_info/2`（直接收 `Neumu.subscribe` 的三种事件）、
  `broadcast_event`（推给客户端 `ctx.handleEvent`）；支持
  `{:binary, info, binary}` 二进制负载（WAV 不走 base64）；
  `Kino.Audio` 可直接播 WAV。多客户端同步自带。
- **Phoenix Channel**：事件桥 = 订阅 + 直转发 + 客户端重查快照；
  播放走 chunk/range 流式送 artifact 文件；远程部署同此形态。
