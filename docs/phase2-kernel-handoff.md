# Phase 2 交接：Kernel 清理与 Domain–Kernel 集成

> **【已废弃 · 仅供考古】** 本文档描述的是 coconut 迁移之前（zongzi 时代，2026-07-25
> 基线）的 kernel 状态与清理计划，保留仅作历史记录。当前架构（coconut + tamale、
> `Coconut.Edit.History` 唯一写入口、`Coconut.Edit.Patch` + `Coconut.Render.Channel`
> 干预模型、equinox 自实现 `Windowing`）见 `docs/coconut-migration.md`。
> 特别注意：正文中多处「当前状态」式断言已随迁移失效——例如 §3 的
> `Zongzi.Timeline.build/1` 反序列化须知、NoteTriplet 干预锚、「把 `:zongzi` 加进
> kernel/mix.exs」等，**请勿据此施工**；§1/§2 的实测基线与耦合结论同样只是
> 当日快照，所涉 legacy 模块大多已在后续迁移中删除。

> 2026-07-25 会话交接文档。基线：master `ca8ada5`（domain Pickle 序列化）+ `8a47c43`（zongzi 迁移）。
> 本文档把两件此前只存在于会话中的内容落盘：**Kernel 死代码清理计划**（§1，已按当日实测修正）
> 与 **ui_shell ↔ kernel 耦合结论**（§2，grep 实测）。
> Phase 2 主体骨架见 AGENTS.md「Phase 2」items 17–21 及「Curves → Phase 2」清单，本文不重复。

## 1. Kernel 死代码清理（已批准，未执行）

### 实测基线（2026-07-25，本人复核）

- `cd kernel && mix test`：**15/15 全绿**。此前调查所称「23/24 有 1 红测（legacy Note 缺 Jason.Encoder）」
  不属实——三个 JSON 测试编码的都是空结构（`Project.new()` 等），不触发 Note 编码。
- `mix compile --force`：**2 个 warning**：
  1. `lib/equinox/kernel/compiler.ex:7` `alias Equinox.Editor.History` 未使用；
  2. `lib/equinox/kernel/compiler.ex:30`（及 `:84`）`Map.get(segment, :data_interventions, %{})` —
     legacy `Equinox.Domain.Segment` 无此字段，类型推断恒返回 `%{}`。
- **`Equinox.Domain.Slicer` 在 kernel 中已不存在**（lib 与 test 均无文件；此前调查给出的
  slicer 删除清单作废）。仅存的 "Slicer" 字样是注释：`test/equinox/domain/note_test.exs:7`
  与 `ui_shell/lib/equinox_web/live/editor_live.ex:204`（HTML 注释），可留待 Phase 2 顺手清理。

### 删除

1. `kernel/lib/equinox/editor/history.ex`（`Equinox.Editor.History`）与
   `kernel/lib/equinox/editor/resolver.ex`（`Equinox.Editor.History.Resolver`，注意模块名带 History 前缀）
   ——除 compiler.ex 那个未使用 alias 外，kernel/test、ui_shell 均零引用。
2. `compiler.ex:7` 的 `alias Equinox.Editor.History`（消 warning 1）。
3. `compiler.ex:30` 与 `:84` 的 `Map.get(segment, :data_interventions, %{})` ——改用现成的
   `RecipeBundle.bind_interventions/2`（`lib/equinox/kernel/recipe_bundle.ex:26`）消 warning 2。
   真实的 data_interventions 由 Phase 2 的 RenderRequest 链路供给，不在本轮修补。
4. legacy JSON 序列化链（已核实 kernel/lib 与 ui_shell/lib 零调用方；domain Pickle 已取代其职责）：
   - `kernel/lib/equinox/project.ex`：`@derive {Jason.Encoder, ...}`（:23）与 `from_json/1`（:63 起）；
   - `kernel/lib/equinox/track.ex`：`@derive {Jason.Encoder, ...}`（:30）与 `from_attrs/1`（:93–98）；
   - `kernel/lib/equinox/domain/segment.ex`：`from_attrs/1`（:60）与 `defimpl Jason.Encoder`（:73–88）；
   - 三个随链删除的 JSON 测试用例：`test/equinox/project_test.exs:20–26`、
     `test/equinox/track_test.exs:29` 所在用例、`test/equinox/editor/segment_test.exs:23` 所在用例
     （当前均为绿，删链即删用例）。
   - **保留**：`Kernel.Graph.*` 的 `@derive Jason.Encoder`（`lib/equinox/kernel/graph.ex:23,37,128`，
     SvelteFlow 图持久化在用）与 `:jason` 依赖本身。
   - `kernel/mix.exs:16` 的 `~r/Jason.Encoder.*/` 是 test_coverage 的 ignore_modules 过滤器，
     删 impl 后无匹配项、无害；可顺手删，也可留。

