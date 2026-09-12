# CONTEXT.md

本文件是本仓库的**领域正名表**：一个概念在各层叫什么、为什么必须这么叫，
以及跨层的映射规则。2026-09-12 由术语对齐 grill 会话建立（此前仓库没有
`CONTEXT.md`，也没有 `CONTEXT-MAP.md`——本仓库是单 context）。

范围：跨层命名（文档 ↔ `coconut` ↔ `coconut_oi` ↔ `neume` ↔ `neume_opu_ds`
↔ `neumu`）。本次只收敛**语言**；代码标识符改名另立批次，候选名单见文末。
三条难逆转的规则已固化为 ADR：
`docs/decisions/0001-intervention-carriers-patch-and-pin.md`。

## 已拍板

| # | 决定 | 日期 |
|---|---|---|
| Q1 | 对齐强度 = 语言层唯一正名 + 跨层映射表；代码标识符本次不改，只产出候选清单 | 2026-09-12 |
| Q1 | 文档模型：根 `CONTEXT.md` 为正名表；ADR 只在「难逆转 + 无上下文会意外 + 真实权衡」三条同时成立时开，预计 `docs/decisions/0001-*.md`（分层命名：载体 vs 身份） | 2026-09-12 |
| Q2 | 术语收敛规则 = **层内唯一律**：同一层内一个词只许一个意思；跨层同名允许但语义必须一致，否则登记两个概念并改名 | 2026-09-12 |
| Q3 | **干预 intervention** = 领域概念正名（用户对模型生成施加的意图）；收回它指 patch / pin 的资格 | 2026-09-12 |
| Q4 | **probe** 归「向引擎索取一次物化中间结果」；Host → Neume 那一侧正名为「pin 挂载预检 / 预检令牌（preflight）」 | 2026-09-12 |
| Q5 | 裸词 **pin** = 用户干预的身份单元；History cursor 一律写全限定词（`history_pin` / `source_pin` / `at_pin`） | 2026-09-12 |
| Q6 | 裸词 **base** = 底料（被签名的底层值）；引擎输入底座一律写 `base interventions`，History 窗口根正名为 **root_seq** | 2026-09-12 |
| Q7 | 裸词 **patch** = `Coconut.Edit.Patch`（载体）；`Tamale.Patch` 正名「tamale patch / 底座」，必须写全名 | 2026-09-12 |
| Q8 | ADR 落笔：`docs/decisions/0001-intervention-carriers-patch-and-pin.md`（载体 patch/pin + 层内唯一律 + 限定词制） | 2026-09-12 |

## 分层命名规则

**已拍板（Q2, 2026-09-12）：层内唯一律。** 同一层（同一 app / 同一命名空间）
内，一个词只允许一个意思；跨层同名允许，但语义必须一致，否则登记为两个概念
并改名。

**附则（Q4）：动作词必须能看出方向与产出物。** 两义的差别不只是"谁问谁"——
Host → Neume 的预检产出的是**乐观并发令牌**（地址 + 当前 History cursor），
Neume → 引擎的 probe 产出的是**物化结果**。因此：`probe` 不带限定词时默认指
Neume → 引擎；凡 Host/facade 方向取挂载前状态，一律说"预检（preflight）"。

**附则二（Q6）：限定词制。** 裸词留给该层/该领域的核心概念，任何次要义必须带
限定词。已按此收敛的三例：Host 方向的取状态动作 → `preflight`；History cursor →
`history_pin`；历史窗口根 → `root_seq`。同一条也适用于 `Tamale.Patch`：它必须
写全名，不得简写成 patch（见 Q7）。

- D9 `patch`——已按 Q7 收敛：裸 patch 归 `Coconut.Edit.Patch`，`Tamale.Patch`
  写全名。

判定记录：

- D5 `probe`——neume/neumu 层内两义，**违规**，已按 Q4 收敛。
- D3 `channel`——**已勘误，不是分歧**（见勘误）。
- D2 `interventions`——同层同名、同形、不同阶段，**不违规**，散文里区分
  base / resolved 即可。
