# DiffSinger Pure-FP 手术

`freeze_noise.py` 把 DiffSinger ONNX 图内无 seed 的随机算子替换为显式的
host-noise 输入，并把派生 ONNX 与 `fp_manifest.json` 写入独立目录。原声库
始终只读。

Neume 默认在 `tmp/onnx_fp/<声库短名>/` 构建并使用 FP 模型；传入
`fp: false` 可退回原始 stock 模型。`seed` 决定 host noise：相同输入、声库、
运行时与 seed 应逐比特复现，改变 seed 会得到不同 take。

## 许可证

派生 ONNX 是否允许修改、分发或商用，完全取决于具体声库和模型的许可证。
默认输出目录已被仓库根 `.gitignore` 的 `tmp/` 规则排除；不要在没有明确许可
时提交或发布派生模型。

## 手工构建

```sh
python apps/neume/priv/fp/freeze_noise.py <voicebank> --out tmp/onnx_fp/<name>
```

## 真机验收

```sh
cd apps/neume
mix run priv/fp/fp_acceptance.exs
```

门禁包括：关闭缓存后同 seed WAV 逐字节一致、异 seed 不同，以及 1 秒短
样本的 stock/FP RMS 位于 2× 包络内。可通过 `DS_VOICEBANK`、`DS_PYTHON`、
`FP_PYTHON` 覆盖本机路径。
