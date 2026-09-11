# 设计提案：pin carrier 与 runtime 解耦（2026-09-07）

> 状态：批次 A 已实施（2026-09-07）——`Neume.Pin.Descriptor` /
> `Neume.Pin.Context` / `Neume.Pin.Semantics` / `Neume.Pin.Schema`
> 协议骨架落地，`Identity.adjudicate/3` 与 `Editor.repatch/2` 按
> channel semantics 分派；digest、工程文件与 facade 行为不变。
> 批次 B 已实施（2026-09-07）：§11.1 拍板 `note_tick`；新增
> `Neume.Pin.Resolved` / `Neume.Pin.Lower` 与 `Neume.Runtime.lower_pins/4`
> lowering 边界；`score_pitch_v2` envelope + `score_region_v1` 底料落地，
> 点列 mount 默认产 v2，legacy payload 行为不变；facade probe 令牌不再
> 携带底料。
> §11.2/11.3 已拍板（2026-09-11）：stable segment ref 由 syllable unit
> 输入事实确定性派生（unit = 组头 note_id，segment = `%{member, index}`
> 成员内序号），不引入持久化 ID；phonology digest 进 `Pin<Ph>`/`Pin<Co>`
> base，经 `Neume.Runtime.phonology_digest/1` 回调由 provider 提供
> （字典级范围 + G2P 算法版本戳），不拆独立 G2P 实体。
> 批次 C 已实施（2026-09-11）：Manifest 字典级摘要、`phonology_digest/1`
> 回调与 `Context` 扩展、`Neume.Phonology.Ref` 派生/解析、双 runtime
> ref 契约向量落地；无用户可见 payload 变化（duration v2 属批次 D）。
> 批次 D 待施工。

## 1. 问题

当前 pitch 与 phoneme duration 是两个 Coconut channel，但共享
`Neume.Identity` 的同一份语音学输入事实底料：歌词、显式音素、melisma
归属和声库摘要。因此绝对 tick/MIDI pitch pin 也会被改词或换声库连坐。

这不是 Coconut 的问题。Coconut 只需要知道：

- patch 挂在哪里（anchor transport）；
- payload 是什么；
- 当前 base 是否仍与挂载时一致（Tamale digest）；
- 如何记录 mount/unmount/repatch 的 History 边。

“base 代表什么”属于 Neume。具体声库如何把已裁决 pin 转成模型输入，属于
runtime adapter（当前为 `neume_opu_ds`）。

## 2. 三类 carrier

记乐谱表征为 `S`，语音学表征为 `Ph`，两者的对应关系为 `Co<S, Ph>`：

| carrier | payload 例子 | base 应覆盖 | 不应覆盖 |
|---|---|---|---|
| `Pin<S>` | 绝对/相对 tick 上的 MIDI pitch | 坐标系、锚定区域、必要的谱面结构 | 歌词、G2P、声库模型、seed/backend |
| `Pin<Ph>` | 发音、音素符号、重音/语言学标记 | 稳定 phonology namespace 与被编辑单位 | DiffSinger inventory 下标、ONNX、frame grid |
| `Pin<Co<S, Ph>>` | 音素时长、音节/音素对齐 | `S` 侧区域、`Ph` 侧 segment ref、对应关系版本 | runtime 临时 word index、worker 展开下标 |

分类依据是 payload **引用哪个领域对象**，不是最终写入哪个模型端口。一个
runtime 可以把三类 carrier 都编译进同一个 `ScorePlan`，但不能反过来定义
它们的持久化语义。

## 3. 所有权

```text
Coconut
  Patch(anchor, channel, Tamale.Patch(base_digest, payload))
                         |
                         v
Neume
  Pin.Semantics + carrier-specific base / expressibility / envelope
                         |
                         v
Runtime adapter
  resolved pins -> runtime plan / indices / frames / model inputs
```

- Coconut 不新增 `S`、`Ph` 或 `Co` 类型，也不解析 payload schema。
- Neume 定义 carrier、canonical payload、base 和 repatch 规则。
- runtime adapter 只实现 lowering；backend、seed、FP manifest、worker 路径
  只进入执行/缓存身份。

## 4. 协议骨架

第一版保持“一个 channel 模块同时实现 Coconut transport 与 Neume 语义”的
形状，避免额外注册表。建议增加：