- D7 `pin`——neume/neumu 层内两义（History cursor vs 在册干预载体），**违规**，
  已按 Q5 收敛。
- D8 `base`——coconut 层内多义（History `base_seq` 窗口根 vs 底料 vs base
  interventions），已按 Q6 收敛。

## 概念登记

| 概念 | 领域正名 | coconut | coconut_oi | neume | neumu |
|---|---|---|---|---|---|
| 用户对模型生成施加的意图 | **干预 intervention** | 概念（载体是 patch） | 概念（翻译成 Oi data） | pin 是它的身份具体化，不叫 intervention | 手势 |
| 编辑载体（可 undo 的历史单元） | patch | `Coconut.Edit.Patch` | — | — | — |
| 底座 patch（依赖层） | tamale patch | `%Patch{tamale_patch: %Tamale.Patch{}}` | — | — | — |
| 引擎消费的数据切面 | channel | `Coconut.Render.Channel`；`Coconut.Render.Channels.{Lyric,Duration,Pitch}` | `port_map` | `Neume.Channels.{PitchPin,DurationPin}`——就是 channel，只是多实现 `Neume.Pin.Semantics` | 手势参数 `channel ∈ {:pitch, :duration}`（= channel 键） |
| 引擎 base 输入 | base interventions | `Coconut.Session.interventions` | — | `Neume.TrackRuntime.interventions` | — |
| 折叠后的引擎输入 | resolved interventions | `Resolve.run_check/3` 返回的 `:interventions` | `Assemble.assemble/2` | — | — |
| 身份单元（存活/裁决对象） | pin | 无此概念 | — | `Neume.Pin.*`、`Neume.Identity` | snapshot 的 `pins` |
| pin 承载的领域对象分类 | carrier | — | — | `:score` / `:phonology` / `:correspondence` | — |
| 身份底料（被签名的输入事实） | base | `base_digest`（tamale） | — | base schema `pin_input_v1` / `score_region_v1` / `phoneme_correspondence_v1` | 预检令牌不携底料 |
| 挂载前预检（两阶段挂载第一阶段） | **pin 挂载预检 preflight** | — | — | `Neume.MultiTrack.preflight_pin/3`、`Editor.derive_base/2` | `Neumu.preflight_pin/3`；令牌 = `%{track_id, note_id, history_pin}` |
| 历史窗口根（最老仍保留的节点） | **root_seq** | `Coconut.Edit.History.root_seq` | — | — | `ProjectSnapshot` 用它算 `can_undo` |
| History cursor（版本钉） | **history_pin（版本钉）**；裸词 `pin` 不指 cursor | `Tamale.Anchor.at_version`（同一个"钉"） | — | `Editor`/`RenderJob.source_pin`、`at_pin/2` | `history_pin`、事件与任务里的 `pin` |

## 分歧清单（grill 对象）

| # | 分歧 | 层次 | 状态 |
|---|---|---|---|
| D1 | `intervention` 在文档里是万能词（动作 / 载体 / 引擎输入 都叫它） | 文档 ↔ 全部层 | 已拍板（Q3）：只做领域概念正名 |
| D2 | `interventions` 键同时指 base 输入与折叠结果 | coconut 层内 | **已勘误**：不是分歧 |
| D3 | `channel` 三层三义 | 跨层 | **已勘误**：不是分歧 |
| D4 | "patch" 跨层重名：`Tamale.Patch`（依赖层）与 `Coconut.Edit.Patch`（载体层） | 依赖 ↔ coconut | 开放（Q6） |
| D5 | `probe` 层内两义：向引擎索取物化结果 vs 纯派生 | 层内 | 已拍板（Q4） |
| D6 | pin 与 patch 的边界叙述：谁是身份、谁是载体 | neume ↔ coconut | 开放（ADR 0001 候补） |
| D7 | `pin` 层内两义：History cursor vs 在册干预载体 | neume / neumu 层内 | 已拍板（Q5）：裸 pin 归干预 |
| D8 | `base` 多义：History `base_seq`（窗口根）vs 底料 vs base interventions | coconut 层内 + 跨层 | 已拍板（Q6）：裸 base = 底料 |
| D9 | `patch` 三处同名：`Coconut.Edit.Patch` / `Tamale.Patch` / `Coconut.Pickle.Patch` | 依赖 ↔ coconut | 已拍板（Q7）：裸 patch 归载体，tamale 写全名 |

