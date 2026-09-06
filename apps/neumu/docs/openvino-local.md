# 本机 OpenVINO 实验后端

## Disclaimer

这是显式选择的本机实验，不是 DiffSinger 通用兼容性承诺。当前只对 Arc A770、
OpenVINO 2026.3.1、Asaritsu Pure-FP 的有限输入做过验证。换声库、模型、驱动、
精度或输入形状可能失败、变慢或产生不同结果。不保证 CPU/GPU 输出相同，也不
保证 GPU 冷/热运行逐字节确定性。数值差异不等于听感判断，重要工程保留 CPU
对照；当前声库资产不因此获得新的分发或托管授权。

用户接受这些已知限制后可以继续本地试用，不以解决所有 GPU 问题作为试用前提。

## 选择后端

不拆现有协议：Neumu 继续通过 Neume 的 `check` / `render` 调用同一个 NDJSON
worker。默认 `:cpu` 不需要 OpenVINO；实验模式 `:openvino` 把
variance/acoustic/vocoder 放到 GPU/f32，linguistic、duration、pitch 留在 CPU。
GPU 编译或调用失败会返回错误，不静默改走 CPU。

```elixir
opts = [
  voicebank_registry: registry,
  python: ["D:/CodeRepo/Qy/equinox/tmp/openvino_probe/venv/Scripts/python.exe"],
  diffsinger_backend: :openvino,
  output_dir: "tmp/neumu-openvino"
]

{:ok, _pid} = Neumu.create_project("local-gpu", opts)
{:ok, _pin} = Neumu.add_track("local-gpu", "lead", voicebank_id)
```

`registry` / `voicebank_id` 使用既有声库选择流程；Stock 与 Modified 仍是不同
声库身份。后端只是运行选项，不更改工程 History、pin 底料或声库签名；
`load_project/3` 也要传相同选项，不把本机设备和 Python 路径持久化。
要切回 CPU，可关闭工程后以 `diffsinger_backend: :cpu` 重新打开。

上述 Python 路径是本机隔离实验环境的例子，其他机器应替换。安装依赖时使用
独立环境，不覆盖现有推理环境；除 worker 原有依赖外需安装 `openvino`，
本机验证版本为 `2026.3.1`。不需要加载旧 `D:/Intel` SDK 的 setupvars，避免
`PYTHONPATH` / DLL 路径把隔离环境重新指向旧版。

## 生命周期与缓存

- 沿用当前常驻 worker；同一配置复用，CPU/OpenVINO 的 worker 身份隔离。
- GPU 模型只在 worker 初始化时编译一次，使用动态形状。中间张量留在 Python；
  返回数组复制后才交给后续阶段，避免引用被后续推理复用的输出缓冲区。
- 声库首次加载、GPU 编译、新长度首次执行仍可能明显等待；ready 不等于所有
  长度已预热。UI 不应把模型等待当作编辑命令必须同步完成的部分。
- 实验模式强制关闭窗口 WAV 缓存，即使传入 `cache: true` 也不读写该缓存。
  这不影响 compiled model 的常驻复用或已生成制品的正常存储。
- 生产默认仍走 CPU；升级 Python 包、OpenVINO 或驱动后重启应用及其 worker，
  不在同一运行进程中混用旧 session。OpenVINO 模式不保证 Pure-FP 字节确定性。
- 本次不接新的 Symbiont 生命周期、不重构现有 Oi 图，也不拆协议与 DiffSinger
  实现；服务管理可以另行替换，不改变本次 facade 选项。

## 验证

无 GPU 测试：

```powershell
mix test apps/neume/test/neume/diff_singer_fp_test.exs apps/neumu/test/neumu/inference_backend_test.exs
python -m unittest discover -s apps/neume/priv/diffsinger -p 'test_*.py'
```

真实 GPU facade 测试默认排除，显式提供本机环境和已存在的 Pure-FP manifest：

```powershell
$env:DS_VOICEBANK = 'E:/ProgramAssets/OpenUTAUSingers/Asaritsu'
$env:DS_PYTHON = 'D:/CodeRepo/Qy/equinox/tmp/openvino_probe/venv/Scripts/python.exe'
$env:DS_FP_MANIFEST = 'D:/CodeRepo/Qy/equinox/tmp/onnx_fp/da62cb2558e59478-v1/fp_manifest.json'
mix test --include openvino apps/neumu/test/neumu/openvino_integration_test.exs
```

测试走 create → add track/note → check → 两次异步 render → 导出 → 保存/重开。
只验证集成与有效音频，不以 CPU/GPU hash 相等作为通过条件，不替代听审或完整
Pure-FP 确定性验收。不构建、不修改原声库模型。
