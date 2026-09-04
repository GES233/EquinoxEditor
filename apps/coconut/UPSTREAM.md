# Coconut 来源与维护策略

Coconut 已从独立仓库收归 Equinox umbrella，后续活跃开发在本目录进行。

- 原仓库：<https://github.com/GES233/Coconut>
- 导入提交：`b592e1086912604cb28df078fb8899a0687bd639`
- 导入方式：最终 tracked-source 快照，不合并原仓库 Git 历史
- 原仓库状态：迁移验收完成后作为独立时期的公开只读档案归档

## 边界

Coconut 是引擎无关的编辑内核，拥有编辑状态、History、Patch、Resolve 与序列化语义。它不拥有歌声引擎、Oi 图、轨道调度、多轨混音、播放或导出管理。

若需要追溯导入前历史，请在原仓库按上述提交查询。Equinox 中对 Coconut 的修改与调用方修改应在同一提交或同一变更集中保持原子性。
