# Neume

~~人类重写版本。~~ 第二轮迭代版本。

当前实现进度、验证基线、限制和后续路线见 [`STATUS.md`](STATUS.md)；多轨
runtime、Oi/NIF 以及 Neume/Neumu/UI 职责见
[`docs/design-2026-09-multitrack-runtime.md`](docs/design-2026-09-multitrack-runtime.md)。

## 当前闭环

无声库时使用确定性的 mock 图；传入仓库外的 OpenUtau DiffSinger 目录时，
走 `Coconut -> CoconutOi -> Oi -> Python/ONNX -> WAV`：

```elixir
{:ok, editor} =
  Neume.Editor.new(
    voicebank_path: "E:/ProgramAssets/OpenUTAUSingers/Asaritsu",
    voicebank_mode: :modified,
    python: ["D:/path/to/python.exe"],
    output_dir: "D:/temp/neume-renders",
    speaker: "Normal",
    steps: 8,
    seed: 0
  )
```

推理 Python 环境需要 `onnxruntime`、`numpy`、`soundfile`、`pyyaml`；中文歌词的
自动音素化还需要 `pypinyin`。Modified 变体当前采用 Pure-FP 工艺，首次显式构建时由 `fp_python`（默认系统
`python`，需额外安装 `onnx`）把图内随机算子改为 host noise 输入，派生 ONNX
写到 gitignored 的 `tmp/onnx_fp/<声库摘要>/`，原声库始终只读。相同输入与
`seed` 不依赖缓存也逐比特复现；换 seed 产生新 take。派生模型的分发/商用仍
服从具体声库许可证。

Stock 与 Modified 是两个独立声库身份（`:diffsinger_stock` / `:diffsinger_modified`），
不是同一个声库上的运行期开关。`Neume.Voicebank.Registry.discover/1` 可扫描多个
根目录或其直接子目录；发现只登记 Stock 和已经存在的 Modified manifest，绝不
自动修改 ONNX。需要构建时显式调用 `Registry.prepare_modified/3`。工程在每条 Vocal track 的 `extras[:neume][:voicebank]` 保存所选变体的
`{name, engine, digest}`；重新打开多轨工程时按各轨 signature 自动从 registry 解析。

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
吸收剩余帧。pitch intervention 可经 `Editor.mount_pitch/3` 挂载兼容折线，
或经 `Editor.mount_pitch_curve/3` 挂载 Coconut Bezier 控制点容器；Bezier
在宿主侧按真实声学帧 tick 栅格化，worker 不重复曲线数学。两种 pin 的
 digest 都钉在**输入事实签名**上（歌词/显式音素/melisma 归属/声库摘要，
2026-09-05 起替代 probe 物化序列）：改词、
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
系数，1.0 中立）是轨道挂载的工程事实：`Editor.update_globals/2` 写入
`track.extras[:neume][:globals]`（一条可 undo 的历史边），随工程保存/
加载往返，读档与 undo/redo 后自动重新派生到会话 render 配置；越界或
未知键在 check 的门禁聚合为 `%{kind: :global, ...}` entry。

调试导出：`Editor.export_debug(editor, path, opts)` 把当前轨打包成
debug.json（notes/pitch 帧网/音素边界/tempo/`meta.patches` 铆钉点/pin
控制点曲线；`span:` 裁剪 tick 区间，`raw?: true` 附无干预对照），
`tools/plot_render.py` 用 matplotlib 画钢琴卷帘 + pitch + 音素时序图
（`-o out.svg` 出矢量图，依赖 `pip install matplotlib`）。

analyze/check/render 共用瞬态 `Neume.Phrase`：空档 ≥ 3 拍切窗，逐窗 probe 的
错误带 track/phrase/span 定位并一次聚合；render 复用同次 check 的 probe，不重复
模型检查。窗口级 WAV 缓存按「声库摘要 + globals + 窗内音符 + pins + Modified/
Stock + seed + 修改工艺版本」失效，编辑后只重推内容变化的窗口。

多轨使用 `Neume.MultiTrack`：整个工程只持有一个 Coconut Session/History，
每条 Vocal track 只保留可重建的 `Neume.TrackRuntime`，独立解析声库、检查与
渲染，随后进入 Neume-owned Oi 图 `TrackGainPan → Mix → Master → Export`。
音符、pin、声库重绑定和 `mute/gain/pan` 都写入同一 History；多轨工程文件会
一并保存、恢复该 History。任一轨 check 失败时不会执行 master 导出。

## TODO

- [ ] ~~energy/breathiness/voicing 的逐帧曲线 channel（手绘编辑）~~——本版本
  不做，三旋钮保持轨道级全局系数；未来重启时普通表现曲线可作为仅结构
  裁决的 Patch，增量型干预（preserve、相对旧值）走 output base
  （coconut intervention 设计 §6.6），并与全局旋钮复合。
- [ ] Oi 多轨并发调度、播放与导出管理。
- [ ] 最小钢琴卷帘、音素边界编辑和播放 UI。
