# Neume

~~人类重写版本。~~ 第二轮迭代版本。

当前实现进度、验证基线、限制和后续路线见 [`STATUS.md`](STATUS.md)。

## 当前闭环

无声库时使用确定性的 mock 图；传入仓库外的 OpenUtau DiffSinger 目录时，
走 `Coconut -> CoconutOi -> Oi -> Python/ONNX -> WAV`：

```elixir
{:ok, editor} =
  Neume.Editor.new(
    voicebank_path: "E:/ProgramAssets/OpenUTAUSingers/Asaritsu",
    python: ["D:/path/to/python.exe"],
    output_dir: "D:/temp/neume-renders",
    speaker: "Normal",
    steps: 8
  )
```

Python 环境需要 `onnxruntime`、`numpy`、`soundfile`、`pyyaml`；中文歌词的
自动音素化还需要 `pypinyin`。声库目录只读，模型不会复制或写入仓库；
工程只保存 `{name, engine, digest}`，重新打开时必须再次提供
`voicebank_path` 并通过摘要核对。

真实管线使用 OpenUtau 式元音锚定：音符起点对应词内首个元音（C-G-V
结构对应 glide），此前的一个或多个辅音向前回排并占用前置 SP/间隙；
`RenderArtifact.phonemes` 返回实际渲染帧网上的绝对音素边界。

melisma（一词跨多音符）用显式旗标表达：续音音符携带
`metadata["melisma"] == "continue"` 且与前一音符贴接时并入其音节组；
组的音素 = 头音素 + 每成员一个延续元音（锚在各成员音符起点，带各自
音高）。`Editor.split_note/4` 拆分时右子自动获得旗标（拆分 = 同音节
延续）；删除头音符后下一成员自动晋升，移动出缝隙即断组。worker 只
消费显式组，不根据歌词或音高猜测。

音素时长编辑通过 `Editor.mount_phoneme_duration/3` 挂载 Coconut
`:duration` patch；指定音素固定为给定 tick 时长，其余音素按模型预测比例
吸收剩余帧。pitch 曲线经 `Editor.mount_pitch/3` 挂载稀疏控制点。两种 pin
的 digest 都钉在 **probe 物化的词内音素序列**上（身份底料）：改词、
melisma 晋升/断组会让 pin 冲突并进入统一的 `check_failed` 裁决界面，
`Editor.repatch/2` 把仍可表达的 pin 批量重签（一条历史边，undo 一次全
还原）；改音高、拖动和邻居编辑不会误伤。所有干预编辑进入 Coconut
History，支持 undo/redo，最终仍经过上述元音锚定，因此 artifact 展示的
边界与实际合成一致。

无需出音频的对齐读取用 `Editor.analyze/1`（G2P、duration/pitch 预测和
绝对音素边界，不运行 acoustic/vocoder）；提交渲染前的完整检查用
`Editor.check/1`（静态 patch/port/globals 检查 + 模型级 probe，失败聚合为
`{:error, {:check_failed, entries}}`）。

全局表现旋钮（`energy`/`breathiness`/`voicing`，variance 预测曲线的乘性
系数，1.0 中立）走 `Editor.update_globals/2` 直进 render：会话态、不经
tamale patch、不可 undo 也不随工程持久化；越界或未知键在 check 的门禁
聚合为 `%{kind: :global, ...}` entry。逐帧曲线干预是另一条路（tamale
patch，待落地）。

调试导出：`Editor.export_debug(editor, path, opts)` 把当前轨打包成
debug.json（notes/pitch 帧网/音素边界/tempo/`meta.patches` 铆钉点/pin
控制点曲线；`span:` 裁剪 tick 区间，`raw?: true` 附无干预对照），
`tools/plot_render.py` 用 matplotlib 画钢琴卷帘 + pitch + 音素时序图
（`-o out.svg` 出矢量图，依赖 `pip install matplotlib`）。

渲染按乐句分窗增量执行：空档 ≥ 3 拍切窗，窗口级 WAV 缓存按「声库摘要 +
globals + 窗内音符 + pins」失效，编辑后只重推内容变化的窗口，各窗音频按
绝对时间拼接成整轨 `RenderArtifact`。

## TODO

- [ ] energy/breathiness/voicing 的逐帧曲线 channel（手绘编辑）；增量型
  曲线干预走 output base（coconut `design-2026-08-orchid-intervention.md`
  §6.6 第三档），与全局旋钮复合。
- [ ] 声库发现/注册表、多轨调度、播放与导出管理。
- [ ] 最小钢琴卷帘、音素边界编辑和播放 UI。
