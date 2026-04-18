# Equinox

[简体中文](README.md)

**Equinox** is a vocal synthesis editor built in Elixir. It provides an interactive editing experience for AI singing voice synthesis, targeting desktop-class DAW-like workflows delivered through the web.

This repository is the successor to two prior prototypes:
- **Quincunx**: Validated the Orchid-based DAG kernel and intervention model.
- **KinoBayanroll**: Validated the Svelte 5 + SvelteFlow frontend stack.

Equinox consolidates those lessons into a single **Phoenix + Svelte** application, abandoning Livebook/Kino hosting entirely.

## Architecture

```
Equinox = Kernel + DomainApp + UI
```

- **Kernel**: Incremental generation orchestration (DAG + Intervention + Incremental Generation + Heavy Services).
- **DomainApp**: Domain-specific logic for vocal synthesis (Projects, Tracks, Notes, Curves, Topologies).
- **UI**: Phoenix LiveView shell hosting Svelte 5 components (Piano Roll, Node Editor, Arranger) as islands.

## Prerequisites

- [Elixir](https://elixir-lang.org/install.html) (with Erlang/OTP)
- [Node.js](https://nodejs.org/) (for frontend assets)

## Getting Started

1. Install backend dependencies and compile:

   ```bash
   mix deps.get
   mix compile
   ```

2. Install frontend dependencies:

   ```bash
   npm install --prefix assets
   ```

3. Start the development server:

   ```bash
   iex -S mix phx.server
   ```

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser. The Phoenix dev server automatically watches and builds Vite output.

## Tech Stack

### Backend
- **Orchid Ecosystem**: `orchid` (DAG engine), `orchid_symbiont` (OTP integration), `orchid_stratum` (cache), `orchid_intervention`.
- **Phoenix Framework**: `phoenix`, `phoenix_live_view`, `phoenix_html`, `bandit`, `jason`.

### Frontend
- **Svelte 5** (Runes mode)
- **SvelteFlow** (Node editor canvas)
- **Vite** & **TypeScript**
- **Tailwind CSS v4**

## Development Tools

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

## Learn More

- [Phoenix Framework Official Website](https://www.phoenixframework.org/)
- [Svelte Documentation](https://svelte.dev/docs)
- Review `./AGENTS.md` for detailed architectural decisions and domain models.