## 勘误（勘查中改正的初始判断）

1. `interventions` 不是同名不同物。我最初把 `Coconut.Session.interventions`
   （base 输入）与 `Coconut.resolve/2` 返回值里的 `interventions`（base 叠折叠
   结果）判为「同名不同物、语义相反」。核对
   `apps/coconut/lib/coconut/render/resolve.ex:78` 后更正：两者是**同一类型同一
   形状**（`%{port_ref => %{input: term()}}`）在不同阶段的值，属于「同名同物、
   不同阶段」。散文里需要区分的是 base / resolved，不是两个概念。
2. `channel` 不是三层三义。我最初以为 neume 的 `Neume.Channels.*` 是"pin 语义
   模块"借用了 channel 这个词。核对 `apps/neume/lib/neume/multi_track.ex:678`
   （`%{duration: Neume.Channels.DurationPin, pitch: Neume.Channels.PitchPin}`）
   与 `apps/neumu/lib/neumu/project_server.ex:452-463` 后更正：三层说的是**同一个
   东西**——引擎消费的数据切面；pin 以它为寻址坐标（`patch.channel`）。三处同名
   且语义一致，符合层内唯一律，不需要改名。

## 语言层改动清单（Q3 / Q4 / Q5 拍板，已于 2026-09-12 施工）

### Q3：neume 层散文里拿 intervention 指 pin 的地方一律改 pin

| 位置 | 现状 | 改为 |
|---|---|---|
| `AGENTS.md:142` | "identity-base pitch intervention" | "identity-base pitch pin" |
| `apps/neume/README.md:70` | "pitch intervention 可经 `Editor.mount_pitch/3` 挂载" | pitch pin |
| `apps/neume/README.md:113` | "增量型干预（preserve、相对旧值）走 output base" | patch（此处指 patch，不是 pin） |
| `apps/neume/lib/neume/pitch_curve.ex:3` | "Pitch intervention 的版本化曲线 payload" | pitch pin payload |
| `apps/neume/lib/neume/editor.ex:348` | "挂载 identity-base Bezier pitch intervention" | pitch pin |
| `apps/neume/lib/neume/debug_export.ex:8` | "`curves` 是 pitch intervention 控制点" | pitch pin 控制点 |
| `apps/coconut/lib/coconut/edit/track.ex:7` | "the track's patches — interventions" | 删去破折号后半句 |

### Q4：Host → Neume 那一侧改说"预检"

| 位置 | 现状 | 改为 |
|---|---|---|
| `apps/neumu/docs/facade-protocol.md:104` | "1. `probe_pin/3` → …（纯派生、即时返回）" | 说"预检（preflight）" |
| `apps/neume/docs/plan-2026-09-ui-facade-gestures.md:10-14` | "probe（G2P + 组展开，真声库要调 worker）……UI 需要『probe 待定』态" | 改说预检，并加勘误注记：2026-09-05 挂载纯化后不再调 worker，「probe 待定」态不再需要（据 `decision-2026-09-pin-input-base.md:39-41`） |
| `apps/neumu/lib/neumu.ex:472-481` | `probe_pin/3` 的 `@doc`："probe 令牌……UI 重新 probe 后重试" | 预检令牌……重新预检 |
| `apps/neume/lib/neume/multi_track.ex:417-422` | `probe_pin/3` 的 `@doc` | 同上 |
| `apps/neumu/lib/neumu/project_server.ex:449-451,484` | 注释"probe 令牌绑定 track/note 与 pin" | 预检令牌 |
| `apps/neume_lab/lib/neume_lab/board.ex:10,184` | "一次走完 probe → mount"、"stale 时重新 probe 重试一次" | 预检 → mount、重新预检 |

