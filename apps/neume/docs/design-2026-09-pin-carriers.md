# 设计提案：pin carrier 与 runtime 解耦（2026-09-07）

> 状态：批次 A 已实施（2026-09-07）——`Neume.Pin.Descriptor` /
> `Neume.Pin.Context` / `Neume.Pin.Semantics` / `Neume.Pin.Schema`
> 协议骨架落地，`Identity.adjudicate/3` 与 `Editor.repatch/2` 按
> channel semantics 分派；digest、工程文件与 facade 行为不变。
> 批次 B 待拍板 §11.1，批次 C/D 待 §11.2/11.3。

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
端口：

```elixir
@callback lower_pins(state(), Snapshot.t(), [Neume.Pin.Resolved.t()], term()) ::
            {:ok, term()} | {:error, term()}
```

`Resolved` 至少携带 channel、descriptor、anchor 和已裁决 payload，不携带
Tamale digest 或 History 状态。具体字段等第二个 runtime 的实际差异出现后
再冻结。

当前 `checked_pins/1` 返回 `%{pitch: ..., duration: ...}` 可继续作为兼容入口；
等第二个 runtime 接入后，再用 `Resolved` 列表替换，避免为尚未出现的差异
提前设计过宽的 DTO。

## 5. 版本化 envelope

不能直接重解释既有 patch：Tamale patch 只持有 `base_digest` 与 payload，无法
从 digest 反推出旧 base schema。因此新语义必须由 payload 自描述：

```elixir
%{
  schema: "score_pitch_v2",
  coordinates: "project_tick",
  values: [[tick, midi], ...]
}

%{
  schema: "phoneme_duration_v2",
  values: [%{segment: segment_ref, duration_tick: ticks}, ...]
}
```

- 旧 pitch list / `pitch_curve_v1` 与旧 duration list 继续签
  `pin_input_v1`，读档和渲染行为不变。
- 新 mount 默认产生 v2；旧 payload 只在显式兼容路径或读档时出现。
- repatch 不跨 schema 偷偷升级。升级是独立、可报告、可撤销的 History 手势。

## 6. `Pin<S>`：pitch

当前绝对 pitch 点已经是 `project_tick -> MIDI`，最容易先迁移。其 base 至少
需要：

```elixir
%{
  schema: "score_region_v1",
  coordinates: "project_tick",
  track: track_id,
  anchor: canonical_anchor_region
}
```

但在施工前必须拍板 transport：

1. **`project_tick`**：拖动音符只移动 anchor，payload 保持绝对位置；移出
   新音符 span 后产生 expressibility conflict。
2. **`note_tick`**：payload 保存相对音符起点的位置，拖动时自然随音符移动；
   runtime lowering 时转成绝对 tick。

推荐新 schema 采用 `note_tick`。它更符合“音符上的 pitch pin”，也能让 anchor
transport 与 payload 语义一致。现有绝对点作为 legacy 保持原行为。

## 7. `Pin<Ph>`：稳定 phonology

Neume 不应把 OpenUTAU/DiffSinger worker 的 `[[language, phone]]` 输出直接当
持久化身份。稳定 ref 至少要包含 namespace：

```elixir
%{namespace: "project_phonology_v1", unit: unit_id, segment: segment_id}
```

`unit_id` 指向显式 syllable group；`segment_id` 由 Neume 的语音学层生成，不能
是 runtime word index 或数组下标。runtime provider 负责把 stable segment ref
映射到自己的 inventory symbol/index。

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

### 批次 B：pitch v2

- 拍板 `note_tick` transport。
- 新 mount 产生 `score_pitch_v2`；旧 payload 继续可读可渲染。
- 添加拖动、trim、split、merge、跨轨移动的 survival matrix 测试。

### 批次 C：phonology ref

- 引入最小 syllable unit / stable segment ref。
- 用 mock runtime 和 OPU runtime 的同一组 contract vectors 验证 lowering。
- 尚不要求实现通用 G2P；runtime 可从歌词或显式音素生成自己的执行表征。

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

1. pitch v2 坐标采用推荐的 `note_tick`，还是继续 `project_tick`？
2. stable phonology segment ref 的最小生成规则：显式持久化 ID，还是由
   syllable unit 输入事实确定性派生？
3. voicebank 的 phonology namespace/dictionary digest 是否需要进入
   `Pin<Ph>` / `Pin<Co>` base；若进入，应使用 provider 提供的 phonology
   digest，而不是整个 runtime manifest digest。

这三个问题未定前，可以完成批次 A；批次 B 需要决定 1，批次 C/D 需要决定
2 和 3。
