# CoconutOi

CoconutOi 是 Equinox umbrella 内部的薄桥，把 `Coconut.Render.Engine` 请求翻译为 Oi 的执行输入。

它只负责两件事：

1. `CoconutOi.OrchidAdapter.Assemble` 将 Coconut 按音符组织的 intervention 聚合到 Oi 的嵌套 `data`；
2. `CoconutOi.OrchidAdapter` 完成 Coconut engine check/render 边界，并调用 `Oi.execute/2`。

## 不属于本应用的职责

- 分数编辑、History、Patch 与序列化属于 Coconut；
- DiffSinger 的编译、probe、对齐、推理和制品属于 Neume；
- 多轨的轨道调度、混音、总线和导出汇聚由 Neume 声明的 Oi graph/steps 实现；
- 播放、任务管理和用户界面属于后续产品外壳。

独立仓库中的 toy pipeline、示例 steps 和重复端到端验收没有迁入。真实边界由本应用的聚合单测以及 Neume 的 mock/真实引擎测试共同覆盖。

## 来源

- 原独立仓库提交：`8dfaade34b1b2f77852124a97e351bd0596b521f`
- 迁入后仅保留当前生产路径使用的 adapter 与 assemble 语义