```elixir
defmodule Neume.Pin.Descriptor do
  @enforce_keys [:payload_schema, :base_schema, :carrier]
  defstruct [:payload_schema, :base_schema, :carrier]

  @type carrier :: :score | :phonology | :correspondence
  @type t :: %__MODULE__{
          payload_schema: String.t(),
          base_schema: String.t(),
          carrier: carrier()
        }
end

defmodule Neume.Pin.Context do
  @enforce_keys [:track, :track_id]
  defstruct [:track, :track_id, :voicebank_identity, phonology: nil, legacy_probe: nil, legacy_bases: nil]

  @type t :: %__MODULE__{
          track: Coconut.Edit.Track.t(),
          track_id: Coconut.Edit.Track.track_id(),
          voicebank_identity: map() | nil,
          phonology: term() | nil,
          legacy_probe: term() | nil,
          legacy_bases: %{term() => map()} | nil
        }
end

defmodule Neume.Pin.Semantics do
  @callback describe(term()) ::
              {:ok, Neume.Pin.Descriptor.t()} | {:error, term()}
  @callback base(
              Neume.Pin.Context.t(),
              Tamale.Anchor.t(),
              Neume.Pin.Descriptor.t(),
              term()
            ) ::
              {:ok, term()} | {:error, term()}
  @callback expressible?(
              Neume.Pin.Context.t(),
              Tamale.Anchor.t(),
              Neume.Pin.Descriptor.t(),
              term()
            ) ::
              :ok | {:error, term()}
  @callback requires_probe?(Neume.Pin.Descriptor.t(), term()) :: boolean()
  @optional_callbacks requires_probe?: 2
end
```

实施补充（评审后修订）：

- `Context.legacy_bases` 是批量裁决的整轨底料预计算槽位：`adjudicate/3`
  与 re-patch 计划只推导一次 `Identity.base_by_note/2`，逐 patch 复用；
  `nil` 时 legacy `base/4` 回退现场推导（单点调用路径）。
- `requires_probe?/2` 按 descriptor/payload schema 判定可表达性校验是否
  需要 probe 物化序列；re-patch 只在批次含此类 payload 时调用
  `pipeline.phonemes/3`，纯 `Pin<S>` 批次不强迫引擎实现音素展开。实现方
  未提供该回调时保守按 `true` 处理。
- 裁决与 re-patch 在调用语义回调前经 `Semantics.implemented?/1` 做入口
  校验；不完整实现的 channel 聚合为 `{:missing_pin_semantics, module}`
  （冲突 entry / 降级原因），不抛 `UndefinedFunctionError`。

`describe/1` 必须按 payload 分派，而不能用模块级 `carrier/0`：同一个
`:pitch` channel 在迁移期会同时承载 legacy list/`pitch_curve_v1` 与
`score_pitch_v2`。它们都是 `Pin<S>`，但 payload/base schema 不同：legacy
payload 继续使用 `pin_input_v1` base，v2 使用 `score_region_v1` base。

`Context.phonology` 是 Neume 的稳定语音学表征，不是 runtime worker 的展开
结果。`legacy_probe` 仅供旧 duration 下标兼容，v2 schema 不得依赖它：

- v2 `Pin<S>` 的 `base/4` 与 `expressible?/4` 不得读取 phonology 或 legacy
  probe；legacy 路径为保持旧 digest 行为可继续读取旧输入事实；
- `Pin<Ph>` 只有在语义确实依赖派生 phonology 时才读取；
- `Pin<Co<S,Ph>>` 可在 repatch/消费边界读取，但挂载是否需要异步 probe
  由具体 payload schema 决定。

runtime 边界建议补一个 lowering callback，而不是让 `Editor` 理解各运行时
端口（批次 B 已实施，`Neume.Runtime.lower_pins/4` 为 optional callback）：

```elixir
@callback lower_pins(state(), Snapshot.t(), [Neume.Pin.Resolved.t()], term()) ::
            {:ok, term()} | {:error, term()}
```

`Resolved` 携带 channel、descriptor、anchor 和已挂载 payload，不携带
Tamale digest 或 History 状态。字段集在第二个真实 runtime 出现前不冻结
（mock 是测试夹具，不算第二个真实 runtime）。

实施要点（批次 B 评审后拍板）：

- `Resolved` 由 Neume 从存活 patch 直接构造（`Editor.resolved_pins`），
  不经 Oi assemble 数据反推——`checked_pins/1` 读 runtime 图结构的旧
  耦合点已拆除，仅作兼容回退保留。
- fallback 严格限制：runtime 未实现 `lower_pins/4` 时，纯 legacy
  descriptor 批次才允许走 `checked_pins/1`；批次中出现 v2 schema 直接
  在统一冲突界面返回 `{:unsupported_pin_schema, schema}`（kind `:pin`
  entry），绝不把 v2 payload 塞进 legacy 路径猜着解释。
