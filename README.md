# Equinox

[English](README.en.md)

Equinox 是基于 Orchid 源于开发者高中时想法（节点编辑图+可编辑/介入数据）的概念验证。

因为技术栈，此应用会成为以 WebUI 为主的一个类似于 OpenUTAU 的轻（jian）量（lou）应用。

本项目是以下几个项目精神上的继承者：

- **QyEditor**： 本项目最早的原型，计划整合贝塞尔曲线与 DAG 自组织与调度。
- **Quincunx**： 验证了前端友好的 Node-Edge-based 工作流的可行性以及整合了 Orchid 生态一系列的插件。 
- **KinoBayanroll**： 花费了开发者数十美元（中转站按量计费 SOTA 模型的开销）已验证 Svelte5 + SvelteFlow 的可行性的一个基于 Livebook 的 Kino 插件。

Equinox 是将其「固化」成单个 Phoenix + Svelte 应用的成果，脱离了难以维护且最优方案为绑定成熟 JSLib 的 Kino 插件。

## 架构

```
Equinox = Kernel + DomainApp + UI
```

- **Kernel**（内核）： 增量生成应用与函数式前端（DAG + 外部数据介入 + 基于缓存的增量生成 + 重服务的独立运行与依赖注入）
- **DomainApp**（领域模型）： 声乐合成的领域特定逻辑（项目、轨道、音符、曲线、拓扑）
- **UI**: 由 Phoenix LiveView shell 以 Islands Architecture 托管 Svelte 5 组件（钢琴卷帘、节点编辑器、编曲器）

## 前置条件

- [Elixir](https://elixir-lang.org/install.html) （还需要安装 Erlang/OTP）
- [Node.js](https://nodejs.org/) （前端资源）

## 开始

1. 安装后端的依赖并编译：

   ```bash
   mix deps.get
   mix compile
   ```

2. 安装前端的依赖项目：

   ```bash
   npm install --prefix assets
   ```

3. 运行服务器：

   ```bash
   iex -S mix phx.server
   ```

之后可以通过浏览器访问 [`localhost:4000`](http://localhost:4000) 。Phoenix 开发服务器会自动监视并构建 Vite 输出。

## 技术栈

### 后端

- **Orchid 生态**：`orchid`（DAG 引擎）、`orchid_symbiont`（复杂任务的 OTP 挂载）、`orchid_stratum`（缓存）、`orchid_intervention`（数据介入）。
- **Phoenix 框架**：`phoenix`、`phoenix_live_view`、`phoenix_html`、`bandit`、`jason`。

### 前端

- **Svelte 5** (Runes mode)
- **SvelteFlow** (Node editor canvas)
- **Vite** & **TypeScript**
- **Tailwind CSS v4**

## 开发工具

对于不需要后端或没有 BEAM 环境的前端开发，您可以使用带有模拟桥接的 Vite 开发服务器：

```bash
cd assets
npm run dev
```

提交前请运行检查（如果没有安装 Elixir 且仅涉及前端的改动只需要 `npm` 即可）：

```bash
mix precommit
cd assets && npm run check
```

## 了解更多

- [Phoenix 框架官网](https://www.phoenixframework.org/)
- [Svelte 文档](https://svelte.dev/docs)
- \[**If You are Agent or AI Assistant**\] 请查看 `./AGENTS.md` 文件，了解详细的架构决策和领域模型。
