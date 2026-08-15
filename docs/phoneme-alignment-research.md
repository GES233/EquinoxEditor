# 音符-音素对齐机制调研（2026-08-15）

> 调研目的：为 `:phoneme_timing` channel 的语义选型（相对 delta vs 绝对边界、
> preutterance 的来源与挂载）提供业界参照。方法：官方文档 + 社区讨论逆推 +
> 学术谱系。证据等级：**【官方】** 文档明说 / **【社区】** 论坛逆推 /
> **【文献】** 论文或官方技术文章 / **【推断】** 本文综合判断。

## 0. 出发点

- UTAU（拼接式）：显式 preutterance/overlap 参数，逐音符手调——拼接固定
  采样，引擎必须被告知每个采样提前多少。
- OpenUtau + DiffSinger（神经式）：dur 模型只输出 `ph_dur_pred`；
  preutterance 是调用方派生的——句首 SP + 500ms padding，首辅音组
  **不拉伸、从音符起点倒推**（`DiffSingerBasePhonemizer.cs` `ProcessPart`：
  "The starting consonant's duration keeps unchanged"），其余音素组按
  比例拉伸对齐音符边界。

问题：商业软件怎么做？

## 1. 「音符起点」的定义：元音 onset（业界共识）

- **【文献】VOCALOID**：引擎层把**元音开始位置**视为音符位置——以「サ」
  为例，[s] 这类无声摩擦音可长达 ~200ms，音符开始才发音则听感迟到
  （[IEICE Bplus VOCALOID 技术解说](https://www.ieice.org/~cs-edit/magazine/ieice/alldata/Bplus24_all.pdf)）。
  VOCALOID6 官方 FAQ 承认 AI 引擎"在比歌唱数据更早的时机合成语音"，
  建议曲前留两小节（[VOCALOID FAQ](https://www.vocaloid.com/support/faq/676)）。
- **【官方】CeVIO AI**：v8.4.0 新增「母音のタイミング補正」——一键把
  元音 timing 对齐音符开头，辅音随元音等量移动（无法移动时按比例
  调整）（[CeVIO 指南·更新履历](https://cevio.jp/guide/cevio_ai/home/archive/)）。
- **【官方】SynthV**：SV2 手册明说"辅音、词尾会在音符**之前和之后**
  生成"，并告诫不要在音符间留缝（[SV2 Manual — Pronunciation](https://sv2.docs.dreamtonics.com/en/phonemes)）。
- **【社区】SynthV 官方论坛**：资深用户共识——元音起点对齐音符起点，
  前导辅音放进前一个元音尾部/前段静音（半元音 /R/ /L/ 例外），
  "几乎所有 vocal synth 都是这样工作的"
  （[Singer timing is wrong](https://forum.dreamtonics.com/t/singer-timing-is-wrong/402)）。
- **【文献】Sinsy（TASLP 2021）**：time-lag 模型的参考音素刻意选
  **音符内第一个元音**（而非第一个音素），"人类通常比乐谱 onset 更早
  开始发辅音"（[arXiv 2108.02776](https://arxiv.org/pdf/2108.02776v1)）。
- **【文献】Opencpop（Interspeech 2022）**：数据集层面 note boundary 与
  phoneme boundary 就是两套独立标注——sung timing ≠ score timing
  （[论文](https://www.isca-archive.org/interspeech_2022/wang22b_interspeech.pdf)）。
- **【文献】反例 ByteSing**：明确不用 time-lag，理由是"方便与伴奏混音"
  ——严格对齐被视为向工程便利性妥协（[arXiv 2004.11012](https://arxiv.org/pdf/2004.11012.pdf)）。

**结论**：没有任何主流软件把"辅音起点 = 音符起点"当默认。元音 onset
≈ 音符 onset 是跨引擎、跨时代的稳定约定。

## 2. 辅音提前量的来源：三个象限

### 纯显式参数

- **UTAU**：preutterance/overlap 逐音符手调。可控性最高，默认值无智能。
  拼接引擎的必然形态（采样是死的，引擎自己不知道辅音多长）。

### 纯模型派生

- **VOCALOID6 AI**：无公开音素 timing 编辑面；timing 偏移官方只以 FAQ
  形式承认（见上）。
- **NEUTRINO**：官方定位"无需设定、按乐句自动生成"，不暴露音素级编辑
  （[公式](https://studio-neutrino.com/332/)）；内部谱系（Sinsy 系）几乎
  肯定是 time-lag + duration 双模型——**【推断】**。
- **ACE Studio（新模型）**：Pre/Post Consonants 功能标注"仅 Verse24 及
  更早模型支持"——新版把辅音时长收回模型内部（见下）。
- **OpenUtau backtime**：模型派生 + 无显式覆盖（见 §0）。

### 混合：模型默认 + 用户覆盖（主流商业答案）

- **SynthV V1**：模型默认（音素类型 + 原唱发音习惯）+ Duration 相对缩放
  滑杆（20%–180%）+ Note Offset（±0.1s 整体平移）
  （[SV1 docs — Note Properties](https://sv1.docs.dreamtonics.com/en/synthv/advanced-usage/note-properties)、
  [manual.synthv.info — Note and Phoneme Timing](https://manual.synthv.info/note-properties/note-and-phoneme-timing/)）。
- **SynthV V2**：模型默认 + Phoneme Timing Panel **绝对边界拖拽** +
  plosive onset 时机/强度微调 + Timing AI Retake（timing 是可重采样的
  生成量）（[SV2 docs — Pronunciation](https://sv2.docs.dreamtonics.com/en/phonemes)、
  [SV2 Pro 发布公告](https://www.dreamtonics.com.cn/announcing-synthesizer-v-studio-2-pro/)）。
  V2 模型"把音乐上下文考虑得更多"，官方不再推荐 V1 式拆音符放音素
  （[迁移指南](https://sv1.docs.dreamtonics.com/en/synthv/upgrade/migration-guide)）。
- **ACE Studio（旧模型）**：AI 按声库口音生成每个辅音时长，**生成后固化**
  为用户可见的 pre/post consonant 块（pre consonant 画在音符左边界
  **之外**），可拖边界手改、换声库可清除重生成
  （[ACE Docs — Editing Lyrics](https://docs.acestudio.ai/ai-vocal-synth/creating-ai-vocals/editing-lyrics)）。
- **CeVIO AI**：TMG 画面音符级（黑带）+ 音素级（上方）双线编辑；调完
  timing 后 PIT/VOL/颤音自动重算
  （[CeVIO 指南·歌声调整](https://cevio.jp/guide/cevio_ai/songtrack/song_07/)）。

**两个相反方向的演进**：ACE 从显式块收回模型内部；SynthV 从相对滑杆
走向绝对边界。共同点是**默认值始终模型派生**——分歧只在覆盖层的
暴露粒度。

## 3. 学术谱系：time-lag 模型

Sinsy（DNN 版）→ XiaoiceSing → NNSVS 一脉：time-lag（音符 onset 偏移）
与 phoneme duration 是**两个独立预测任务**；NNSVS 后处理把预测时长
归一化使总和等于音符时长（[arXiv 2210.15987](https://arxiv.org/pdf/2210.15987)）。
DiffSinger 原文（[arXiv 2105.02446](https://ar5iv.labs.arxiv.org/html/2105.02446)）
不讨论 onset 对齐约定——OpenUtau 的 backtime 是工程实现层的补全，
不是论文内容。

## 4. 对 Equinox 的设计含义（推断层）

1. **`:phoneme_timing` 的长期目标语义应是绝对边界**（SynthV V2 / ACE /
   CeVIO 收敛的形态），当前 payload 的相对 delta
   （`onset_delta_ms / duration_delta_ms`）对应 SynthV V1 形态。与既有
   架构天然吻合：duration 模型投影 = canonical base（默认值模型派生），
   用户编辑 = patch 覆盖，resolve 时对拍——重估时改 payload 语义即可，
   base/resolve 机制不动。
2. **ACE 的"生成后固化、换声库清除重生成"= 我们的 `engine_key` 版本戳
   + adopt 流程**：版本升级 → digest 失配 → 冲突上浮 → 重新 adopt，
   先例完全对应。
3. **sidecar 的 preutterance 缺口**（已记入
   `docs/engine-adapter-design.md` follow-up）按 OpenUtau 模式补齐即可：
   Packaging 句首插 SP 词 + 对齐段首辅音组不拉伸倒推。若未来要"方便
   混音"的严格对齐模式（ByteSing 式），那是一个可选的渲染开关，不是
   默认。

## 5. 未查到的

- SynthV 提前量的具体数值/算法（模型内部，官方从未公布）；
- ACE 博客正文细节（JS 站点，仅搜索摘要）；
- NEUTRINO 内部是否显式 time-lag（无官方文档，仅谱系推断）。