- 不设 `capabilities/1`：能力协商以后可用于 UI 预检，当前由
  `lower_pins/4` 的 tagged error 兜底，且不进入 mount 路径。
- 批次 B 评审修订：`Editor.resolved_pins/1` 保持 `track.patches` 原序
  （lowering 同 note/channel 后写覆盖，later-write-wins 与 Coconut
  assemble 一致）；显式 `:base` 兼容入口校验 `base.schema` 与 payload
  分派出的 `descriptor.base_schema` 一致，错配即
  `{:pin_base_schema_mismatch, _, _}`（挂载期拒绝，不留永久冲突）；
  `checked_pins/1` 降为 optional callback，两个 lowering 入口都缺失的
  runtime 得 `{:missing_pin_lowering, module}` tagged error；facade
  probe 令牌精确三键（`%{track_id, note_id, pin}`，携带 base 的旧令牌
  一律 `{:invalid_pin_probe, _, _, _}`），`probe_pin` 只做存活校验、
  不再物化底料。
- mock 与 `neume_opu_ds` 都委托默认 lowering `Neume.Pin.Lower`：legacy
  payload 透传、`note_tick` 按 snapshot 平移为绝对 tick；双 runtime 契约
  测试（`neume_opu_ds` 的 `PinLoweringTest`）钉住同一 Resolved 批次两边
  产出一致、未知 schema 两边同样 tagged error。

当前 `checked_pins/1` 返回 `%{pitch: ..., duration: ...}` 继续作为兼容
入口保留；等第二个真实 runtime 接入后，再评估是否以 `Resolved` 列表
取代它。

## 5. 版本化 envelope

不能直接重解释既有 patch：Tamale patch 只持有 `base_digest` 与 payload，无法
从 digest 反推出旧 base schema。因此新语义必须由 payload 自描述：

```elixir
%{
  schema: "score_pitch_v2",
  coordinates: "note_tick",
  values: [[offset_tick, midi], ...]
}

%{
  schema: "phoneme_duration_v2",
  values: [%{segment: segment_ref, duration_tick: ticks}, ...]
}
```

- 旧 pitch list / `pitch_curve_v1` 与旧 duration list 继续签
  `pin_input_v1`，读档和渲染行为不变。
- 新 mount 默认产生 v2（批次 B 起 pitch 点列如此）；旧 payload 只在显式
  兼容路径或读档时出现。
- repatch 不跨 schema 偷偷升级。升级如将来提供，必须是独立、可报告、
  可撤销的 History 手势（批次 B 不实现升级手势）。
- 长期方向（2026-09-11 拍板）：legacy 双轨是迁移期兼容层，不长期保留；
  v2 在实战中被验证更好后，后续批次可评估退役 legacy 通道。旧工程
  读档兼容（按原语义打开）不受此影响。

## 6. `Pin<S>`：pitch

当前绝对 pitch 点已经是 `project_tick -> MIDI`，最容易先迁移。批次 B
拍板 transport 为 **`note_tick`**（§11.1），payload 与 base 坐标系统一
为音符内相对 tick。已实施的 v2 base：

```elixir
%{
  schema: "score_region_v1",
  coordinates: "note_tick",
  track: track_id,
  note: note_id
}
```

拍板依据（保留原权衡记录）：

1. **`project_tick`**：拖动音符只移动 anchor，payload 保持绝对位置；移出
   新音符 span 后产生 expressibility conflict。
2. **`note_tick`**：payload 保存相对音符起点的位置，拖动时自然随音符移动；
   runtime lowering 时转成绝对 tick（`Neume.Pin.Lower`，消费边界形状不变，
   worker 协议不动）。

`note_tick` 更符合“音符上的 pitch pin”，也让 anchor transport 与 payload
语义一致；base 不含绝对起点是“拖动存活”的前提。现有绝对点作为 legacy
保持原行为。survival matrix（批次 B 已钉测试）：

| 手势 | v2 结果 |
|---|---|
| 改词 / 换声库 / 改音高 / 邻居编辑 | 直接存活（底料不含输入事实与声库） |
| 拖动 | 直接存活并跟随（base 不含绝对起点） |
| trim / split | 界内点直接存活；越界点在消费边界 loud 报错（与 legacy 同一规则），repatch 经 `expressible?/4` 判越界 → 降级 |
| merge | into 上 pin 存活；被吸收音符的 pin 因 note origin 失配冲突，repatch = 显式接受新 origin 重签 |
| 跨轨移动 | facade 手势本就不迁移 pin；若底层跨轨移动 patch，base 的 track 分量失配 → 冲突，repatch 显式重签 |

