![icon](artwoks/editor_cyan.svg)

# Equinox

[简体中文](README.md)

**Equinox** is a vocal synthesis editor built in Elixir. It provides an interactive editing experience for AI singing voice synthesis, targeting desktop-class DAW-like workflows delivered through the web.

This repository is the successor to three prior prototypes:
- **QyEditor**: The earliest prototype that planned to integrate Bézier curves, DAG self-organization, and scheduling.
- **Quincunx**: Validated the Orchid-based DAG kernel and intervention model.
- **KinoBayanroll**: Validated the Svelte 5 + SvelteFlow frontend stack.

Equinox consolidates those lessons into a single **Phoenix + Svelte** application, abandoning Livebook/Kino hosting entirely.

Equinox is organized into three core directories: `domain/`, `kernel/`, and `ui_shell/`, with an additional `engine_adapters/` sibling that hosts reference engine adapters and real-inference PoCs (DiffSinger, UTAU, etc.).

## Layout

```text
Equinox = Domain + Kernel + UI Shell (+ engine_adapters as built-in PoC)

domain/          # domain model built on coconut (+tamale)
kernel/          # standalone editor kernel, domain model, Orchid orchestration
ui_shell/        # Phoenix LiveView shell + Svelte 5 islands
engine_adapters/ # reference engine adapters: DiffSinger sidecar, UTAU compat, etc. (userland plugin shape)
```

- **Domain**: pure data structures and domain logic (notes, tracks, projects, timeline, phonemes, curves), built on coconut — an engine-agnostic editor core (editing/rendering/serialization) with tamale as its rebase kernel, both maintained by the same developer.
- **Kernel**: core editor logic, sessions, project model, render dispatch; mounts concrete engines via the `Equinox.Kernel.EngineAdapter` contract.
- **UI Shell**: browser-facing shell that depends on `kernel/` via a local path dependency.
- **engine_adapters/**: built-in reference engine adapters and real-inference PoCs proving the `EngineAdapter` contract; path-depends on `domain/` + `kernel/` and is not depended on in reverse, so it can be extracted as standalone plugins later.
- The repository root now keeps repo-level docs and conventions only.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (with Erlang/OTP)
- [Node.js](https://nodejs.org/) (for frontend assets)
- *(Optional)* [Rust](https://rust-lang.org) or [Zig](https://ziglang.org/) — may be needed for future NIF components; not currently enabled.

## Development

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

During UI shell development, Vite watches `ui_shell/assets` and writes bundles into `ui_shell/priv/static/assets`.

### Checks

```bash
cd domain && mix precommit
cd kernel && mix precommit
cd ui_shell && mix precommit
cd engine_adapters && mix precommit
cd ui_shell/assets && npm run check
```

## Architecture

```text
Equinox = Domain + Kernel + UI Shell
```

- **Domain**: pure domain types and logic, decoupled from Kernel and UI.
- **Kernel**: incremental generation, DAG orchestration, intervention, cache, heavy services; engine adapters are loaded as userland plugins.
- **UI Shell**: Phoenix LiveView shell hosting Svelte 5 components for Piano Roll, Node Editor, and Arranger.
- **engine_adapters/**: built-in reference adapters and real-inference PoCs (DiffSinger, UTAU).

## Learn More

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Svelte Docs](https://svelte.dev/docs)
- [Orchid](https://hex.pm/packages/orchid)
- [Coconut](https://github.com/GES233/Coconut) / [Tamale](https://github.com/SynapticStrings/Tamal)
- Review `./AGENTS.md` for architectural conventions.
