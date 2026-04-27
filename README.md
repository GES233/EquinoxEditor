# Equinox

[English](README.en.md)

Equinox 是一个基于 Elixir/Phoenix LiveView 与 Svelte 5 的歌声合成编辑器原型，目标是探索可视化节点调度、增量生成缓存、外部数据介入和可编辑中间参数在 SVS/DAW-like 工作流中的结合。

它基于 Orchid 生态构建渲染与调度内核，并在前端提供类似 OpenUTAU 的轻量级 WebUI。

Equinox 现在按类似 Nx 的结构拆为 `/domain` 、 `kernel/` 与 `ui_shell/`。

## 目录

```text
domain/    # 领域模型本体
kernel/    # 可独立运行的编辑器内核、调用领域模型、整合 Orchid 调度
ui_shell/  # Phoenix LiveView shell + Svelte 5 前端岛
```

- **Domain**：无外部依赖的纯领域模型。
- **Kernel**：纯编辑器内核、会话、项目模型、渲染调度。
- **UI Shell**：托管浏览器界面，通过本地 path dep 依赖 `kernel/`。
- 根目录仅保留仓库级文档与约定，不承载运行时代码。

## 前置条件

- [Elixir](https://elixir-lang.org/install.html) （还需要安装 Erlang/OTP）
- [Node.js](https://nodejs.org/) （前端资源）

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