Bezier envelope（`pitch_curve_v1`）本批保持 legacy：控制点仍为绝对
tick，签 `pin_input_v1`；相对坐标曲线留待后续批次拍板。

## 7. `Pin<Ph>`：稳定 phonology

Neume 不应把 OpenUTAU/DiffSinger worker 的 `[[language, phone]]` 输出直接当
持久化身份。稳定 ref 至少要包含 namespace：

```elixir
%{namespace: "project_phonology_v1", unit: unit_id, segment: segment_id}
```

`unit_id` 指向显式 syllable group；`segment_id` 由 Neume 的语音学层生成，不能
是 runtime word index 或数组下标。runtime provider 负责把 stable segment ref
映射到自己的 inventory symbol/index。

生成规则（§11.2 拍板，2026-09-11）：不引入持久化 ID——持久 ID 会在
note id + melisma 旗标之外开第二条身份通道，split/merge/trim/drag 与
undo/redo 都得双写维护，对下游是双重来源。ref 全部由谱面事实确定性
派生：

- `unit_id` = 组头 note_id（Tamale 稳定锚；组归属由 `Neume.Syllable`
  纯派生，删头晋升/出缝断组规则不变）；
- `segment_id` = `%{member: member_index, index: 成员内音素序号}`——
  成员内序号是 Neume 层对确定性序列的派生，不是 runtime 展开下标。

ref 仍是位置性的，安全性由 base 兜住：Co base 覆盖全组输入事实（各成员
歌词/显式音素）+ phonology digest，任何挪动序列的编辑先冲突、走
repatch 显式重签，不会静默重解释。代价：G2P 输出变动即使听感上是
"同一个音素"也冲突（与批次 B 同音字假冲突的取舍同构）。

本阶段不决定完整 phonology 数据模型。没有真实 pronunciation 编辑手势前，
只冻结 namespace/ref 要求，不先造通用音系学框架。

## 8. `Pin<Co<S,Ph>>`：duration/alignment

duration payload 同时引用音素 segment 和谱面 tick 预算，因此属于
correspondence，不是纯 `Ph`。v2 应用 stable segment ref 替代裸 `ph_index`：

```elixir
%{
  schema: "phoneme_duration_v2",
  values: [
    %{segment: %{unit: unit_id, segment: segment_id}, duration_tick: 96}
  ]
}
```

Neume 负责：

- segment ref 是否仍存在；
- syllable group 变化后 correspondence 是否仍成立；
- tick 预算和 canonical integer 值；
- repatch 时 ref 的无损重定向或明确降级。

`neume_opu_ds` 负责：

- stable segment ref 到展开后 word/phoneme index 的 lowering；
- frame 量化和组级模型预算；
- runtime inventory 不支持该 segment 时返回 tagged error。

## 9. 迁移批次

### 批次 A：协议存在但行为不变（已实施，2026-09-07）

- 增加 `Neume.Pin.Context`、`Neume.Pin.Semantics` 和 payload schema helper
  （`Neume.Pin.Schema`）。✅
- 现有 `PitchPin` / `DurationPin` 按 payload 返回 descriptor，但继续使用
  legacy base。✅
- `Identity` 改为按 channel semantics 分派，黄金行为不变。✅
- 评审修订：整轨底料预计算（`Context.legacy_bases`）、probe 需求按
  descriptor 判定（`requires_probe?/2`）、语义回调入口校验
  （`Semantics.implemented?/1` → `{:missing_pin_semantics, _}`）。✅

### 批次 B：pitch v2（已实施，2026-09-07）

- 拍板 `note_tick` transport（§11.1）。✅
- lowering 边界（B0）：`Neume.Pin.Resolved` + `Neume.Runtime.lower_pins/4`
  optional callback + 严格 fallback（纯 legacy 才回退 `checked_pins/1`）；
  mock 与 `neume_opu_ds` 委托 `Neume.Pin.Lower`，双 runtime 契约测试
  钉住一致性与 `{:unsupported_pin_schema, _}`。✅
- 新 mount 产生 `score_pitch_v2`（点列；Bezier 保持 legacy）；旧 payload
  继续可读可渲染可 repatch，digest 不跨 schema 升级。✅
- 挂载底料由 channel 语义现场推导（`Editor.mount_pin` 经 `describe/1` →
  `base/4`）；facade probe 令牌只携 `track_id`/`note_id`/`pin`，客户端
  传回的 base 一律拒绝。✅
