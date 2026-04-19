# AGENTS.md

## 1. Project Overview & Tech Stack

**Equinox** is a vocal synthesis editor (DAW-like) split into a standalone kernel and a UI shell.

- **Backend**: Phoenix 1.8, LiveView 1.1, Bandit, Orchid ecosystem (DAG orchestration).
- **Frontend**: Svelte 5 (Runes mode strictly), SvelteFlow, Tailwind CSS v4, TypeScript, Vite.
- **Banned Tech**: Kino, Livebook, LiteGraph, Svelte 4 syntax.

## 2. Environment & Agent Constraints (CRITICAL)

- **OS/Shell**: Windows host, but Agent uses `mvdan/sh` (bash emulator).
- **Paths**: ALWAYS use forward slashes (`/`).
- **Commands**: Unix text utilities (`grep`, `awk`, `tail` via pipes) are missing. Rely on native Agent tools (`Glob`, `Grep`, `View`) instead of bash pipes for text search/manipulation.
- **Search Before Act**: Do not rely on hardcoded directory trees. Use `ls`/`glob` to find components and files.

## 3. Frontend ↔ Backend Bridge

The ONLY coupling between Svelte and Phoenix is the `EquinoxBridge` interface injected via `createSvelteHook`.

- **Rule**: Svelte components receive `bridge` as a prop. NEVER import from `phoenix_live_view` or access `window.liveSocket` in Svelte.
- **Event Routing**: LiveComponents use `phx-target={@myself}`. Svelte 5 uses local `$state` for optimistic UI and `$effect` + `setTimeout` for debouncing network requests, instead of backend debouncing.

## 4. Core Domain & Architecture Rules

- **Pure Data**: `Project`, `Track`, and `Segment` are pure data structures (JSON serializable). No Ecto schemas, no executable closures inside them.
- **Timing Model**: Use **Ticks / Beats** (musical time) for storage. Conversions to acoustic frames or audio samples happen in the Elixir Kernel, never in Svelte.
- **Slicer Model**: Keep slicing as pure data derived from note boundaries. Add `slice_flag` to `Equinox.Domain.Note` with shape `{:on_start, slice_id} | :on_end | nil`. Automatic defaults come from rest-gap detection, but users may override them manually. Slice suggestions stay pure; applying them to `Track`/`Segment` is a separate editor/session responsibility.
- **UI Layout Hierarchy**:
  - `EditorLive` (Main Shell) -> Top-level dispatcher.
  - `TrackList` -> Vertical stack for mute/solo.
  - `PianoRoll` / `Arranger` -> SvelteFlow canvases (hybrid rendering with SVG/Canvas overlays).
  - `Synthesizer Node Editor` -> DiffSinger pipeline topology editor.

## 5. Coding Conventions

- **Elixir**: Return `{:ok, value} | {:error, reason}`(except some Context-like structs, it prefer `t() -> t() | {:error, reason}`). API names start with verbs (`create_`, `update_`).
- **Svelte 5**: Runes ONLY (`$state`, `$derived`, `$props`, `$effect`).
- **Tailwind v4**: `!` modifier goes at the END (e.g., `bg-amber-500!`). Gradients use `bg-linear-to-b`.
- **SvelteFlow**: NEVER use reserved node types like `input`/`output`. Use custom names (e.g., `custom_input`).

## 6. Essential Commands

- Kernel (`cd kernel`): `mix deps.get`, `mix test`
- UI Shell (`cd ui_shell`): `mix deps.get`, `iex -S mix phx.server`
- Frontend (`cd ui_shell/assets`): `npm run dev`, `npm run build`, `npm run check`
- Pre-commit: `cd kernel && mix precommit`, `cd ui_shell && mix precommit`


## Current Milestones & Focus

1. ~~**M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~
5. **M4 — Slicer semantics & segment application**: Finalize `Note.slice_flag` model, automatic rest-gap slicing, user overrides, and the editor/session flow that materializes slices into `Segment` updates.
6. **M5 — Arranger**: Second SvelteFlow canvas, multi-track mix, slice/segment alignment, and slice-aware editing affordances.
7. **M6 — Curves**: SVG bezier layer + rasterization in the Compiler.
8. **M7 — History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.
9. **M8 — Plugin System**: Runtime dynamic loading of custom Synth Nodes.
   - Frontend: Implement WebComponent wrapping for SvelteFlow to load arbitrary third-party UI `.js` securely via dynamic `<script type="module">`.
   - Backend: Distributed Erlang Architecture. Spawn isolated BEAM OS processes (`Engine Node`) per Session to execute Orchid graphs. Safely hot-load `.beam` modules at runtime without risking the main Phoenix `Web Node` stability.

## Next Session Starting Point

- Decide the exact automatic slicing invariants for `Note.slice_flag`, especially how `{:on_start, slice_id}`, `{:mono, slide_id}`(temporary when a slice has only one note) and `:on_end` are repaired during split/merge/tail-append edits.
- Decide whether `slice_id` is a stable logical grouping id only, or whether/how it maps onto persisted `Segment.id` during materialization.
