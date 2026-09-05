![icon](artwoks/icon_dark.svg)

# Equinox

[English](README.en.md)

Equinox 是一个歌声合成编辑器实验仓库。当前主线是无界面 Neume 内核，通过 Coconut 编辑模型、CoconutOi 适配层和 Oi 管线完成 DiffSinger 分析与渲染。

## Umbrella 结构

- `apps/coconut`：编辑状态、History、Patch、Resolve 与序列化的事实来源；由原独立 Coconut 仓库收归维护。
- `apps/coconut_oi`：仅负责 Coconut intervention 到 Oi data/execute 边界的薄适配。
- `apps/neume`：歌声引擎、probe/对齐、分窗缓存和制品；未来多轨调度、混音、总线与导出汇聚也由这里声明的 Oi graph/steps 实现。

项目不再依赖同级目录中的 Coconut 或 CoconutOi checkout。

## 验证

```powershell
mix deps.get
mix compile --force --warnings-as-errors
mix test
mix format --check-formatted
mix dialyzer
```

Neume 的使用方式、真实 DiffSinger 环境和当前限制见 [`apps/neume/README.md`](apps/neume/README.md) 与 [`apps/neume/STATUS.md`](apps/neume/STATUS.md)。
