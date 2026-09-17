# 模型输出底料的 pin

`model_output_v1` 实现“在可重放模型输出上修改”：底料来自对应阶段的
局部实际输出，不从歌词、声库、seed 或谱面输入签名代替推导。
输入变化但局部输出相同就存活；改 A 导致 B 的底料漂移，冲突定位到 B。
legacy 和 v2 pin 的原有语义不变，不自动迁移或替换。

## 执行与身份

`Neume.OutputPipeline` 声明 `duration → pitch → result` Oi 图。
`Neume.Output` 实现 `OrchidIntervention.Operate`，启用 producer 后，
用 `Tamale.Patch.resolve/2` 比较局部输出底料，再合并修改。
同阶段各 pin 都对比未加本阶段修改的输出；pitch 消费已合并的 duration。
依赖顺序来自图，UI 不持有另一份依赖关系。

局部区域当前为一枚音符实际拥有的全部音素：底料含该区域的数值、音素
语言/符号/边界、绝对歌曲帧区间与帧率。浮点值用 IEEE 64 位字节的十六进制
字符串进入 Tamale digest，不设容差。音高数值相同但有效域变化也会冲突。
运行配置本身不进身份；它造成输出变化时才影响身份。

| channel | payload 的 `values` | 合并方式 |
|---|---|---|
| `duration` | 按所属音素顺序的非负整数帧长 | 保持该音符区域总帧数，重排内部边界；单个音素可为 0 帧 |
| `pitch` | `[[区域内帧偏移, 绝对 MIDI], ...]` | 1–256 个严格递增点，首尾点间线性插值，其外保留预测 |

完整 payload 为 `%{schema: "model_output_v1", channel: "pitch" 或 "duration", values: ...}`。
当前不编辑音素序列、不改变区域总时长、不提供任意子 span 或 Bezier 输出型 pin。
同一音符同一 channel 只允许一份输出型 pin，歧义不静默覆盖。

## 编辑与冲突

- `Neumu.extract_output/2` 返回 `regions`、`entries` 与
  `%{track_id, history_pin, history_seq}` 令牌；每个投影含 digest、原始数值、
  音素边界和 `blocked`。不会下发可伪造的底料，也不产生历史边。
- `Neumu.put_output/7` 携带区域 digest 和提取令牌。后端重放并校验底料，
  通过 Coconut History 挂载/替换；模型执行在工程进程外，提交时再原子检查
  cursor 与 seq，期间继续编辑不会被旧结果覆盖。
- `Neumu.repatch_output/4` 显式沿用原修改并签当前底料；已不能表达则
  `:degraded`，原件保留。上游冲突未解决时不能确认下游。
- `Neumu.unmount_pin/4` 移除；修改、重挂和移除均可撤销并随工程存读。
  旧 `repatch`/`replace_pin` 不隐式转换输出型 pin。

冲突统一进入 check/render 报告，`stage: :output`，附 channel、note_id、
patch_id。冲突不禁止继续编辑，但禁止将失效修改当作有效结果渲染。
UI 的提示可折叠，折叠不重签；显式沿用后若再次漂移，仍重新告警。
pitch 模型失败保留已取得的 duration 投影，失败的 pitch 不产生伪造底料。

## runtime 边界

真实 DiffSinger 使用 Modified Pure-FP + CPU；Stock 随机路径与实验 GPU
返回 `:replayable_cpu_runtime_required`，不承诺精确重放。
worker 新增 `duration` / `pitch` 请求，传输已有的分析数组，ONNX 中间大张量
仍留在 worker。合并后的 ph_dur/pitch 直接交给现有 synthesis 图，不重算预测。

mock 共用同一图与裁决，用确定性演示曲线及歌曲时间轴验证交互，不冒充真实
G2P 或声学模型。mock 暂不混合旧输入约束与新输出型 pin；真实 adapter 保留
旧约束作为上游条件，同一音符同一 channel 的迁移仍需先显式移除旧 pin。

真实声库测试覆盖重复提取、duration → pitch 漂移、重挂后 WAV 合成，以及
改 A 导致 B 漂移；核心测试覆盖同输出存活、跨乐句隔离、降级、存读和撤销。
Channel 与浏览器测试验证非模态冲突、过期令牌和延迟回复丢弃。
