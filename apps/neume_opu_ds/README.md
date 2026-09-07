# Neume OpenUTAU DiffSinger Runtime

本应用实现 `Neume.Runtime` 与 `Neume.Voicebank.Provider`，封装当前
OpenUTAU DiffSinger 声库格式、Stock/Modified 变体、Pure-FP 工艺、Oi
analysis/synthesis 图和常驻 Python worker。

Neume 的 pin 身份、check/repatch 和工程持久化语义不依赖本应用；工程文件仍
只保存 `{name, engine, digest}`，打开时由 `Neume.Voicebank.Registry` 在本机
重新解析 runtime entry。模型后端、seed、FP manifest 与 worker 路径只进入
执行和缓存身份，不进入 pin 身份。

Python 环境需要 `onnxruntime`、`numpy`、`soundfile`、`pyyaml`；中文 G2P 还
需要 `pypinyin`，构建 Modified 模型另需 `onnx`。原声库保持只读，派生模型
仍写入 gitignored 的 `tmp/onnx_fp/<voicebank-digest>/`。

```powershell
mix test apps/neume_opu_ds/test
cd apps/neume_opu_ds
python -m unittest discover -s priv/diffsinger -p "test_*.py"
```
