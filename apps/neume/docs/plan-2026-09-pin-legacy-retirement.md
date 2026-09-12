# 施工计划：pin legacy 退役 E0（duration 默认 v2 + facade 音素序列查询）

2026-09-11 拍板。前置状态：批次 A–E 已实施（pitch 点列与 Bezier 均默认
v2），唯一仍产 legacy 的挂载入口是 `mount_phoneme_duration` 的 list 形式。
E0 收掉这个口子，闭合"新 mount 零 legacy"指标；之后 E1（legacy 转只读）
是纯删减。

**E0 已实施（2026-09-12）**：E0a 换算不跑 probe（membership 由
`Neume.Phonology.Ref.track_memberships/1` 纯派生）；E0b 落地为
`Neumu.note_phonemes/1`（无 opts，由 /2 更正）。legacy duration list 自此
仅经读档出现，"新 mount 零 legacy"指标闭合。

## E0a：`mount_phoneme_duration` 默认产 `phoneme_duration_v2`

已实施（2026-09-12）。落点：`Neume.Phonology.Ref.track_memberships/1`
（`DurationPin.memberships/1` 委托它，消除重复）；`Editor.
mount_phoneme_duration/4` 先经 `duration_mount_payload/3` 换算再挂载
（非法 list 元素返回 `{:invalid_duration_payload, entry}`，不抛异常；
显式 v2 envelope 透传）。legacy 挂载测试改经 `probe_base` + 显式 `:base`
的 `Coconut.mount` helper 构造。

list → v2 envelope 的换算**不需要 probe**：`[[ph_index, dur_tick]]` 的
下标是成员内音素下标，补 `%{unit, member}` 两个分量即可，二者由
`Neume.Phonology.Ref.memberships/1` 从谱面事实（note_id + melisma 旗标）
纯派生（`Neume.Channels.DurationPin` 已有同款逻辑）。下标界内校验仍在
repatch/消费边界，不在 mount。

- `Neume.Editor.mount_phoneme_duration`：list 入参换算为
  `Schema.phoneme_duration_v2_payload`（unit = 组头 note_id、member =
  组内序号、index 原样）；显式 v2 envelope 透传不动。
- 效应：legacy duration list 仅经读档出现（与批次 B 后 legacy pitch 点列
  处境一致）。
- 测试：挂载换算（单音符 + melisma 组成员的 member 序号）、显式 envelope
  透传、批次 D survival matrix 回归（语义函数不动，只换挂载产出形状）、
  facade 通路断言更新。
- 文档：本文件状态、设计文档批次 D 小节补记、`AGENTS.md`。

## E0b：facade 音素序列查询

已实施（2026-09-12）。落点：`Neume.MultiTrack.note_phonemes/1`
（逐轨 `pipeline.phonemes/3` probe + `Neume.Phonology.Ref` 投影，
`resolve/3` 回读符号作首个生产消费方；空轨归一空映射不 probe；失败
聚合 `{:error, {:probe_failed, entries}}`）；`Neumu.note_phonemes/1`
（无 opts，由计划的 /2 更正为 /1；`:probe_context` 模式，成功返回
`{:ok, %{pin, tracks}}`、失败 `{:ok, %{pin, status: :failed,
entries}}`，span 经 `Neumu.CheckReport.deep_lists/1` JSON-safe 化）；
`Neumu.RefClient.note_phonemes/1` 转发；contract_test 闭环（查询 →
用返回 ref 撰写 v2 envelope 挂载）；`facade-protocol.md` 查询条目。

把引擎物化的音素序列从内部 probe 副产物升格为 facade 一等只读查询。
拍板形状（最小集，扩展走新字段）：

```elixir
{:ok, %{
  pin: history_pin,
  tracks: %{
    track_id => %{
      note_id => %{
        span: {start_tick, end_tick},
        segments: [
          %{segment: %{unit: head_id, member: m, index: i}, phoneme: "l"}
        ],
        extras: %{}
      }
    }
  }
}}
```

- `segment` 即 v2 duration 的 stable ref，UI 拿着可直接撰写
  `phoneme_duration_v2` envelope；`phoneme` 是物化符号；`extras: %{}`
  预留（将来音节边界/预算时长等进 extras，不破坏旧契约）。
- melisma 组：组头给全组序列，续音符只给自己的延续元音 segment。
- 执行面复用 `Neumu.check/1` 模式：ProjectServer 外取 `:probe_context`
  跑只读查询，不产生历史边、不派发事件；底层走 `pipeline.phonemes/3`
  （mock 与 opu_ds 均已实现）。
- 错误语义：probe/G2P 失败投影为 plain-data entry（同 `check/1` 的
  entries 风格），不抛异常、不泄露运行时对象。
- 落点：`Neume.MultiTrack` 只读函数 + `Neumu.note_phonemes/1`（无
  opts，拍板稿的 /2 已更正）、`Neumu.RefClient` 参考实现、
  contract_test 回路、`facade-protocol.md`。

## 拍板记录

- facade 查询形状：ref + symbol + span + `extras: %{}`（2026-09-11）。
- 升级手势不做"一键全量"：逐个 `replace_pin`（legacy → v2）已是显式、
  可报告、可撤销的迁移通路；本机无存量旧档，不发明批量手势。

## 验证

`mix compile --force --warnings-as-errors`、`mix test`、
`mix format --check-formatted`、`mix dialyzer`、`git diff --check`。
