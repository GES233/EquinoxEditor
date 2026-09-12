# 0001 · 干预的载体：patch 与 pin

**Status**: Accepted（2026-09-12，术语对齐 grill 会话）

## 决策

1. **干预（intervention）是领域概念，不是数据结构。** 它指"用户对模型生成结果
   施加的意图"。它在数据结构层面有两级具体化，各有专名，任何文档不得互相替代：
   - **`patch`（coconut 载体）** = `Coconut.Edit.Patch`：id + track_id + anchor +
     channel + tamale 底座。它是可 undo 的历史单元，也是 Coconut History 里唯一
     可持久化的编辑单元。
   - **`pin`（neume 身份）** = `Neume.Pin.Descriptor/Context/Semantics/Schema`
     与 `Neume.Identity`：它是存活与裁决单元（payload schema、base schema、
     carrier）。
2. **层内唯一律**：同一层（同一 app / 同一命名空间）内，一个词只允许一个意思；
   跨层同名允许，但语义必须一致，否则登记为两个概念并改名。
3. **限定词制**：裸词留给该层/该领域的核心概念，任何次要义必须带限定词。已按此
   收敛的四处：`preflight`（Host 方向取挂载前状态，不叫 probe）、`history_pin`
   （History cursor，裸 `pin` 不指它）、`root_seq`（历史窗口根，原
   `History.base_seq`）、`tamale patch`（`Tamale.Patch`，裸 `patch` 归 coconut
   载体）。
4. **`probe` 与 `interventions` 各有专义**：`probe` = 向引擎索取一次物化中间结果
   （G2P / 组展开 / 模型预测，不跑 acoustic/vocoder）；`interventions` = 引擎边界
   上的干预数据 `%{port_ref => %{input: value}}`，分 base / resolved 两级。两者都
   不再是 patch / pin 的同义词。

## 理由

同一个概念在三层有三个名字（文档的 intervention、coconut 的 patch、neume 的
pin），这不是错误，而是分层职责的真实差异：coconut 管"能不能 undo"，neume 管
"身份还成不成立"。强行同名会把两层职责抹平；放任不管则读者分不清"这个干预是能
撤销的，还是会被裁决的"。

另外两类分歧各有成因，都需要写下来才不会被重新引入：

- **同一个动词、两个宾语**：`pin` 既指 tamale 的版本钉（`at_version`、History
  cursor），又指用户干预的身份单元；`base` 既指历史窗口根，又指被签名的底料。
  这类只能靠限定词制切断。
- **语义迁移留下的化石名**：`probe_pin` / `probe_base` 在 2026-09-05 身份底料改
  为输入事实签名之后已不再调 worker（见
  `apps/neume/docs/decision-2026-09-pin-input-base.md`），名字却留在原地，于是
  neume 层内出现了"probe 表示不 probe"的反义。改名（`preflight_pin`）已登记，
  属施工批次。

不复用同名的代价是经常性的：`ProjectSnapshot` 里 `history_pin`（cursor）与
`pins`（存活载体）并排出现；`patch.patch.payload` 需要读者在脑内展开一层；
`apps/neume/docs/plan-2026-09-ui-facade-gestures.md` 至今教 UI 为一次纯函数调用
准备"probe 待定"加载态。

## 影响

- 正名表与逐词判定记录：根 `CONTEXT.md`。
- 本次不改代码标识符；改名候选（`preflight_pin`、`history_pin`、`root_seq`、
  `Coconut.Edit.Patch` 的 `tamale_patch` 字段等）登记在 `CONTEXT.md` 的候选改名
  清单，另立批次施工。
