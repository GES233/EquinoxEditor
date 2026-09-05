# 决策：pin 身份底料改为输入事实签名（2026-09-05）

> 状态：已实施（随本次工作落盘，未提交）。取代
> `design-2026-08-orchid-intervention.md` §6.6 第二档中"签 probe 物化
> 音素序列"的做法；channel 分档与裁决界面不变。

## 背景

原设计把 pin 的 digest 钉在 probe 物化的**词内音素序列**（G2P + 组展开
的输出）上。问题：G2P 既不是 lang-agnostic 也不是 voicebank-agnostic —
— 英文有 heteronym、日文有语境读音/accent，后续不只中文歌。把编辑状态
层的身份建立在语言学前端的输出上，等于让 pin 的稳定性继承 G2P 的稳定性
（字典更新、前端选型摇摆会连坐所有 pin）。

用户原始直觉：G2P 与合成都是**潜在引擎内部的协议**——引擎内部协议的
产物不应泄漏进编辑状态的身份层。

## 决定

底料改为**输入事实签名**（`Neume.Identity`，schema `pin_input_v1`）：

```
%{schema: "pin_input_v1",
  voicebank: 声库内容摘要（manifest digest；mock 为 nil）,
  lyric: 歌词,
  phonemes: 显式音素（metadata["phonemes"]，无则 nil）,
  group: %{kind: "head"}
       | %{kind: "continuation", head: _, head_lyric: _, head_phonemes: _}}
```

即"决定该音符语音学身份的全部输入事实"。生效续音的自身歌词/显式音素
不入底料（生效期不被模型消费，与 probe 展开语义一致）；续音身份 = 头的
输入事实。推导是纯函数（`Neume.Identity.base_by_note/2`）：不跑 G2P、
不调 worker、只读 workspace。

## 影响

- **挂载纯化**：`Editor.probe_base/2` 与 facade 的 `probe_pin` 不再调
  worker，即时返回。两阶段 API 形状保留（stale_pin 校验仍有用），但 UI
  可将其视为即时操作，"probe 待定"态不再是必需的。
- **爆炸半径不变的部分**：改词、显式音素修改、melisma 晋升/断组、声库
  内容变化会炸；改音高、拖动、邻居编辑不炸；生效续音自身歌词编辑不炸。
- **已知取舍（变粗的部分）**：同音字改词等"输入变了但 G2P 输出不变"的
  编辑会假冲突，由 `repatch` 重签兜住（payload 仍可表达则无损）。
- **repatch 仍需 probe**：duration pin 的可表达性（下标界内）判定需要
  probe 物化的序列长度，`pipeline.phonemes/3` 保留给这条路径与词内下标
  平移使用。
- **裁决界面不变**：仍在 `check`/`analyze`/`render` 的 `stage: :probe`
  冲突界面聚合，entry 形状不变；但裁决本身不再依赖 probe 输出，模型
  probe 失败时身份冲突照常报告（此前整批跳过）。

## 遗留问题

1. **声库摘要粒度**：用的是 manifest digest（整个声库扫描内容），比
   "字典摘要"宽——声库内任何被扫描文件变化都会炸 pin。保守方向正确
   （假冲突可 repatch），但若声库模型文件就地更新而字典未动，会产生
   不必要的冲突。如成为痛点，在扫描层加字典级 digest。
2. **`:probe` stage 名义保留**：底料现在可从 workspace 纯派生，理论上
   channel 可降为 `:static`（Coconut 静态 Resolve 裁决）。未做的原因：
   静态 projection 只能读到 track extras 里的 entry 签名（stock/modified
   不同摘要会造成假冲突），拿不到 manifest digest；且冲突 entry 形状会
   变。若日后把 manifest digest 持久化进 extras，可再收敛。
3. **EN/JP 入口**：显式音素（`metadata["phonemes"]`）在整条链上绕过
   G2P，是 EN/JP 的主要入口假设（OpenUTAU 工程导入自带音素）；裸歌词
   G2P 作为增量补充。该假设待 EN/JP 声库真正接入时验证。
4. **替身漂移**：黄金向量计划（mock/fake/真 worker 对同一 fixture 的
   expand 输出）仍适用于 probe 序列的**消费侧**（可表达性、下标平移、
   render），不因底料改为输入签名而消失。
5. **同音字假冲突的 UX**：repatch 回复的 `:repatched` 结果可以支撑
   "一键全部重签"的 UI 模式；是否需要"改词时预判无实际音素变化就
   不提示"的优化，留给 UI 阶段用真实数据评估。

## 验证

- `apps/neume`：`92 passed, 7 excluded`（含新测试"签输入：底料是输入
  事实而非 G2P 输出，mount 不依赖 probe"）。
- `apps/neumu`：`50 passed`（pin 族测试的底料断言已更新为输入事实形状；
  melisma 断组/恢复的 probe 断言改验 continuation/head 形态）。
- 未提交，待人工审阅。
