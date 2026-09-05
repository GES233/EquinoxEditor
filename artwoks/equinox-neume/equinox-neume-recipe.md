# Equinox / Neume — 单色编辑印刷品配方记录

2026-09-05 · mono-color skill · 交付物同目录

## 输入

- 主题：Equinox（歌声合成编辑器内核；`apps/neume` 以纽姆谱命名）
- 意图：文化海报（项目 poster）
- 文字：无用户供给 → 造句 `PIN THE NOTE, KEEP THE VOICE`（pin 手势是产品灵魂）
- 参考图：无 → 从识别锚点构建
- 约束：纽姆谱代替钢琴卷帘；**不要宗教色彩**

## 世俗化纽姆的策略

纽姆的宗教感来自手抄本能指（羊皮纸、哥特体、红谱线/rubrication、拉丁
经文），而非几何本身。所以：承印物用当代冷灰不泛黄、字体用宽
grotesk 与 mono（不用哥特体）、红色只给"钉"与套准标、全程无文字内容
（gabc 只出符头，不带唱词）。

## 配方

- **承印物**：Cool Gray `#E9E9E5`
- **版式**：Charcoal `#30343A` 主版（纽姆谱 + 标题 + 小字）+ Mist Blue
  `#8DABE4` accent 版（圆斑"钉" + 套准十字/注记），约 85/15。
  （初版为 Signal Red `#C83232`；后改蓝——红色圆斑在浅底上易误读含有
  政治含义，且红色在产品语义里专属冲突/错误提示，两处都让位。）
- **构图族**：editorial cover；焦点事件 = 钉头大过符头的反常比例；
  释放区 = 顶部约 45% 净纸；未决边缘 = 谱号左缘半裁、谱线双缘出血、
  第四线直出底缘
- **字体**：宽 grotesk 大写（Arial Black 80）标题 × Consolas 15 小字
  （5.3× 尺度跳变）
- **工艺**：纽姆谱由 Gregorio 6.2.0（greciliae 真字形，gabc 无唱词）
  经 LuaLaTeX/gregoriotex 排版成条，`\gresetlinecolor`+`\color` 统一为
  炭黑、`\pagecolor` 统一为承印物色；PDF→200dpi PNG→Python 中目网点化
  （12px 网目、暗度→点半径）；红版纯色平版，+6px 淡影作套准微偏
- **手工笔意**（仅一族）：套准十字 + `repatch.` 注记（项目真实术语）
- **原创性**：主体物（纽姆谱条）、焦点机制（抽象圆斑钉）、构图
  （顶部释放区 + 左缘谱号裁切）、字体组合与任何参考均不同源

## 文件

- `equinox-neume.png` — 成品（1350×1800，3:4）
- `equinox-neume.svg` — 可编辑源（Inkscape 可直接改）
- `neume-strip-halftone.png` — 网点化纽姆条（SVG 引用，勿删）
- `score.gabc` / `strip4.tex` — 纽姆条的 Gregorio/LaTeX 源（重生成用）

## 图像生成 prompt（如需喂给图像模型的替代路径）

```text
A 3:4 vertical editorial print on cool gray paper #E9E9E5, flat front-facing
page, no mockup. Two printing plates only: charcoal #30343A carries the
neume-notation strip, headline and microcopy; mist blue #8DABE4 carries one
flat circular disc and one small registration crosshair. Complementary
duotone, roughly 85/15 coverage.

Editorial-cover composition, balanced tension: a fragment of medieval
square-note neume notation — four-line staff, C clef, punctum and podatus
glyphs, no lyrics, no Latin — reproduced in medium charcoal halftone, the
staff running across the middle band and bleeding off both page edges, the
clef half-cropped at the left edge, the fourth staff line exiting through
the bottom edge. One oversized flat red disc presses onto a note glyph at
center-right — the pin head larger than the note head — the single focal
event, with a faint 1 mm registration ghost. The top 45% stays open quiet
paper with only the small red crosshair and a tiny red mono annotation
"repatch." as page furniture.

Typography: wide interlocked grotesk capitals, headline "PIN THE NOTE, KEEP
THE VOICE" in two lines sitting inside the staff band, overprinting staff
lines and one note glyph; two lines of small programmatic mono at the
bottom: "EQUINOX / NEUME — A SINGING-SYNTHESIS EDITOR KERNEL" and
"UNDOABLE HISTORY · PINNED INTENT · WINDOWED RENDER". Headline about 5-6x
the microcopy size.

Material: visible halftone dots at close range, restrained ink bleed,
nothing else. Avoid: parchment or yellowed paper, Gothic or calligraphic
lettering, illuminated initials, religious iconography, red staff lines,
gradients, full color, glossy mockup, 3D depth, centered template symmetry,
logos, QR codes, marketing copy.
```
