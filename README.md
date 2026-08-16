![icon](artwoks/editor_cyan.svg)

# Equinox

[English](README.en.md)

Equinox 是一个基于 Elixir/Phoenix LiveView 与 Svelte 5 的歌声合成编辑器原型，目标是探索可视化节点调度、增量生成缓存、外部数据介入和可编辑中间参数在 SVS/DAW-like 工作流中的结合。

它基于 [Orchid 生态](https://hex.pm/packages/orchid)构建渲染与调度内核，并在前端提供类似 OpenUTAU 的轻量级 WebUI。

Equinox 现在按类似 Nx 的结构拆为三个核心库 `domain/` 、 `kernel/` 与 `ui_shell/`，并在本仓库内附带 `engine_adapters/` 作为引擎适配器的参考实现 / PoC 验证（DiffSinger/UTAU 等）。

其是以下几个项目精神上的继承者：

- **QyEditor**： 本项目最早的原型，计划整合贝塞尔曲线与 DAG 自组织与调度。
- ~~**Quincunx**~~ → **Oi**： 验证了前端友好的 Node-Edge-based 工作流的可行性以及整合了 Orchid 生态一系列的插件。 
- **KinoBayanroll**： 花费了开发者数十美元（中转站按量计费 SOTA 模型的开销）已验证 Svelte5 + SvelteFlow 的可行性的一个基于 Livebook 的 Kino 插件。

## 目录/架构

```text
Equinox = Domain + Kernel + UI Shell (+ engine_adapters as built-in PoC)

domain/          # 领域模型本体
kernel/          # 可独立运行的编辑器内核、调用领域、整合 Orchid
ui_shell/        # Phoenix LiveView shell + Svelte 5 前端岛
engine_adapters/ # 引擎适配器参考实现：DiffSinger sidecar、UTAU 兼容等（userland 插件形态）
```

- **Domain**：构建在 coconut 之上的纯领域模型[^dep]（音符、轨道、工程、时间线、音素、曲线等），是所有业务逻辑的基础。coconut 是引擎无关的编辑器核心（编辑/渲染/序列化），tamale 是其 rebase 内核。
- **Kernel**：增量生成、DAG、数据介入、缓存、重服务；通过 `Equinox.Kernel.EngineAdapter` 契约挂载具体引擎。
- **UI Shell**：托管浏览器界面，通过本地 path dep 依赖 `kernel/`。
- **engine_adapters/**：内建的参考引擎适配器与真实推理 PoC，证明 `EngineAdapter` 契约可行；它 path 依赖 `domain/` + `kernel/`，但不被反向依赖，未来可拆出为独立插件。
- 根目录仅保留仓库级文档与约定，不承载运行时代码。

[^dep]: coconut 与 tamale 由开发者本人维护并以本地 path 依赖方式接入；Orchid/oi 为 hex 依赖。`engine_adapters/` 是仓库内参考实现，不构成外部依赖。

## 前置条件

- [Elixir](https://elixir-lang.org/install.html) （还需要安装 Erlang/OTP）
- [Node.js](https://nodejs.org/) （前端资源）
- *(Optional)* [Rust](https://rust-lang.org) 或 [Zig](https://ziglang.org/) — 未来 NIF 组件可能需要；当前代码库未启用。

## 开发

### Domain

```bash
cd domain
mix test
```

### Kernel

```bash
cd kernel
mix deps.get
mix test
```

### UI Shell

```bash
cd ui_shell
mix deps.get
cd assets && npm install
mix phx.server
```

UI Shell 开发时会自动监视 `ui_shell/assets` 并输出到 `ui_shell/priv/static/assets`。

### 检查

```bash
cd domain && mix precommit
cd kernel && mix precommit
cd ui_shell && mix precommit
cd engine_adapters && mix precommit
cd ui_shell/assets && npm run check
```

## 了解更多

- [Phoenix 框架官网](https://www.phoenixframework.org/)
- [Svelte 文档](https://svelte.dev/docs)
- [Orchid](https://hex.pm/packages/orchid) / [Oi](https://hex.pm/packages/oi)
- [Coconut](https://github.com/GES233/Coconut) / [Tamale](https://github.com/SynapticStrings/Tamal)
- [**If You are Agent or AI Assistant**] 请查看 `./AGENTS.md`
