# Equinox

[简体中文](README.md)

**Equinox** is a vocal synthesis editor built in Elixir. It provides an interactive editing experience for AI singing voice synthesis, targeting desktop-class DAW-like workflows delivered through the web.

This repository is the successor to two prior prototypes:
- **Quincunx**: Validated the Orchid-based DAG kernel and intervention model.
- **KinoBayanroll**: Validated the Svelte 5 + SvelteFlow frontend stack.

Equinox consolidates those lessons into a single **Phoenix + Svelte** application, abandoning Livebook/Kino hosting entirely.

Equinox is organized into three directories: `domain/`, `kernel/`, and `ui_shell/`.

## Layout

```text
domain/    # zero-dependency domain model
kernel/    # standalone editor kernel, domain model, Orchid orchestration
ui_shell/  # Phoenix LiveView shell + Svelte 5 islands
```

- **Domain**: pure data structures and domain logic (notes, tracks, projects, timeline, phonemes, curves). Zero dependencies.
- **Kernel**: core editor logic, sessions, project model, render dispatch.
- **UI Shell**: browser-facing shell that depends on `kernel/` via a local path dependency.
- The repository root now keeps repo-level docs and conventions only.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (with Erlang/OTP)
- [Node.js](https://nodejs.org/) (for frontend assets)

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
cd ui_shell/assets && npm run check
```

## Architecture

```text
Equinox = Domain + Kernel + UI Shell
```

- **Domain**: pure domain types and logic, decoupled from Kernel and UI.
- **Kernel**: incremental generation, DAG orchestration, intervention, cache, heavy services.
- **UI Shell**: Phoenix LiveView shell hosting Svelte 5 components for Piano Roll, Node Editor, and Arranger.

## Learn More

- [Phoenix Framework](https://www.phoenixframework.org/)
- [Svelte Docs](https://svelte.dev/docs)
- [Orchid](https://hex.pm/packages/orchid)
- Review `./AGENTS.md` for architectural conventions.
