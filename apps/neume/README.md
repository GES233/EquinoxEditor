# Neume

人类重写版本。

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
`RenderArtifact.phonemes` 返回实际渲染帧网上的绝对音素边界。当前仍以
“一音符一个音节槽”为边界，melisma 需要后续显式的跨音符音节身份。

音素时长编辑通过 `Editor.mount_phoneme_duration/3` 挂载 Coconut
`:duration` patch；指定音素固定为给定 tick 时长，其余音素按模型预测比例
吸收剩余帧。该编辑进入 Coconut History，支持 undo/redo，最终仍经过上述
元音锚定，因此 artifact 展示的边界与实际合成一致。

无需出音频的对齐读取用 `Editor.analyze/1`（G2P、duration/pitch 预测和
绝对音素边界，不运行 acoustic/vocoder）；提交渲染前的完整检查用
`Editor.check/1`（静态 patch/port/globals 检查 + 模型级 probe，失败聚合为
`{:error, {:check_failed, entries}}`）。

渲染按乐句分窗增量执行：空档 ≥ 3 拍切窗，窗口级 WAV 缓存按「声库摘要 +
globals + 窗内音符 + pins」失效，编辑后只重推内容变化的窗口，各窗音频按
绝对时间拼接成整轨 `RenderArtifact`。

## TODO

- [ ] 跨音符 syllable group：以相邻音符组作为显式音节身份，定义音素到
  成员音符的归属、延音歌词约定，以及成员移动、拆分、删除后的 patch
  存活与冲突语义；不要在 worker 中根据歌词或相邻音高隐式猜测 melisma。
