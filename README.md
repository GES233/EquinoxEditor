# Equinox

[English](README.en.md)
Equinox 是基于 Orchid 源于开发者高中时想法（节点编辑图+可编辑/介入数据）的概念验证。

因为技术栈，此应用会成为以 WebUI 为主的一个类似于 OpenUTAU 的轻（jian）量（lou）应用。

本项目是以下几个项目精神上的继承者：

- **QyEditor**： 本项目最早的原型，计划整合贝塞尔曲线与 DAG 自组织与调度。
- **Quincunx**： 验证了前端友好的 Node-Edge-based 工作流的可行性以及整合了 Orchid 生态一系列的插件。 
- **KinoBayanroll**： 花费了开发者数十美元（中转站按量计费 SOTA 模型的开销）已验证 Svelte5 + SvelteFlow 的可行性的一个基于 Livebook 的 Kino 插件。

Equinox 现在按类似 Nx 的结构拆为 `kernel/` 与 `ui_shell/`。

## 目录

```text
kernel/    # 可独立运行的编辑器内核、领域模型、Orchid 调度
ui_shell/  # Phoenix LiveView shell + Svelte 5 前端岛
```

- **Kernel**：纯编辑器内核、会话、项目模型、渲染调度。
- **UI Shell**：托管浏览器界面，通过本地 path dep 依赖 `kernel/`。
- 根目录仅保留仓库级文档与约定，不承载运行时代码。

## 前置条件

- [Elixir](https://elixir-lang.org/install.html) （还需要安装 Erlang/OTP）
- [Node.js](https://nodejs.org/) （前端资源）

## 开发

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
cd kernel && mix precommit
cd ui_shell && mix precommit
cd ui_shell/assets && npm run check
```

## 架构

```text
Equinox = Kernel + UI Shell
```

- **Kernel**：增量生成、DAG、数据介入、缓存、重服务。
- **UI Shell**：Phoenix LiveView shell 托管 Svelte 5 组件（Piano Roll、Node Editor、Arranger）。

## 了解更多

- [Phoenix 框架官网](https://www.phoenixframework.org/)
- [Svelte 文档](https://svelte.dev/docs)
- [Orchid](https://hex.pm/packages/orchid)
- \[**If You are Agent or AI Assistant**\] 请查看 `./AGENTS.md`
