# UI facade 手势覆盖：缺口分析与施工计划

> 用户：临时文档

状态：第一至三批已完成（2026-09-05）；第四批（tempo）单独立项，未动
范围：Neumu UI-facing facade 的手势/schema 扩展；不动 Coconut/Neume 内核语义

## 已拍板的决定

1. **pin 挂载走两阶段**。probe（G2P + 组展开，真声库要调 worker）在
   ProjectServer 外执行，mount 带 History pin 校验进 server；probe 期间
   工程被编辑则 mount 以 `{:error, {:stale_pin, _}}` 拒绝，UI 重试。
   动机：本地推理预期很慢（OpenUTAU 使用经验），不能在 GenServer 内
   同步阻塞所有编辑/查询。推论：UI 需要"probe 待定"态，不假装它很快。
2. **facade 边界定义 payload schema**：UI ↔ Neumu 之间只传可序列化
   plain data（如 Bezier 曲线用 plain map 而非 `Coconut.Curve.Adapter.Bezier`
   struct）。暂不做版本化。
3. **repatch 回复形状为 `{:ok, history_pin, results}`**（results 逐项
   `:repatched` / `:degraded`）；事件仍只发一次 `project_changed`。
4. **unmount pin 按 `(track_id, note_id, channel)` 寻址**，不透出裸
   patch id。Neume 侧需新增公开卸载手势（现状两层都缺：Coconut 只有
   内部 `discard_patches` command）。
5. **tempo 编辑单独立项**，不进本批（Coconut 无对应 command；Neume 的
   tick→帧换算消费 tempo，改动波及窗口缓存 identity 与 pin 预算）。

## UX 方向（产品差异化判断，作为施工优先级依据）

卖点判断：**把"试听"从阻塞的赌博变成有版本、可复现的资产；把"调校"
从易耗品变成随乐谱演化、坏得明明白白的资产。**

推论：

- 冲突/降级（pin 死亡、repatch 降级）要占 UI 一等位置，不许静默。
- "按 pin 试听对比"（artifact 已带 `source_pin`）尽量早做，成本最低、
  差异度最高。
- 逐帧手绘曲线编辑器不急：pin + repatch 的健壮性叙事优先于曲线完整度。

## 手势缺口矩阵（Coconut → Neume → Neumu facade）

| 手势 | Coconut | Neume | Neumu | 备注 |
|---|---|---|---|---|
| 音符增/删/改/拖 | ✅ | ✅ | ✅ | facade 名 `move_note` = Neume `drag_note` |
| `MoveNote`（纯排序） | ✅ | 未单独暴露 | — | 被 drag 覆盖，不透出 |
| `SplitNote` | ✅ 通用 | ✅ 自有版（右子补 melisma 旗标） | ❌ | 第一批 |
| `TrimNote` | ✅ | ❌ | ❌ | 第三批；melisma 断组自动派生，pin 预算走 check 裁决 |
| `MergeNotes` | ✅（into 留 payload，被吸收者进墓地，需相邻） | ❌ | ❌ | 第三批；歌词拼接/pin 死亡报告/melisma 语义待决定 |
| `DragNoteAcrossTracks` | ✅（fresh id、patch 不迁移） | ❌ | ❌ | 第三批；内容复制策略待决定 |
| pitch 折线/Bezier、duration pin 挂载 | — | ✅ | ❌ | 第二批（两阶段 + schema） |
| `repatch` 批量重挂 | — | ✅ | ❌ | 第二批；回复形状扩为 `{:ok, pin, results}` |
| pin 卸载 | 仅内部 command | ❌ | ❌ | 第二批新增 Neume 手势 |
| `rename_track` | ✅ 轻字段边 | ❌ 一行 wrapper | ❌ | 第一批 |
| `put_track_metadata` | ✅ | ❌ | ❌ | 第一批可选（视 UI 需要） |
| `set_time_sigs` | ✅（不碰 edit_version，render 不消费） | ❌ | ❌ | 第一批；snapshot 补 time_sigs 投影 |
| tempo 编辑 | ❌ 无 command | ❌ | ❌ | 第四批，单独立项 |
| `batch`/`attach_patches`/`discard_patches`/`consume_dead` | 内部组装件 | 间接使用 | 不透出 | 保持内部 |

