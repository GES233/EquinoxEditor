# AGENTS.md

## Project Overview

**Equinox** is a vocal synthesis editor built in Elixir. It provides an interactive editing experience for AI singing voice synthesis, targeting desktop-class DAW-like workflows delivered through the web.

This repository is the successor to two prior prototypes:

- **Quincunx**: Validated the Orchid-based DAG kernel and intervention model.
    - Remote: [SynapticStrings/Quincunx](https://github.com/SynapticStrings/Quincunx)
- **KinoBayanroll** (Livebook Smart Cell): Validated the Svelte 5 + SvelteFlow frontend stack.
    - Remote: [GES233/kino_bayanroll](https://github.com/GES233/kino_bayanroll)
- **PoC Script**: (DiffSinger pipeline demo)
    - Remote: [simple_run.livemd](https://github.com/GES233/DiffSinger/blob/main/examples/diff_singer_model/simple_run.livemd)
    - Local: `C:/Users/Q/Downloads/simple_run.livemd`

Equinox consolidates those lessons into a single **Phoenix + Svelte** application, abandoning Livebook/Kino hosting entirely.

### Architecture Vision

```
Equinox = Kernel + DomainApp + UI
```

- **Kernel**: Incremental generation orchestration (DAG + Intervention + Incremental Generation + Heavy Services).
- **DomainApp**: Domain-specific logic for vocal synthesis (Projects, Tracks, Notes, Curves, Topologies).
- **UI**: Phoenix LiveView shell hosting Svelte 5 components (Piano Roll, Node Editor, Arranger) as islands.

## Project Structure

```
equinox/
├── lib/
│   ├── equinox/              # Core domain + Kernel
│   │   ├── application.ex
│   │   ├── project.ex        # Top-level session container
│   │   ├── track.ex          # Track (Context) with topology_ref
│   │   ├── editor/           # Edit actions, history
│   │   ├── session/          # Runtime session state
│   │   ├── topology/         # Topology registry + hydration
│   │   ├── kernel/           # Graph, Compiler, Engine, RecipeBundle
│   │   └── domain/           # Domain entities (Note, Slicer)
│   │
│   ├── equinox_web/          # Phoenix + Svelte shell
│   │   ├── application.ex
│   │   ├── endpoint.ex
│   │   ├── router.ex
│   │   ├── live/             # LiveView entrypoints
│   │   └── components/       # .heex + Svelte mount points
│   ├── equinox.ex
│   └── equinox_web.ex
│
├── assets/
│   ├── src/                  # Svelte 5 + TS source
│   │   ├── lib/
│   │   │   ├── stores/       # viewport.svelte.ts, node_registry.ts
│   │   │   ├── components/   # PianoRoll, NodeEditor, Arranger, ...
│   │   │   └── bridge/       # LiveView <-> Svelte transport
│   │   ├── piano_roll.ts     # Entry: Piano Roll island
│   │   ├── node_editor.ts    # Entry: Synth node editor
│   │   ├── arranger.ts       # Entry: Arranger island
│   │   └── app.ts            # Shared bootstrap + hooks
│   ├── css/
│   ├── index.html            # Vite dev entry (mock bridge)
│   ├── vite.config.ts
│   └── tsconfig.json
├── priv/static/              # Vite build output lands here
├── config/
├── AGENTS.md
└── mix.exs
```

## Essential Commands

```bash
# Elixir
mix deps.get
mix compile
mix test
mix format
iex -S mix
iex -S mix phx.server

# Frontend
npm install
npm run dev       # Vite dev server, uses mock bridge
npm run build     # Builds into priv/static
npm run check     # svelte-check + tsc
```

The Phoenix dev server should watch Vite output rather than invoke `esbuild`/`tailwind` Mix tasks directly. Configure `:watchers` in `config/dev.exs` to spawn `npm run dev` inside `assets`.

Use `mix precommit` alias when you are done with all changes and fix any pending issues

## Tech Stack

### Backend (lib/equinox)

Orchid ecosystem — workflow orchestration kernel:

- **orchid** (~> 0.6) — DAG engine.
- **orchid_symbiont** (~> 0.2) — OTP/GenServer service integration (used for heavy NIF-backed synth services).
- **orchid_stratum** (~> 0.2) — Deterministic content-addressable cache.
- **orchid_intervention** (~> 0.1) — External data injection semantics.

### Web (lib/equinox_web)

- **phoenix** (~> 1.8), **phoenix_live_view** (~> 1.1), **phoenix_html** (~> 4.1)
- **bandit** (~> 1.5), **jason**

### Frontend (assets/)

- **Svelte 5** (Runes mode) — mandatory. No Svelte 4 syntax.
- **SvelteFlow** (`@xyflow/svelte`) — node editor canvas.
- **Vite** — build tool; outputs to `priv/static`.
- **TypeScript** — strict mode.
- **Tailwind CSS v4** — via Vite plugin, not the Mix `tailwind` task.

> **No Kino, no Livebook, no LiteGraph.** These prototype dependencies are permanently retired.

## Frontend ↔ Backend Bridge

The **only** coupling between Svelte and Phoenix is a small typed interface, modeled after (and replacing) the old `KinoCtx`:

```ts
// assets/src/lib/bridge/index.ts
interface EquinoxBridge {
  root: HTMLElement;
  pushEvent<T>(name: string, payload: T): void;
  handleEvent<T>(name: string, handler: (payload: T) => void): () => void;
  // getBlob / requestBinary etc. for waveform assets
}
```

Two implementations exist:
1. **`LiveBridge`** — backed by a Phoenix LiveView Hook (`this.pushEvent`, `this.handleEvent`). Used in production.
2. **`MockBridge`** — backed by in-memory fixtures and `fetch`. Used by `npm run dev` standalone. Enables UI-only contributors to work without an Elixir toolchain.

**Svelte components receive a `bridge` prop; they must never import from `phoenix_live_view` or inspect `window.liveSocket` directly.** This discipline keeps the components portable and testable.

### Data flow
```
Svelte component
  └─ bridge.pushEvent("synth_graph_update", {nodes, edges})
      └─ LiveView Hook → LiveView handle_event/3
          └─ Equinox.Editor action → Project/Track state update
              └─ (optional) Kernel.Engine.run/2
                  └─ bridge.handleEvent("render_complete", {audio_ref})
```

## Core Domain Architecture

Inherited and simplified from Quincunx; data-driven in the Bumblebee spirit.

### 1. Data Hierarchy
- **Project / Session** — top-level container; owns tempo map, tracks, global undo/redo.
- **Track (Context)** — timeline/singer instance. Stores pure data only:
  - `topology_ref` (e.g., `"diffsinger:v1"`).
  - `model_id` / asset references (resolved at runtime).
  - `interventions` keyed by semantic UI keys.
- **Notes** — discrete events in **Ticks/Beats** (musical time), never raw ms.
- **Curves** — sparse control points (bezier / spline); rasterized to dense frames during compilation.

### 2. Topology & Package Management (Bumblebee-style)
- **Pure data persistence.** Projects never store executable closures or Orchid steps directly.
- **Registry & Hydration.** `topology_ref` → hydrates into an `Orchid.Recipe` composed strictly of `Module` steps.
- **Pluggable engines.** Third-party Hex packages may register new topologies. Assets (models, dictionaries) are resolved per-track and injected as Orchid inputs.

### 3. Translation Layer
- **Frontend speaks semantic keys** (e.g., `track_1.pitch_curve`, `track_1.acoustic.mel`).
- **Compiler** maps semantic keys ↔ Orchid `PortRef`s (`"node_id|port_name"`).
- **Interventions** collapse to exactly two kinds, mirroring `OrchidIntervention`:
  - `:input` — pre-execution initialization (e.g., notes → sequencer input).
  - `:output` — post-execution override / mix (e.g., user-painted pitch curve masks predicted pitch).

### 4. Topology Tearing (Runtime Optimization)
- **Data declaration ≠ runtime declaration.** The DAG shape is portable data; hardware strategies (cluster partitioning, Symbiont NIF teardown between batches to reclaim VRAM, laptop vs. workstation profiles) are a **compilation phase** applied when producing the final Orchid Recipe.

### 5. History
- Global undo/redo lives at the Session/Editor level, not per-segment. Designed to accommodate future OT/CRDT collaborative editing.

## Timing Model (SVS-Specific)

Three timing perspectives must be respected throughout the pipeline:

1. **Musical Time (Ticks / Beats)** — canonical storage, tempo-independent. Use `480` or `1920` ticks per beat.
2. **Acoustic Frames** — discrete NN steps, typically ~10ms or 12.5ms. Produced by rasterizing curves against the tempo map + frame rate.
3. **Audio Samples** — final waveform (44.1 / 48 kHz).

Conversions happen inside the Kernel/Compiler, never in Svelte.

## UI Shell Layout

The app presents a DAW-style window (see effect mockup). Major regions:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                                     Equinox                                          │
│ File  Edit                                                       Status  Help  About │
│                                                                                      │
├─────┬────┬─────────────────────────────────────────────────┬─────────────────────────┤
│     │    │┌─────┐ ┌──────┐ ┌──────────┐      Track Overview│    Arranger             │
│      M S │└─────┘ └──────┘ └──────────┘     (Determine how │                         │
├─────┬────┼──────────────────────────────────   track slice)│   ┌───┐                 │
│     │    │           ┌──────┐                              │   │#Sy│                 │
│      M S │           └──────┘                              │   │   ├────────────┐    │
├─────┬────┼─────────────────────────────────────────────────┤   │   │            │    │
│     │    │                                                 │   └───┘            │    │
│      M S ├──(present waveform here...)─────────────────────┤                    │    │
├────────┬─┴─────────────────────────────────────────────────┤   ┌───┐            ▼    │
│        │                                          PianoRoll│   │#Sy│          ┌─────┐│
│▌▌▌▌▌───┤                                                   │   │   ├─────────►│     ││
│        │                                                   │   │   │    ┌────►│     ││
│▌▌▌▌▌───┤                                                   │   └───┘    │ ┌──►│     ││
│        │                                                   │            │ │   │     ││
├────────┤           ┌───────────┐                           │   ┌───┐    │ │   └─────┘│
│        │           │           │                           │   │#Au│    │ │          │
│▌▌▌▌▌───┤      ┌───┐└───────────┘┌───┐                      │   │   ├────┘ │          │
│        │      │   │ he-   re    │   │                      │   │   │      │          │
│▌▌▌▌▌───┤ ┌───┐└───┘             └───┘                      │   └───┘      │          │
│        │ │   │ me                the                       │   ┌───┐      │          │
│▌▌▌▌▌───┤ └───┘                                             │   │   │      │          │
│        │  Let                                              │   │   ├──────┘          │
├────────┤                             ┌────────────────────┐│   │   │                 │
│        │                             │                    ││   └───┘                 │
│▌▌▌▌▌───┤                             └────────────────────┘│                         │
│        │                              soun-        -d      │    ...           Swelte │
│▌▌▌▌▌───┤                                                   │   ┌────┐          Flow  │
│        │                                                   │   │    │                │
└────────┴───────────────────────────────────────────────────┴───┴────┴────────────────┘
```

- **TrackList** — mute/solo/volume per track; vertical stack.
- **TrackOverview** — horizontal strip above Piano Roll showing slice boundaries decided by the Slicer node.
- **PianoRoll** — primary editing surface. Hybrid rendering (see below).
- **Arranger** — a second SvelteFlow canvas for mixing / offsets / multiple Synth outputs → final master.

A separate route hosts the **Synthesizer Node Editor** (per-track deep-edit view). Its topology mirrors the DiffSinger-family pipeline:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                             │
│                                           Syntheziser Node Editor                                           │
│                                                                                                             │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│    ┌───────────┐                                                                                            │
│    │Extra pitch│                                                                                            │
│    │ (Optional)├─────────────────────────┐    ┌─────────────────────────────┐                               │
│    │           │       ┌─────────────┐   │    │  Acoustic Model             │                               │
│    └───────────┘       │  Duration   │   │    ├─────────────────────────────┤                               │
│                        │ Prediction  │   │    │ *present mel spectrum       │                               │
│                      ┌►│             │   │    │   within current calc       │                               │
│                      │ │             │   │    │   transaction               │                               │
│                      │ │             │   │    │                             │                               │
│                      │ └─────────┬───┘   │    │                             │                               │
│                      │           │       │    │                             │                               │
│  ┌─────────────────┐ │┌──────────┤       │    │                             │                               │
│  │Note(with lyrics)│ ││          │       │    │                             │                               │
│  │   (required)    │ ││          ▼       ▼    │            /=\ ----         ├────┐                          │
│  │                 ▌─┤│ ┌─────────────┐┌───┐  │    /====\  /=\ ----         │    │                          │
│  │                 │ ││ │   Pitch     ││ M │  │    /----\  /=\ ----         │    │                          │
│  └─────────────────┘ ││ │ Prediction  ││ A │  │                             │    │                          │
│                      ├┼►│             ││ S │  └─────────────────────────────┘    │                          │
│                      ││ │             ││ K │                ▲                    │                          │
│                      ││ │             ││   │                │                    │                          │
│                      ││ └─────────────┘└─┬─┘                │                    │                          │
│                      ││                  │                  │                    │                          │
│                      │└────────┐         │Masked pitch      │                    ▼                          │
│                      │         ▼         │(partial override)│      ┌────────────────┐  ┌──────────────────┐ │
│   ┌────────────────┐ │ ┌──────────────┐  │                  │      │    Vocoder     │  │    Waveform      │ │
│   │   breathness,  │ │ │  Variance    │  │                  │      │                ├─►▌ (required node)  │ │
│   │   gender,      │ │ │   Model      │  │                  │      └────────────────┘  │                  │ │
│   │   ...          │ └►│              │  │                  │              ▲           └──────────────────┘ │
│   │                ├──►│              │◄─┴──────────────────┴──────────────┘                                │
│   │Extra Parameters│   │              │                                                                     │
│   │ (based on conf)│   └──────────────┘                                                                     │
│   └────────────────┘                                                                                        │
│                                                                                                             │
│                                                                                                             │
│                                                                                                             │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Users connect/disconnect ports; the Compiler validates against topology contracts.

## Piano Roll Architecture

- **Grid**: CSS `repeating-linear-gradient` bound to the `Viewport` rune store.
- **Notes**: absolute-positioned `<div>`s with viewport culling.
- **Curves**: SVG `<path>` (cubic beziers) with sparse control points.
- **Slicer overlay**: translucent vertical bands over the entire roll, sourced from backend slice computation.
- **Waveform overlay**: background `<canvas>` rendering stems / rendered audio.
- **Viewport**: a single Svelte 5 class (`Viewport`) managing `zoomX` (ms→px), `zoomY` (semitone→px), unbounded pan, and 30° angle-lock for pan/zoom gestures (inherited from KinoBayanroll).

### Interactions
- Double-click empty → add note.
- Double-click note → delete.
- Drag body → move (X/Y).
- Drag right edge → resize.
- TODO: inline lyric input (replace legacy `prompt()`), marquee/lasso multi-select.

## Code Conventions

### Elixir

- Return `{:ok, value}` / `{:error, reason}` from public APIs.
    - For some function can be chained.
- `@spec` on public functions.
- Pattern-match in heads; use `with` for ROP chains.
- `mix format` is law.
- Comments in Chinese are acceptable; **doc strings (`@doc`, `@moduledoc`) in Chinese are encouraged** for domain modules.
- Public-API names start with verbs: `create_`, `update_`, `list_`, `render_`, `compile_`.

### Svelte / TS

- **Svelte 5 Runes only** (`$state`, `$derived`, `$effect`, `$props`). No stores from `svelte/store` unless wrapping an external lib.
- `strict: true` in `tsconfig.json`.
- Components receive `bridge: EquinoxBridge` as a prop; never reach into globals.
- File-level CSS is scoped; shared utilities go through Tailwind.

### SvelteFlow

- **Do not use reserved `nodeTypes` names** like `input` / `output` — SvelteFlow silently injects styles. Use `custom_input` / `output_with_panel` etc.
- Keep node components under `assets/src/lib/components/node/`. `DynamicNode.svelte` is the fallback for step types not yet given a bespoke renderer.
- External packages register custom nodes via `registerNodeType(stepName, Component)` from `lib/stores/node_registry.ts`.

### Tailwind CSS v4

- `!` modifier goes at the **end**: `bg-amber-500!`, not `!bg-amber-500`.
- Gradients: `bg-linear-to-b`, not `bg-gradient-to-b`.
- Prefer the spacing scale (`min-w-55`) over arbitrary values (`min-w-[220px]`).

## Kernel Modules

Naming convention inside `lib/equinox/kernel/`:

| Module | Responsibility | Ancestor |
|---|---|---|
| `Equinox.Kernel.Graph` | `%Node{}`, `%Edge{}`, `%PortRef{}`, topological sort, cycle detection | Quincunx.Topology.Graph |
| `Equinox.Kernel.Compiler` | Graph → `RecipeBundle`; applies topology-tearing passes | Quincunx.Compiler.GraphBuilder |
| `Equinox.Kernel.RecipeBundle` | `{recipe, requires, exports, node_ids, interventions}` | Quincunx.Compiler.RecipeBundle |
| `Equinox.Kernel.Engine` | `run(bundle, interventions)` → `Orchid.run/3`; emits progress via PubSub | Quincunx.Renderer.Worker |
| `Equinox.Kernel.StepRegistry` | Dynamic step registration (built-in + third-party packages) | KinoBayanroll.StepRegistry |

Port key format stays `"node_id|port_name"` for interop with existing Orchid recipes.

## Testing

- Backend: ExUnit, doctests on pure functions, context-level tests for `Equinox.Editor` actions.
- Frontend: `svelte-check` + `vitest` for stores (especially `Viewport`, `node_registry`).
- E2E: deferred until LiveView shell stabilizes.

## Working Notes for Agents

- **When adding a new step type**: (1) register in `Equinox.Kernel.StepRegistry`, (2) expose its ports through the topology package, (3) optionally provide a bespoke Svelte node component — otherwise `DynamicNode` renders it.
- **When touching the bridge interface**: update both `LiveBridge` and `MockBridge` in the same change. The `MockBridge` is the contract.
- **When in doubt about Windows friendliness**: prefer pure-Elixir / pure-JS solutions over native bindings. If a NIF is required, isolate it behind `orchid_symbiont` so it can be torn down and restarted.
- **Do not reintroduce** `KinoCtx`, `to_source/1`, `broadcast_event/3`-style Kino plumbing, `KinoBayanroll.Registry`, or any Livebook Smart Cell hook. They are archaeology.
- **Reference prototypes** (read-only):
  - `D:/CodeRepo/Qy/Quincunx` — kernel reference.
  - KinoBayanroll codebase — Svelte component reference.
  - `C:/Users/Q/Downloads/simple_run.livemd` — DiffSinger pipeline PoC.

## Current Milestones

1. **M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.
2. **M1 — Piano Roll parity**: Port notes/viewport/grid/slicer overlay from KinoBayanroll.
3. **M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.
4. **M3 — Kernel integration**: End-to-end render (Note → DiffSinger recipe → Vocoder → Waveform) using Orchid.
5. **M4 — Arranger**: Second SvelteFlow canvas, multi-track mix, slice alignment.
6. **M5 — Curves**: SVG bezier layer + rasterization in the Compiler.
7. **M6 — History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.

## Agent Work Log

### 2026-04-17 (M0/M1 Data Architecture)
- **Restructured Core Domain (Pure Data)**: Removed Ecto schemas from `Equinox.Project`, `Equinox.Editor.Track`, `Equinox.Editor.Segment`. Converted them to strictly JSON-serializable pure Elixir structs using `Jason.Encoder`.
- **Global History & Clean Segments**: Explicitly removed `history` from `Segment` (history will be managed at the Project/Editor level). `Segment` no longer serializes its runtime `graph` or `cluster`, retaining only `notes` and `curves` (Pure Data) for storage and hash calculation.
- **Project Serialization**: Added symmetric `Project.to_json/1` and `Project.from_json/1` for full recursive hydration of `project.json` in the bundle architecture.
- **App Structure Fix**: Removed the incorrect `apps/` umbrella folder convention and aligned `AGENTS.md` with the actual standard Phoenix structure (`lib/equinox`, `lib/equinox_web`).

### 2026-04-17 (M2 Bridge Protocol & Hydration)
- **TypeScript Bridge Types**: Added explicit `ProjectData`, `TrackData`, `SegmentData`, `NoteData` interfaces to `assets/src/lib/bridge/index.ts` to mirror Elixir Pure Data exactly.
- **Svelte State Hydration**: Refactored `PianoRoll.svelte` to listen for the `project_load` event via `LiveBridge`. Svelte now successfully parses the backend project payload, derives the active track/segment, and renders the backend notes on the canvas.
- **Bi-directional Editing Skeleton**: Implemented `handle_event` callbacks in `EquinoxWeb.EditorLive` (`add_note`, `update_note`, `delete_note`) ready to be wired up to `Equinox.Editor` state mutations.
- **Editor Actions Skeleton**: Built `Equinox.Editor` module. Implemented `add_note/4`, `update_note/5`, and `delete_note/4` as pure functional transformations over the nested `Equinox.Project` structure.
