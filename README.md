![icon](artwoks/icon_dark.svg)

# Equinox

[English](README.en.md)

Equinox 是基于 Neume 内核的歌声合成编辑器。Neume 是这套编辑范式的名字（Tamale/Coconut 编辑模型：History、pin 干预、check/repatch 纪律），也是它的 Elixir 实现。具体合成运行时作为独立适配器接入；当前 `apps/neume_opu_ds` 通过 Oi 管线完成 OpenUTAU DiffSinger 分析与渲染。

## Umbrella 结构

- `apps/coconut`：编辑状态、History、Patch、Resolve 与序列化的事实来源；由原独立 Coconut 仓库收归维护。
- `apps/coconut_oi`：仅负责 Coconut intervention 到 Oi data/execute 边界的薄适配。
- `apps/neume`：稳定的编辑、pin 身份/裁决和 runtime/provider 契约，以及通用分窗、缓存、混音与制品语义。
- `apps/neume_opu_ds`：OpenUTAU DiffSinger 声库扫描、probe/对齐、Pure-FP、Python worker 与 Oi 合成图。

项目不再依赖同级目录中的 Coconut 或 CoconutOi checkout。

## 验证

```powershell
mix deps.get
mix compile --force --warnings-as-errors
mix test
mix format --check-formatted
mix dialyzer
```

Neume 的稳定边界见 [`apps/neume/README.md`](apps/neume/README.md)，真实 DiffSinger 环境见 [`apps/neume_opu_ds/README.md`](apps/neume_opu_ds/README.md)；实现进度、验证基线、当前限制和后续路线见 [`AGENTS.md`](AGENTS.md) 的 Neume Implementation Status 一节。