- survival matrix 测试：改词/换声库/拖动/trim/split/merge/跨轨（见 §6
  表格），legacy 行为不变性由 `IdentityPinTest` 与本批矩阵共同钉住。✅

### 批次 C：phonology ref（已实施，2026-09-11）

- 引入最小 syllable unit / stable segment ref（生成规则见 §7）：✅
  `Neume.Phonology.Ref`（`memberships/1`、`units/1`、`segment/2`、
  `resolve/3`），删头晋升/出缝断组的 ref 漂移行为已钉测试。
- 用 mock runtime 和 OPU runtime 的同一组 contract vectors 验证 lowering：✅
  `neume_opu_ds` 的 `PhonologyRefVectorsTest` 复用 `expand_vectors.json`，
  真身期望序列与替身序列上的 ref 解析逐一相同（`within_fake_approximation`
  不成立的用例只消费真身一侧，替身报错由 `ExpandVectorsTest` 钉住）。
- 尚不要求实现通用 G2P；runtime 可从歌词或显式音素生成自己的执行表征。✅（不变）

实施记录：

1. `NeumeOpuDs.Voicebank.Manifest` 扫描期增算 `phonology_digest`
   （phonemes inventory、languages.json、dsdict 词典；不覆盖模型/配置/
   embedding），与全量 `digest` 并列。✅
2. G2P 算法版本戳：`NeumeOpuDs.Pipeline` 以 `@g2p_version` 常量
   （`opu-g2p/1`）与字典摘要合成最终 phonology digest；测试钉住合成
   格式（domain separator + 字典摘要 + 版本戳）。✅
3. `Neume.Runtime.phonology_digest/1` 回调（optional）：`neume_opu_ds`
   返回合成值，mock 返回 `nil`；`Context.voicebank_identity` 扩为
   `%{digest, phonology_digest}`，`Identity.adjudicate` 与挂载/repatch
   路径全程透传，legacy 路径只读 `digest`（旧工程 digest 兼容不动）。
   runtime 未实现该回调时 v2 Ph/Co 挂载/裁决的 tagged error 由批次 D
   在消费边界落地（本批尚无 v2 Ph/Co payload）。✅
4. contract vectors：见上。✅
5. 不拆独立 G2P provider 实体：G2P 的输入（字典、inventory）是引擎包
   资产，当前唯一消费方是合成管线；等发音编辑手势带来第二个消费方时
   再评估 `Neume.Phonology` 契约。✅（决策）

### 批次 D：duration v2

- 新 duration mount 使用 stable segment ref。
- repatch 从“下标界内”升级为“segment 可重定向”。
- `neume_opu_ds` 在消费边界降为现有 worker index，worker 协议可暂时不变。

## 10. 验收条件

- 改词、换声库或 G2P 更新不应让 `Pin<S>` 冲突。
- 改音高或移动无关音符不应让 `Pin<Ph>` 冲突。
- melisma 晋升/断组必须让失效的 `Pin<Co<S,Ph>>` 冲突或明确重定向。
- 同一份 Neume pin 工程可由两个 runtime provider 解析；不支持时返回 tagged
  error，不能静默改义。
- 旧工程不迁移也能按原语义打开、check、repatch 和渲染。

## 11. 尚待拍板

1. ~~pitch v2 坐标采用推荐的 `note_tick`，还是继续 `project_tick`？~~
   已拍板 `note_tick`（2026-09-07，批次 B 实施）。
2. ~~stable phonology segment ref 的最小生成规则：显式持久化 ID，还是由
   syllable unit 输入事实确定性派生？~~ 已拍板**确定性派生**
   （2026-09-11）：持久 ID 会造成双重身份来源；unit = 组头 note_id，
   segment = `%{member, index}` 成员内序号，安全性由 base 覆盖全组
   输入事实兜住（生成规则见 §7）。
3. ~~voicebank 的 phonology namespace/dictionary digest 是否需要进入
   `Pin<Ph>` / `Pin<Co>` base；若进入，应使用 provider 提供的 phonology
   digest，而不是整个 runtime manifest digest。~~ 已拍板**进 base**
   （2026-09-11）：经 `Neume.Runtime.phonology_digest/1` 回调由 provider
   提供 opaque 字符串，范围 = 字典级资产 + G2P 算法版本戳，不用整个
   runtime manifest digest；不拆独立 G2P 实体（见批次 C 施工要点）。

批次 A/B/C 已完成；批次 D（duration v2）待施工。