snapshot 投影对应缺口：pins（存活 patch 的 id/channel/anchor/payload）、
`time_sigs`、`can_undo`/`can_redo`——随对应批次同步扩，不单独改。

## 施工批次

1. **第一批（纯接线，约半天）**：`split_note`、`rename_track`、
   `set_time_sigs`（+ snapshot 的 `time_sigs`）。目的：把"Neume wrapper
   → facade 命令 → 测试矩阵"的模式钉死。
2. **第二批（pin 族，约 1.5–2 天）**：三个 mount、`repatch`、`unmount_pin`
   （Neume 新增）、payload schema、snapshot pins 投影；把
   `apps/neume/test/support/fake_phonemes.ex` 式 expand-capable 假 client
   移植到 neumu 测试支撑。
3. **第三批（领域决定，约 2 天）**：`merge_notes`、`trim_note`、
   `drag_note_across_tracks`。每个先在本文档补两三行语义决定再写码。
4. **第四批（单独立项）**：tempo 编辑（缓存 identity / pin 预算波及面大）。

## 第三批语义决定（2026-09-05 拍板）

- `trim_note`：纯接线（Coconut TrimNote 直通）。melisma 组成员关系按
  旗标 + 贴接自动派生，trim 拖出缝隙即自然断组；duration pin 超预算
  不在手势期拒绝，走 check 裁决（`{:check_failed, _}`）。
- `merge_notes`：`note_ids` 首元素为存活者（into），须按轨序相邻；
  内容保留 into 原样（lyric/phonemes 不拼接，被吸收者内容随音符进
  墓地），melisma 旗标不特殊处理（into 自留，失效旗标由组派生自然
  失效）。**pin 语义按证据修正**（2026-09-05 施工中发现）：Tamale
  transport 对普通 ordinal 锚的 Merge 语义是**重映射到 into**而非判死
  （`deps/tamale/lib/tamale/transport.ex` 的 `remap(%Merge{})` 与模块
  文档"Merge remaps refs onto `into`……judging whether the edit still
  means something is `Tamale.Patch.resolve/2`'s job"）——被吸收音符上
  的 pin 不死，是搬家；"是否还有意义"归 check/repatch 裁决。因此报告
  从 dead_pins 改为 `{:ok, pin, %{moved_pins: [%{id, channel,
  from_note_id, note_id}]}}`（搬家 pin 逐项显式列出，同样满足"不许
  静默"的意图）。
- `drag_note_across_tracks`：内容全量复制（pitch/lyric/annotation/
  metadata），但显式清除 melisma 旗标（跨轨后原组必然不成立，旗标
  留着是死信；目标落点恰贴接时保留会意外成组）。fresh id、pin 不
  迁移（Coconut 底座语义，源音符上的 pin 死进源轨墓地，由快照投影
  与 repatch 流程兜住）。

## 每个手势的标准测试矩阵（照抄即可）

- 成功落一条 History 边、返回新 pin、只发一次 `project_changed`；
- 失败（tagged error）不改状态、不发事件；
- undo/redo 更新 pin 并发事件；
- 保存/重开后手势结果与 History 恢复一致；
- 快照投影与新 pin 一致、无运行时对象泄露；
- （pin 族）probe 期间被编辑 → mount 返回 `stale_pin`，状态不变。

## 明日开工入口

- facade 命令分派：`apps/neumu/lib/neumu/project_server.ex` 的
  `apply_edit/2`；公开 API：`apps/neumu/lib/neumu.ex`；
- 测试：`apps/neumu/test/neumu/facade_test.exs`（现有 12 例可作模板）；
- Neume wrapper 先例：`apps/neume/lib/neume/multi_track.ex` 的
  `remove_track/2`（一行 Command 包装）；
- 验证基线命令见根 `AGENTS.md`；新阶段完成前不自动提交，先人工审阅。