### 修改

5. `kernel/lib/equinox/kernel/engine.ex:4`：moduledoc 删「通过 PubSub 发出进度事件。」
   （功能从未实现。注意该文件含混排 `\r` 行尾，编辑时保留原样）。
6. `kernel/lib/equinox/domain/note.ex`、`kernel/lib/equinox/domain/segment.ex`：moduledoc 顶部加
   frozen 标注（遗留类型，Phase 2 将由 EquinoxDomain/zongzi 类型取代，禁止新增依赖）。
7. AGENTS.md §10：补「kernel legacy JSON 链已移除（domain Pickle 取代）」「`Equinox.PubSub`
   命名归属 ui_shell」两条事实说明（保持英文）。原 6 条 known issues 不受本轮清理影响，保留。

### 明确不动

- legacy `Domain.Note/Segment` 本体、`Equinox.{Track,Project,Editor}`、`Util.Id/Attrs`
  （ui_shell 与编译链路负荷中，Phase 2 全量替换时另行出计划）。
- `Kernel.Plugin`、`Planner.build/1` 的 `[%Segment{}]` 便捷子句、`Blackboard.fetch_contents/2`。
- `Kernel.Engine` vs `Zongzi.Engine` 命名冲突 —— Phase 2 接线时处理。
- `kernel/mix.exs:41` 的 `{:equinox_domain, path: "../domain"}` 挂载 —— Phase 2 即启用。
- ui_shell 全部文件（本轮零影响，用验收命令 2 证明）。

### 验收

1. `cd kernel && mix precommit` 全绿（precommit = `compile --warnings-as-errors` +
   `deps.unlock --unused` + `format` + `test`；两个 warning 均消失，15 测试全过）。
2. `cd ui_shell && mix compile --warnings-as-errors` 通过（必要时先 `mix deps.get`）。
3. grep 确认 kernel/lib 与 ui_shell/lib 无 `Editor.History`、`from_json`、`from_attrs` 残留引用。
4. 完成后**不自动 commit**：先报告删除/修改清单与验证结果，等用户确认。

## 2. ui_shell ↔ kernel 耦合结论（2026-07-25 grep 实测）

- **ui_shell → kernel 单向深度耦合**，legacy 类型无法先于 ui_shell 删除：
  - path 依赖：`ui_shell/mix.exs:36` `{:equinox_kernel, path: "../kernel"}`；
  - `Equinox.Session.*` 门面：`lib/equinox_ui_shell/session_host.ex:18,33`，
    `editor_live.ex`、`editor_live/arranger_component.ex`、`editor_live/piano_roll_component.ex`
    多处 `Equinox.Session.server(...)` 调用；
  - legacy 类型构造：`editor_live.ex:298–321`（`Project.new` / `Track.new` /
    `Domain.Segment.new` / `Domain.Note.new` 搭 demo 工程）、`piano_roll_component.ex:5`
    （`alias Equinox.Domain.Note`）；
  - Kernel 内部件：`lib/equinox_ui_shell/svelte_flow_graph_translator.ex`
    （`@behaviour Equinox.Kernel.GraphTranslator`，`alias Equinox.Kernel.{Graph, StepRegistry}`）、
    `editor_live.ex:47`（`StepRegistry.list_all()`）。
- **kernel → ui_shell/Phoenix 零代码依赖**；`engine.ex` 的 PubSub 注释从未实现，
  `Equinox.PubSub` 只是 ui_shell 侧的进程命名。
- **ui_shell/lib 无任何 Jason 调用** —— legacy JSON 链是纯死重。
- 执行时以最新 grep 为准，以上仅为当日快照。

## 3. Phase 2 开工前须知（本会话补充决策，AGENTS.md 骨架之外）

- **Track API 一律以 `seq_id` 为键**（merge 后只有 seq_a 存活，Note.id 会死）；
  UI 若需按 `Note.id` 寻址，在 Session 边界维护 id→seq_id 反查，不进 Domain。
- **工程反序列化必须用持久化的 Timeline 结构重建**：`Zongzi.Timeline.build/1`
  （`note_order/seq_map/tombstones/next_seq`）；禁止用 `insert_note` 逐条回放——
  seq 重排会导致 NoteTriplet 干预锚全灭。
- kernel 调 zongzi API 时按需把 `:zongzi` 加进 kernel/mix.exs deps。
- AGENTS.md §10 的 6 条 known issues 随 Phase 2 处理，不提前投机修。

## 4. Phase 2 之后（仅预告，不主动做）

ui_shell 编辑流切换到 `EquinoxDomain.Score.Track` API 之后，legacy
`Equinox.{Track,Project,Editor}` 与 `Domain.{Note,Segment}` 才具备删除条件，届时另行出计划。
