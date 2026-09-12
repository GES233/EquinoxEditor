# 施工计划：术语改名批次（2026-09）

> 前置阅读：根 `CONTEXT.md`（正名表与候选改名清单）、
> `docs/decisions/0001-intervention-carriers-patch-and-pin.md`（三条硬规则）、
> `AGENTS.md`（架构边界与验证基线）。
>
> 来源：2026-09-12 的术语对齐 grill 会话。语言层（散文/注释/文档）已施工完毕，
> 本计划只做**标识符改名**。行号基于 2026-09-12 的工作树，可能漂移——以符号名
> 为准。

## 目标与完成定义

把三处"语义迁移留下的化石名 / 同层双义"改成 `CONTEXT.md` 登记的正名。**只改
名字，不改行为**：不新增功能、不改语义、不改错误契约的形状（只改 tag 名）。

DoD：

1. 三个工作包各自一个提交，提交信息用中文 conventional commit
   （例：`refactor(neumu): probe_pin 正名为 preflight_pin`）。
2. 每包做完跑：`mix compile --force --warnings-as-errors`、`mix test`、
   `mix format --check-formatted`、`git diff --check`；整批结束再跑一次
   `mix dialyzer`。
3. 测试基线不下降：`apps/neume` 166 passed、`apps/neumu` 75 passed / 1 excluded、
   `apps/neume_lab` 9 passed、`apps/neume_opu_ds` 46 passed / 8 excluded。
4. `CONTEXT.md` 的候选改名清单同步更新（已做的移出，并在对应条目注明提交）。

## 全局禁改清单（这些看着像不一致，但是对的）

- `Coconut.Render.Channel.resolve_stage/0 :: :static | :probe`、冲突 entry 的
  `stage: :probe`、Oi 端口 `{:analysis, :probe}`、`requires_probe?/2`、
  `legacy_probe`、`probe_track_phonemes/1`、`{:probe_failed, _}`——都是
  **义 A**（向引擎索取物化结果），`probe` 在这里是正名。
- `Editor.pin_entry/2` 的 `%{kind: :pin, ...}`——按 Q5 这是**正确**用法
  （kind 指用户 pin，不是 cursor）。
- `RenderJob.source_pin`、`Neumu.history_pin/1`、`MultiTrack.at_pin/2`、
  `ProjectSnapshot.history_pin`——已带限定词，合格。
- `Neumu.ProjectSnapshot.pins`、`Neume.Pin.*` 命名空间——义"在册干预载体"，合格。
- 外部契约：`Tamale.*` 模块名、`orchid_intervention`（hex 包与 Oi hook 名）、
  所有 `interventions` 字段名、`serve`/`port_ref` 形状。
- `apps/coconut/test/coconut/resolve_test.exs:46,257,265,267,272,283` 的
  `:probe_pin`（channel 名与 port 名）是 **coconut probe-stage 的测试夹具**，
  与包 1 无关，**禁止改**。

---

## 包 1：Host 方向的"预检"改名（无持久化影响，可独立交付）

正名依据：Q4——Host → Neume 那一侧叫**预检 preflight**，令牌叫**预检令牌**。

| 现状 | 改为 | 落点 |
|---|---|---|
| `Neumu.probe_pin/3` | `preflight_pin/3` | `apps/neumu/lib/neumu.ex:487-493`（`@doc`/`@spec`/def） |
| `Neume.MultiTrack.probe_pin/3` | `preflight_pin/3` | `apps/neume/lib/neume/multi_track.ex:423-431` |
| `Neume.Editor.probe_base/2` | `derive_base/2` | `apps/neume/lib/neume/editor.ex:469-470` |
| `:probe_context`（call 模式） | `:preflight_context` | `apps/neumu/lib/neumu/project_server.ex:227`、`apps/neumu/lib/neumu.ex:205,234,490` |
| `:invalid_pin_probe` | `:invalid_pin_token` | `project_server.ex:498`、`apps/neumu/docs/facade-protocol.md:106,110,119` |
| 令牌形参 `probe` | `token` | `neumu.ex` 的 `mount_pitch/5`、`mount_pitch_curve/5`、`mount_phoneme_duration/5`；`project_server.ex:452` 的 `{:mount_pin, ..., probe}` 内部消息元组与 `mount_probe_opts/3`（→ `mount_token_opts/3`）；`apps/neumu/test/support/ref_client.ex`；`apps/neume_lab/lib/neume_lab/board.ex` |
| 令牌键 `pin`（History cursor） | `history_pin` | `neumu.ex:493`、`mount_token_opts/3` 的模式与 `map_size` 断言、`ref_client.ex:21,32,40`、相关测试断言 |
| `Editor` 挂载路径 `opts[:pin]` | `opts[:history_pin]` | `apps/neume/lib/neume/editor.ex:938`（透传 History stale-write 校验；连带 `mount_pin/5` 的读取点与 `Neume.MultiTrack.mount_*` 的 opts 透传） |

调用点（测试为主，必须一起改）：

- `apps/neumu/test/neumu/pin_facade_test.exs`（13+ 处，含 `:invalid_pin_probe` 断言）、
  `score_gestures_test.exs`、`contract_test.exs`、`audition_test.exs`、
  `apps/neumu/test/support/ref_client.ex`