### Q5：裸 pin 指 cursor 的散文改 history_pin

全仓 `按 pin` 共 12 处命中（含本文件的一行表格，实际改写 11 处 / 8 个文件）：
`AGENTS.md` ×3、`neumu.ex` ×2、`project_server.ex` ×2、`multi_track.ex`、
`plan-2026-09-ui-facade-gestures.md`、`neume_lab.ex`、`board.ex`、
`notebooks/lab.livemd`——一律改为 `按 history_pin`；`project_server.ex:346`
的"不存在的 pin"注释一并改为 `history_pin`。

### Q6：base 的限定词

- 引擎输入底座一律写 **base interventions**，不裸叫 base。
- History 的窗口根一律写全 `root_seq` 或称"历史窗口根"，禁止简写成 base。
  现有散文未见违规，作为新增文档的约束。

### Q7：tamale patch 必须写全名

- 散文统一说"tamale patch"（中文可说"底座"），禁止裸 patch 指它。现有散文未见
  违规；`resolve.ex:37` 的 `patch.tamale_patch.base_digest` 已随字段改名
  （2026-09 改名批次包 3）更新。

明确不动：`design-2026-08-orchid-intervention.md` 文件名与正文（自洽）、
`orchid_intervention` 依赖与 hook 名（外部契约）、所有 `interventions` 字段名、
coconut `resolve_stage() :: :probe` 与 `stage: :probe` 冲突界面（义 A）。

## 候选改名清单

> 施工交接（逐项落点、陷阱、验收、提交切分）见
> `docs/plans/plan-2026-09-rename-batch.md`。

**2026-09 改名批次已施工完毕**，原清单全部条目已移出：

- probe 双义（Q4）与 pin 双义（Q5）条目 → 包 1 `c7a1955`
  （`refactor(neumu,neume,neume_lab): 预检正名 preflight_pin/derive_base，
  cursor 键统一 history_pin`）；施工时拍板扩面两处：`check/1` 与
  `note_phonemes/1` 返回键 `pin` → `history_pin`，`submit_render/2`
  选项 `:pin` → `:history_pin`。coconut 侧 `Coconut.mount/6` 的 `pin:`
  选项拍板不动。
- base 多义（Q6）条目 → 包 2 `fb57948`（`refactor(coconut):
  History.base_seq 正名为 root_seq，旧档读档兼容`）。
- patch 同名（Q7）条目 → 包 3 `2511493`（`refactor(coconut,neume,neumu):
  Patch.patch 字段正名为 tamale_patch，旧档读档兼容`）。

### 剩余候选

- `Coconut.mount/6` 与 examples 里的局部变量 `probe`（试用 patch 之义，
  `%Patch{track_id: ..., anchor: ..., channel: ...}` 半成品）：与 Q4 的
  probe 正名不同义，改名批次中登记但未动，待另立批次决定（如
  `trial_patch`）。

## 开放问题队列

1. ~~Q2 分层命名规则~~ 已拍板：层内唯一律
2. ~~Q3 `intervention` 的最终身份~~ 已拍板：领域概念正名，不得指 patch/pin
3. ~~Q4 `probe` 双义的收敛~~ 已拍板：probe 归引擎侧，Host 侧叫预检
4. ~~Q5 `pin` 层内两义~~ 已拍板：裸 pin 归干预，cursor 写 `history_pin`
5. ~~Q6 `base` 的多义~~ 已拍板：裸 base = 底料，窗口根叫 `root_seq`
6. ~~Q7 D9：`patch` 三处同名~~ 已拍板：裸 patch 归载体，tamale patch 写全名
7. ~~Q8 ADR 0001~~ 已落笔：`docs/decisions/0001-intervention-carriers-patch-and-pin.md`
8. Q9 语言层改动清单的施工时机（当场做 vs 另立批次）
