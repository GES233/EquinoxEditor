# Equinox

[English](README.md)

Equinox 是基于 Orchid 源于开发者高中时想法（节点编辑图+可编辑/介入数据）的概念验证。

因为技术栈，此应用会成为以 WebUI 为主的一个类似于 OpenUTAU 的轻（jian）量（lou）应用。

本项目是以下几个项目精神上的继承者：

- **QyEditor**： 本项目最早的原型，计划整合贝塞尔曲线与 DAG 自组织与调度。
- **Quincunx**： 验证了前端友好的 Node-Edge-based 工作流的可行性以及整合了 Orchid 生态一系列的插件。 
- **KinoBayanroll**： 花费了开发者数十美元（中转站按量计费 SOTA 模型的开销）已验证 Svelte5 + SvelteFlow 的可行性的一个基于 Livebook 的 Kino 插件。

Equinox 是将其「固化」成单个 Phoenix + Svelte 应用的成果，脱离了难以维护的 Kino 插件。

## 架构

```
Equinox = Kernel + DomainApp + UI
```

- **Kernel**（内核）： 增量生成应用与函数式前端（DAG + Intervention + Incremental Generation + Heavy Services）
- **DomainApp**（领域模型）： Domain-specific logic for vocal synthesis (Projects, Tracks, Notes, Curves, Topologies).
- **UI**: Phoenix LiveView shell hosting Svelte 5 components (Piano Roll, Node Editor, Arranger) as islands.

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

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser. The Phoenix dev server automatically watches and builds Vite output.

## 技术栈

### 后端

- **Orchid Ecosystem**: `orchid` (DAG engine), `orchid_symbiont` (OTP integration), `orchid_stratum` (cache), `orchid_intervention`.
- **Phoenix Framework**: `phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `jason`.

### 前端

- **Svelte 5** (Runes mode)
- **SvelteFlow** (Node editor canvas)
- **Vite** & **TypeScript**
- **Tailwind CSS v4**

## 开发工具

For frontend development without the backend, you can use the Vite dev server with a mock bridge:

```bash
cd assets
npm run dev
```

Run checks before committing:

```bash
mix precommit
cd assets && npm run check
```

## 了解更多

- [Phoenix 框架官网](https://www.phoenixframework.org/)
- [Svelte 文档](https://svelte.dev/docs)
- Review `.agents/AGENTS.md` for detailed architectural decisions and domain models.