- `apps/neume/test/neume/{editor,identity_pin,pin_semantics,score_pitch_v2}_test.exs`
  的 `Editor.probe_base`（9 处）

文档同步（散文已改，标识符引用要跟着改）：`facade-protocol.md`、
`apps/neume/docs/design-2026-09-pin-carriers.md:201`、
`apps/neume/docs/plan-2026-09-pin-legacy-retirement.md:19,44,74`、
`apps/neume/docs/plan-2026-09-ui-facade-gestures.md:10`、`AGENTS.md`。

验收 grep（应只剩义 A 与 coconut 夹具）：

```powershell
rg "probe_pin|probe_context|invalid_pin_probe|probe_base" --glob "!CONTEXT.md"
```

---

## 包 2：`History.base_seq` → `root_seq`（动持久化，需读档兼容）

正名依据：Q6——代码自己管它叫 root（`{:missing_root_checkpoint, hist.base_seq}`、
`nodes[base_seq].checkpoint`），字段名却是 base。

落点（约 23 处）：

- `apps/coconut/lib/coconut/edit/history.ex`：`@type`、`new/1` 默认值、`restore/1`
  的 `fetch_field`、不变量与窗口裁剪（`:64,73,92,125,145,149,157,175,179,180,183,185,186,261,333,343,344`）
- `apps/coconut/lib/coconut/pickle/history.ex:12,34,50`
- `apps/neumu/lib/neumu/project_snapshot.ex:78`（`can_undo`）
- 测试：`apps/coconut/test/coconut/edit/history_test.exs`、
  `apps/coconut/test/coconut/pickle/history_test.exs`

**兼容要求（硬）**：`Coconut.Pickle.History.load/2` 必须同时接受新键 `:root_seq`
与旧档的 `:base_seq`（`Map.get(data, :root_seq) || Map.get(data, :base_seq)`），
dump 只写 `:root_seq`。理由：`Struct`/显式 `Map.get` 取不到键时给 `nil`，
`History.restore/1` 的 `is_integer` 校验会直接失败——旧工程会读不开，
而 `AGENTS.md` 要求"旧工程读档兼容不变"。

新增测试：拿一份含 `:base_seq` 的历史 dump map，断言能 load 成功且
`root_seq` 等于该值。

---

## 包 3：`Coconut.Edit.Patch.patch` → `tamale_patch`（动持久化，需读档兼容）

正名依据：Q7——裸 `patch` 归载体；`Tamale.Patch` 必须写全名。现状是
`patch.patch.payload` 这类读法（11 处），读者要在脑内展开一层。

落点：

- 字段定义：`apps/coconut/lib/coconut/edit/patch.ex`（`@keys` 与 `@type`）
- pickle 规格：`apps/coconut/lib/coconut/pickle/patch.ex:32-40`（`fields/0` 的
  `{:patch, {dump, load}}`）
- 读取点（11 处 `patch.patch.*`）：`apps/neume/lib/neume/identity.ex:209-210,222`、
  `debug_export.ex:291,345`、`editor.ex:656,760-761,1024-1035,1172-1177`、
  `apps/neumu/lib/neumu/project_snapshot.ex:116`、
  `apps/coconut/lib/coconut/render/resolve.ex:37,162,174`（`:37` 是 `@typedoc`
  里的 `patch.patch.base_digest`）
- 构造点：`patch: %Tamale.Patch{...}` 形式约 50 处，集中在 coconut 测试
  （`frame_anchor_test`、`warp_provider_test`、`tempo_test`、`diff_test`、
  `audio_test`、`resolve_test`、`operate_test`、`pickle/track_test`）与
  `apps/coconut/examples/multi_track.exs`；neume 侧
  `apps/neume/test/neume/pin_semantics_test.exs:138,203,236`

**兼容要求（硬）**：`Coconut.Pickle.Patch` 的 load 必须接受旧键 `:patch`。
`Coconut.Pickle.Struct.load/4` 是**字段名驱动**的（`Map.get(data, field)`，缺键
给 `nil`、多余键忽略），所以只改 `fields/0` 会让旧档静默产出
`tamale_patch: nil` 的 patch——必须显式补一条读旧键的路径（在 `load/1` 前把
legacy `:patch` 键搬成 `:tamale_patch`），dump 只写 `:tamale_patch`。

新增测试：拿一份旧形状的 dump map（键 `:patch`）断言 load 出的
`tamale_patch` 与原值一致；再断言新 dump 里没有 `:patch` 键。

**陷阱**：不要动 check/冲突 entry 里的 map 键 `patch:`——`resolve.ex:122,143,182,192,205`、
`editor.ex:1187`、`identity.ex:234`、`identity_pin_test.exs:129` 是 entry 字段名
（值是 `Coconut.Edit.Patch`），不是载体内部字段。

---

## 建议顺序

包 1 → 包 2 → 包 3。包 1 是纯重命名、零格式影响，先做可以把"改名 + 测试基线
不变"的节奏钉死；包 2、包 3 各自带一条读档兼容，做完各自补一条旧档测试。
