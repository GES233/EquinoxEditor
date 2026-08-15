# AGENTS.md

## 1. Project Overview & Tech Stack

**Equinox** is a vocal synthesis editor (DAW-like) split into a standalone kernel and a UI shell.

- **Backend**: Phoenix 1.8, LiveView 1.1, Bandit, Orchid ecosystem (DAG orchestration).
- **Frontend**: Svelte 5 (Runes mode strictly), SvelteFlow (`@xyflow/svelte`), Tailwind CSS v4, TypeScript, Vite, Vitest.
- **Banned Tech**: Kino, Livebook, LiteGraph, Svelte 4 syntax.

### Repository Layout

This is **not** a mix umbrella: the root `mix.exs` is a bare placeholder (`:equinox_repo`, no deps). The real projects are three sibling Elixir projects wired by path dependencies:

- `domain/` — `:equinox_domain` (Elixir ~> 1.18)
- `kernel/` — `:equinox_kernel` (Elixir ~> 1.15, OTP app `Equinox.Application`)
- `ui_shell/` — `:equinox_ui_shell` (Phoenix app; Svelte frontend in `ui_shell/assets/`)

Two further path dependencies live **outside this repo**, expected as siblings of the checkout: `../coconut` (`github:GES233/Coconut`) and `../tamale` (local path override). Build commands below fail without them.

### Layered Architecture

Development follows a strict bottom-up dependency order:

```text
┌─────────────────────────────────┐
│  ui_shell (Svelte + LiveView)   │  ← The presentation layer is the final implementation.
├─────────────────────────────────┤
│  Equinox.Session.*              │  ← Session/Storage Layer
├─────────────────────────────────┤
│  Equinox.Kernel.*               │  ← Compiler/Orchid Integration(Scheduling/Graph Engine/etc.)
├─────────────────────────────────┤
│  EquinoxDomain.*                │  ← Equinox-specific domain layer (thin, over coconut)
├─────────────────────────────────┤
│  Coconut.* (path dependency)    │  ← Engine-agnostic editor core: Score types / Edit
│    └─ Tamale.* (path dep)       │    (Workspace/Track/Operations/History) / Render / Pickle
│                                 │    Tamale = rebase kernel: Space / Op / Anchor / Transport / Patch
└─────────────────────────────────┘
```

- **Coconut** is the bottom-layer editor core (separate repo, consumed as a path dependency, remote `github:GES233/Coconut`): base score/curve/util types (`Coconut.Score.*`, `Coconut.Curve.*`, `Coconut.Util.*`), the editing aggregate (`Coconut.Edit.Workspace` / `Track` / `Operations.*` / `History` / `Command` / `Diff` / `Patch`), the render contracts (`Coconut.Render.Channel` / `Resolve` / `Engine`), and serialization (`Coconut.Pickle.*`). Its only runtime dependency is tamale.
- **Tamale** is the rebase kernel (zero dependencies): versioned identity spaces (`Tamale.Space`), the six edit ops (`Tamale.Op.*`), structural anchors (`Tamale.Anchor.{Ordinal, Metric, Relative}`), transport (`Tamale.Transport` + `Tamale.Warp` over exact rational `Tamale.Coord`), and semantic survival (`Tamale.Patch` + canonical `Tamale.Digest`). Both coconut and equinox consume it via a local path override.
- **Domain** sits directly on coconut/tamale: equinox-specific pure data structures and stateless domain logic only. Its only allowed dependencies are coconut + tamale — never Kernel, Session, or UI.
- **Kernel** consumes Domain types for compilation, planning, and graph construction. Never imports UI or Session.
- **Session / UI Shell** sit at the outermost layer, consuming both Domain and Kernel.

> Historical note: the bottom layer was **zongzi** (Timeline / Anchor / Windowing / Intervention) until 2026-08. The migration to coconut+tamale is recorded in `docs/coconut-migration.md`; the tamale caller guide (`tamale/docs/zh/guide/caller-guide-zh.md` §8) contains the authoritative zongzi→tamale mapping table.

### EquinoxDomain — Independent Domain Project

The `EquinoxDomain` module lives in `domain/` as a **separate Elixir project** (`:equinox_domain`) whose only dependencies are `{:coconut, path: "../../coconut"}` and `{:tamale, path: "../../tamale", override: true}`. After the coconut migration it is a **thin equinox-specific layer** — coconut already absorbed the generic domain model (tracks, notes, operations, history, pickle).

**Project location**: `domain/` (root-level, sibling to `kernel/` and `ui_shell/`)

**Module map** (`domain/lib/equinox_domain/`):
- `Score.Project` — `{id, workspace :: Coconut.Edit.Workspace.t(), tracks_meta :: %{track_id => TrackMeta.t()}, metadata}`. Pure query/meta aggregate: `new/1` (explicit `:id`), `add_track/2` → `{:ok, project, track}`, `remove_track/2`, `fetch_track/2`, `track_meta/2`, `put_track_meta/3`, `tempo_map/1`, `time_sig_map/1`, `view/2`, `dump/1` / `load/1` (composes `Coconut.Pickle.Workspace` + `Coconut.Pickle.Track.default_registry()` + own TrackMeta codec). **No note/tempo/patch writes here** — writes belong to the kernel's History path.
- `Score.TrackMeta` — equinox-only per-track side table: `{mix_automation, gain, pan, mute, solo, voicebank_id, globals, presets, active_preset, ui_state, metadata}`. Lives outside coconut History (not undoable). Own dump/load. `voicebank_id` selects the track's EngineAdapter from the session `engines` registry (per-track granularity). `globals` holds per-track engine knob values (engine-defined keys; validated at Runner check against the adapter's declared rules, never at write time).
- `Score.Track` — **stateless query facade** over Project/workspace: `notes(project, track_id)` → `{:ok, [{id, Coconut.Score.Note.t(), {start_tick, end_tick}}]}`, `note/3`, `slice/3`.
- `Windowing` + `Windowing.Window` — equinox-owned phrase windowing (coconut deliberately defers segmentation). `Window{start_tick, end_tick, note_ids}` (half-open). Ports the zongzi `RestSplit3Beats` rules + `slice_flag` overrides; see "Windowing Semantics" below.
- `Score.SliceFlag` — `:auto | :force_slice | :force_merge` over `Coconut.Score.Note.metadata`.
- `Score.Phoneme` — pure identity VO (`symbol`, `type`). Timing lives in the engine projection layer; user timing edits are `:phoneme_timing` patches.
- `Segment` — Caller-side rendering-context VO (acoustic boundaries + `phonemes`/`curves`, populated by the Kernel at compile time, not serialized). Distinct from `Windowing.Window`.
- `Port` / `Command` — namespace marker modules (documentation only; responsibilities described in their moduledocs).
- `Port.Channel` — data-channel identifier type (`atom()`), aligned with `Coconut.Edit.Patch.channel`.
- `Port.Preset` — registry `channels :: %{channel_atom => Coconut.Render.Channel module}` + artifact/allow_adopt lists with cross-validation; own dump/load.
- `Port.Channels.PhonemeTiming` — the first concrete `Coconut.Render.Channel` (`:phoneme_timing`): `projection/2` (canonical, float-free note+span base), `target/0` → `{:port, :synth, :phoneme_timing}`.
- `Command.RenderRequest` — per-window compile request `{track_id, note_ids, notes (with spans), time_range, tempo_segments, patches, channels}`; `from_window(project, window, tempo_map)` filters structurally-survived patches by anchor ∩ window (Ordinal/Relative by refs, Metric by tick-range intersection).
- `Command.AdoptRequest` — `build_patch(workspace, channel_module, %{track_id, anchor, payload})` → `{:ok, Coconut.Edit.Patch.t()}` (pure; the kernel mounts it via History).

**Key design decisions**:
- Base types come from coconut: `Coconut.Score.{Note, Tick, Tempo, TempoMap, TimeSig, TimeSigMap, Record, RecordMap, Grid}`, `Coconut.Score.Key.*`, `Coconut.Curve.*`, `Coconut.Util.*`. EquinoxDomain does not redefine them.
- **`Coconut.Score.Note` has no timing fields** — `{id, key, lyric, annotation, metadata}`; timing lives in the track's spans table and surfaces through `Coconut.Edit.Track.view/1` as `[{id, note, {start_tick, end_tick}}]`. Anything that needs note timing must carry the span alongside.
- **Tempo is a track**: `workspace.globals["global:tempo"]` holds a `Coconut.Edit.Track.Tempo` with `%{bpm: milli_bpm}` elements (`Coconut.Score.Tempo.cast_bpm/1` rationalizes floats to milli-bpm). Time signatures are **not** a track — `Workspace.time_sigs` (bar-anchored), set via `Command.set_time_sigs`. Compiled maps (`Workspace.tempo_map/1`, `time_sig_map/1`) carry their own tpqn.
- Interventions are `Coconut.Edit.Patch` (tamale `Anchor` + `Tamale.Patch{base_digest, payload}` + channel), stored in `Coconut.Edit.Track.patches`. Anchors are constructed **explicitly** (Ordinal for element identity, Ordinal+`adjacent?` for boundaries, Metric for tick ranges, Relative for element+offset) — no triplet scrubbing.
- Two-stage death verdict (tamale doctrine): structural survival is judged at edit time by workspace write-time transport (dead patches go to per-track graveyards, drained via `History.take_dead_patches/1` — surfaced, never silently pruned); semantic survival is judged at render check time by `Tamale.Patch.resolve/2` (digest zero tolerance).
- There is no `Zongzi.Util.Model`/`Util.Object` macro in coconut — structs hand-roll `new/1` + `update/2` via `Coconut.Util.Helpers`. IDs via `Coconut.Util.ID.generate_id/1`.
- **Tamale float discipline**: anything entering the tamale kernel (Metric endpoints, Relative offsets, Retime spans, warps, digest inputs) must be exact rationals/canonical terms — floats are rejected. Normalization (µs ints, frame numbers, decimal strings) happens in the adapter layer before digesting.

**Build/Test**: `cd domain && mix test` | **Pre-commit**: `cd domain && mix precommit`

## 2. Environment & Agent Constraints (CRITICAL)

- **OS/Shell**: Windows host, but Agent uses `mvdan/sh` (bash emulator).
- **Paths**: ALWAYS use forward slashes (`/`).
- **Commands**: Unix text utilities (`grep`, `awk`, `tail` via pipes) are missing. Rely on native Agent tools (`Glob`, `Grep`, `View`) instead of bash pipes for text search/manipulation.
- **Search Before Act**: Do not rely on hardcoded directory trees. Use `ls`/`glob` to find components and files.
- **Plan Before Code**: Before modifying or creating files, briefly output your plan or structural changes. Do not rush into writing large blocks of code without confirming the target file paths via `ls`/`glob`.
- **Strict Phase Compliance**: Do not attempt to refactor Kernel or UI Shell (Phase 2 & 3) while Phase 1 is still ongoing. Ignore legacy code smells in `kernel/` until Phase 1 (Domain MVP) is 100% complete.

## 3. Frontend ↔ Backend Bridge

The ONLY coupling between Svelte and Phoenix is the `EquinoxBridge` interface injected via `createSvelteHook`.

- **Rule**: Svelte components receive `bridge` as a prop. NEVER import from `phoenix_live_view` or access `window.liveSocket` in Svelte.
- **Event Routing**: LiveComponents use `phx-target={@myself}`. Svelte 5 uses local `$state` for optimistic UI and `$effect` + `setTimeout` for debouncing network requests, instead of backend debouncing.
- **Svelte 5 State**: Extract complex client-side state models into `.svelte.ts` files using exported functions or classes wrapping `$state`. Keep `.svelte` UI components focused on rendering and Bridge message dispatching.
- **Frontend layout** (`ui_shell/assets/`): `js/app.js` (LiveSocket entry), `src/lib/bridge/` (bridge impls), `src/lib/components/` (`PianoRoll.svelte`, `Arranger.svelte`, `NodeEditor.svelte` + subfolders), `src/lib/stores/` (`viewport.svelte.ts`, `node_registry.ts`), `src/lib/editor_context.ts`.

## 4. Core Domain & Architecture Rules

> In this document, "Editor" refers to the entire Equinox application.

- **Domain-First Development**: `EquinoxDomain.*` (in `domain/`) is the cornerstone of the project — now as a thin layer over coconut. Equinox-specific domain models must be completed and thoroughly tested at this layer before Kernel or UI Shell work. The Domain project's only allowed dependencies are coconut + tamale; it is prohibited from depending on Kernel or UI modules.💡
- **Pure Data**: `Project`, `TrackMeta`, `Coconut.Score.Note`, `Phoneme` are pure data structures (Pickle-serializable). `Segment` is also of type Domain, but its `phonemes` and `curves` fields are cached at runtime and do not participate in serialization. No Ecto schemas, no executable closures inside them.
- **Timing Model**: Use **Ticks / Beats** (musical time) for storage. Conversions to acoustic frames or audio samples happen in the Elixir Kernel, never in Svelte. Note timing lives in workspace spans, not on the Note struct — carry spans alongside notes.
- **Headless-capable Kernel**: Kernel business logic (`Equinox.Kernel.*`) stays pure-functional; Domain types come from `EquinoxDomain.*`. The Kernel MAY hold session state as a headless editor — `Equinox.Session.Server`/`Context` own the per-session project, `Coconut.Edit.History` (the only write entry), synth graphs, compile cache, and render tasks behind named editing APIs. `Equinox.Kernel.StepRegistry` remains a build-time catalog (not session state).💡
- **History is the only write entry**: all score/tempo/patch writes go through `Coconut.Edit.History` (`Operations.*` via `History.apply/4`, structural commands via `History.run/3` + `Coconut.Edit.Command`). After each write, `Session.Context.sync_workspace/1` re-attaches `History.current(hist).workspace` onto the query-side `Project`; the `tracks_meta` side table survives on the Project and is updated directly (not undoable). Drag edits are `[Move, Retime]` in one batch (enforced by `Coconut.Edit.Operations.DragNote`) — never hand-edit spans without a Retime op.💡
- **Windowing Model**: Windowing is an equinox-owned, pure one-way projection `notes+spans → [Windowing.Window]` (`EquinoxDomain.Windowing`, invoked via `Score.Track.slice/3`). Windows are transient and recomputed from scratch after edits — there is no slice-repair step. `slice_flag` in `Note.metadata` is an *input signal* for windowing, not a post-hoc synchronization channel.💡
- **Interventions belong to coconut tracks, anchored structurally**: continuous parameter data (pitch, energy, breathiness, …), phoneme-timing edits, and adopted engine output are `Coconut.Edit.Patch`es in `Coconut.Edit.Track.patches` — explicit tamale anchors + `base_digest`/`payload` + `Tamale.Patch.resolve` semantics. They are never keyed by tick-window ids. At dispatch time, `RenderRequest.from_window/3` filters structurally-survived patches by anchor ∩ window; semantic resolution happens at engine check time.💡
- **UI Layout Hierarchy**:
  - `EditorLive` (Main Shell) -> Top-level dispatcher.
  - `TrackList` -> Vertical stack for mute/solo.
  - `PianoRoll` / `Arranger` -> SvelteFlow canvases (hybrid rendering with SVG/Canvas overlays).
  - `Synthesizer Node Editor` -> DiffSinger pipeline topology editor.

## 5. Coding Conventions

- **Elixir**: Return `{:ok, value} | {:error, reason}` (except some Context-like structs, which prefer `t() -> t() | {:error, reason}`). API names start with verbs (`create_`, `update_`).
  - **Elixir Error Handling**: The `EquinoxDomain` layer must NEVER `raise` exceptions. Use pattern matching, `case`, and `with` to return `{:error, reason}`. Avoid `!` functions (e.g., use `Map.fetch` instead of `Map.fetch!`) unless validating purely internal logic where a crash is genuinely expected. For other scenes, `!` is acceptable.
- **Svelte 5**: Runes ONLY (`$state`, `$derived`, `$props`, `$effect`).
- **Tailwind v4**: `!` modifier goes at the END (e.g., `bg-amber-500!`). Gradients use `bg-linear-to-b`.
- **SvelteFlow**: NEVER use reserved node types like `input`/`output`. Use custom names (e.g., `custom_input`).
- **Formatting**: root `.formatter.exs` covers `{domain,kernel,ui_shell}/{config,lib,test}`; each subproject also has its own `.formatter.exs`. Run `mix format` per subproject (part of `precommit`).
- **Language**: AGENTS.md is pure English. Source code, comments, and documentation use Chinese. Project audience: AI assistants and Chinese-speaking developers.

## 6. Essential Commands

- Domain (`cd domain`): `mix test`, `mix precommit` (= `compile --warnings-as-errors` + `format` + `test`)
- Kernel (`cd kernel`): `mix deps.get`, `mix test`, `mix precommit` (additionally runs `deps.unlock --unused`)
- UI Shell (`cd ui_shell`): `mix setup` (= `deps.get` + assets `npm install`), `iex -S mix phx.server`, `mix precommit`; `mix assets.build` / `mix assets.deploy` for frontend builds via Vite
- Frontend (`cd ui_shell/assets`): `npm run dev` (Vite watch build), `npm run build`, `npm run check` (`svelte-check && tsc --noEmit`), `npm run test:run` (Vitest, single run)
- Commit Messages: Follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`).
  - Commit messages should be in English, but the internal code/documentation comments remain in Chinese until user's request.

## 7. Architecture Decision Records 💡

The domain / intervention / rebase decisions that used to live in zongzi now live in the **coconut** and **tamale** repos:

- coconut: `../coconut/docs/` — `design-2026-07-editor-core.md` (the constitution: Workspace/Track/Element model, six ops, warp provider, step-only structural tempo, undo/redo via op tree + checkpoints), `design-2026-08-orchid-intervention.md` (render backend hookup, payload taxonomy, exactness spec), `design-2026-08-tempo-curve.md` (step-for-bones / curve-for-skin / bake-for-boundary).
- tamale: `../tamale/docs/` — `zh/guide/caller-guide-zh.md` (Caller orchestration contract + self-check list), `spec/canonical-digest.md` (portable digest spec), `decisions/0001..0007` (edit-intent ops, identity conventions, warp-based Metric transport, clip/relative semantics, digest-as-adjudicator, chunked digests, exact rational coords).

Equinox-side design docs in `docs/`: `coconut-migration.md` (migration record + mapping tables), `channel-development.md` (channel developer guide), `engine-adapter-design.md` (Engine Adapter boundary decision), `editor-mental-model.md`, `phase2-kernel-handoff.md`, `windows.md`. Note: `ui-interaction-model.md` is self-marked **outdated** post-migration — treat it as intent-level only.

| coconut/tamale concern | Equinox concern |
|---|---|
| tamale `Transport` + write-time transport | Dead patches → per-track graveyard; `History.take_dead_patches/1` surfaces them |
| tamale `Patch.resolve/2` zero tolerance | Kernel check phase: one-vote veto `{:error, {:check_failed, entries}}` |
| tamale exact rational `Coord` | No floats in anchors/spans/digests; normalize in adapters |
| coconut `Operations.DragNote` | `[Move, Retime]` same-batch discipline |
| coconut `Render.Channel` behaviour | Equinox channel impls (`Port.Channels.PhonemeTiming`) + `Preset` registry |
| coconut `Render.Engine`/`Resolve`/`Encoder` stack (dormant — zero equinox callers, whole-workspace granularity) | Kernel owns the engine interface: `EngineAdapter` behaviour; Configurator derives channel specs from it (see `docs/engine-adapter-design.md`) |
| coconut `Edit.Diff` | UI whole-window note replacement (`replace_window_notes`) |
| coconut workspace write-time transport | No equinox-side rebase orchestration anymore |

### Equinox-only (not in coconut/tamale)

These remain product / shell / Orchid concerns; they are **not** upstreamed:

- **Windowing ownership** — `EquinoxDomain.Windowing` (RestSplit3Beats port + `slice_flag` overrides). Coconut explicitly defers phrase segmentation; if coconut lands it upstream, re-evaluate.
- **slice_flag semantics** — Caller-side windowing override (`Note.metadata` + `Score.SliceFlag` + `Windowing` fixup passes).
- **TrackMeta side table** — mix/preset/ui_state per track, outside History (not undoable).
- **synth_graph Session-side storage** — graph/cluster are Kernel compile-time concepts; they live in `Session.Context.graphs` (`%{track_id => Graph.t()}`).
- **channel spec (projection/target) contract** — channel→port binding and projection supply are Host-side configuration, injected into the Runner check phase. Single source: an `Equinox.Kernel.EngineAdapter` implementation packages channel specs + `timing_spec` + globals + adoptables; `Configurator` derives `channels` from the Adapter instead of hand-injected specs (`docs/engine-adapter-design.md`).
- **Headless-editor placement** — session state (coconut History, synth graphs, compile cache, blackboard, render tasks) is kernel-owned (`Session.Server/Context`); coconut stays a pure edit core with no processes, no sessions, no orchestration.
- **History persistence** — short term: History is session-scoped and not pickled (save/load round-trips only the present workspace; the undo tree restarts via `History.new/1`). Long term: `Pickle.Command` + `Pickle.History` on the coconut roadmap (`Pickle.Op` already exists); no equinox-side boundary change when it lands.
- **Per-window render dispatch** — unit id `{track_id, window.start_tick}`; coconut's own render granularity is whole-workspace Snapshot, equinox keeps per-window `RenderRequest`s.
- **Domain–Kernel–Session–UI layering** (`EquinoxDomain` vs Kernel import bans)
- **Compiler / Orchid Hook** wiring (`param_name → port`)
- **Raster NIF placement** in Kernel (Domain keeps pure reference)
- **UI History surfacing** (op-tree undo/redo wiring into LiveView), Douglas-Peucker before History, LiveView bridge
- **Phrase cache implementation** (e.g. Stratum)

### Historical note

The zongzi decision files (`zongzi/docs/zh/spec/decisions/*`) are superseded by the coconut/tamale docs above. The 2026-08 migration record is `docs/coconut-migration.md` (target architecture, module map, mapping tables). Prefer coconut/tamale docs as the source of truth for kernel-level rules.

When implementing Equinox Host glue:

```text
edit → Operations.*/Command → History.apply/run (op batch; drag = Move+Retime)
  → workspace write-time transport (dead patches → graveyard, drained + surfaced)
  → Score.Track.slice (EquinoxDomain.Windowing) → [Windowing.Window]
  → RenderRequest.from_window (patches filtered by anchor ∩ window)
  → Runner check (Tamale.Patch.resolve per patch) → (user resolution) → render (Oi.execute)
```

Do not re-introduce persistent window/segment-as-identity in Domain.

## 8. Do Not Do 💡

### Domain Red Lines (permanent)

- Do not let `EquinoxDomain.*` modules import, alias, or use anything from `Equinox.Kernel.*`, `Equinox.Session.*`, or `Equinox.Editor.*`. Domain's only allowed dependencies are coconut + tamale.
- Do not add `graph`, `cluster`, or `synth_override` fields to Domain structs. These are Kernel compile-time concepts.
- Do not persist `EquinoxDomain.Windowing.Window`, and do not re-introduce slice-repair passes. Windowing is an explicit one-way projection via `Score.Track.slice/3`; windows are recomputed from scratch after edits.
- Do not store user/engine interventions as tick-anchored chunks — use `Coconut.Edit.Patch` (tamale Anchor + `Tamale.Patch`) with explicit anchors.
- Do not write notes/tempo/patches through `Workspace.*` directly outside kernel tests — `Coconut.Edit.History` is the only write entry; time-changing edits must carry `Retime` in the same op batch (tamale hard rule).
- Do not feed raw floats into tamale-facing structures (anchors, spans, digest bases). Normalize first (milli-bpm ints, µs ints, frame numbers, decimal strings).
- Do not feed raw per-frame drawing samples into Editor or History. Simplify to control points first via Douglas-Peucker (ADR-003).

### Kernel Guidelines

The Kernel layer exists as a thin wrapper over Domain + runtime state management. It introduces no new business logic.

- GenServer usage in Kernel is limited to runtime state management only. No business logic in processes.
- Curve parameter semantics do not leak into Kernel. Never hardcode `:pitch`, `:energy`, or any specific param name (Hook territory, ADR-004).

## 9. Testing Guidelines

- **Domain (Elixir)**: Focus on pure unit tests (`ExUnit`, one test file per module under `domain/test/equinox_domain/`). Avoid mocking in the `domain/` project since everything is pure data/functions. Use table-driven tests (or `Enum.each`) for matrix logic like `Windowing` edge cases. Test fixtures write notes through `Coconut.Edit.History` + `Operations.*` (see `EquinoxDomain.TestFactory`) — do not re-test coconut/tamale internals.
- **Kernel (Elixir)**: Test stateful boundaries (e.g., GenServers) and integration with Domain types. Test support files compile from `kernel/test/support` in the `:test` env; kernel coverage ignores `*Step*` modules.
- **UI Shell (Elixir)**: LiveView/presenter tests under `ui_shell/test/` (`lazy_html` available in test).
- **Frontend (Svelte/TS)**: Vitest is wired in `ui_shell/assets` (`npm run test`, `npm run test:run`, `npm run test:ui`; jsdom + `@testing-library/svelte` + `setupTest.ts`). Full UI testing is deferred to Phase 3; for pure TS logic (e.g., math, formatting), use standard unit tests (see `src/basic.test.ts`).

## Current Milestones & Focus

Current priority: **Phase 1a → 1b → 1c → 1d (Domain MVP) → Phase 2 (Domain-Kernel integration) → Phase 3 (UI Shell)**.

```
Phase 1a ─── Standalone Domain Models (domain/)  [superseded: base types now from coconut]
Phase 1b ─── Aggregate Roots (domain/)           [superseded: coconut Workspace/Track]
Phase 1c ─── Windowing & Interventions (domain/) [windowing equinox-owned; patches via coconut]
Phase 1d ─── Polish & Serialization (domain/)    [Coconut.Pickle; History landed early]
Phase 2 ──── Domain-Kernel Integration (kernel/)
Phase 3 ──── UI Shell (ui_shell/)
```

### Completed

> The following M0–M3 are early milestones that have been completed. Subsequent planning will uniformly use the Phase system.

1. ~~**M0 — Skeleton**: Repo scaffolded (domain/kernel/ui_shell path-dep projects), Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~
5. ~~**Zongzi Migration (domain)**: `:zongzi` path dependency; Caller trio Track; `SlicePolicy`; interventions; `RenderRequest`/`AdoptRequest`.~~ (superseded by the coconut migration)
6. ~~**Coconut Migration (2026-08, branch `zongzi-to-coconut`)**: all three subprojects moved from zongzi to coconut+tamale (see `docs/coconut-migration.md`). Domain slimmed to equinox-specific concerns (`Score.Project` workspace wrapper + `TrackMeta` side table, stateless `Score.Track` facade, equinox-owned `Windowing` + `SliceFlag`, `Port.Preset`/`Port.Channels.PhonemeTiming`, per-window `RenderRequest`, `AdoptRequest.build_patch/3`; `EquinoxDomain.Pickle.*` deleted in favor of `Coconut.Pickle.*`). Kernel `Session.Context` holds `Coconut.Edit.History` as the only write entry (undo/redo foundation landed early — the op tree + checkpoints are in place; UI surfacing remains Phase 3); note edits flow through `Operations.*`/`Command` (`replace_window_notes` via `Coconut.Edit.Diff`); Runner check phase resolves patches via `Tamale.Patch.resolve/2`. Audio track type mapping (`:external_audio` → `Coconut.Edit.Track.Audio`) wired through `add_track`. ui_shell presenter reads workspace views; frontend JSON contract (`NoteData`/`SegmentData`) unchanged.

**Completed sector list:**
- Base types (from coconut): `Tick`, `TempoMap`, `Tempo.Step/Linear`, `TimeSigMap`, `RecordMap`, `Grid`, `Key.TwelveET`, `Curve.Chunk/ControlPoint/Adapters`
- Editing aggregate (from coconut): `Edit.Workspace`, `Edit.Track.{Vocal, Tempo, Audio}`, `Edit.Operations.*`, `Edit.History`, `Edit.Command`, `Edit.Diff`, `Edit.Patch`
- Rebase kernel (from tamale): `Space`, `Op.*`, `Anchor.{Ordinal, Metric, Relative}`, `Transport`, `Warp`, `Patch`, `Digest`, `Coord`
- Serialization (from coconut): `Pickle.*` + `Pickle.File` envelope (registry-driven)
- Equinox domain: `Score.Project` (+ `TrackMeta`), `Score.Track` facade, `Windowing` + `Window`, `Score.SliceFlag`, `Phoneme`, `Segment` (rendering-context VO), `Port.Preset`, `Port.Channels.PhonemeTiming`, `Command.RenderRequest`, `Command.AdoptRequest`
- Deferred: curves rasterization/simplification, curve channel (see Curves section)

### Phase 2 — Domain-Kernel Integration (kernel/)

17. **Domain dependency** — done; deepened by the coconut migration (kernel and ui_shell consume `EquinoxDomain.*` + coconut/tamale directly; zongzi fully removed).
18. **Slicer → Windowing** — done: `Score.Track.slice/3` (equinox-owned `EquinoxDomain.Windowing`) → `[Windowing.Window]` drives dispatch (unit id `{track_id, window.start_tick}`; the UI's "segment" is a presenter-side simulation over windows). Metric-anchored patches widen windows via `extra_spans`.
19. **Track API** — done: domain Project/TrackMeta + coconut Operations are wired through `Session.Server` named editing APIs (`add_track` / `remove_track` / `update_track_mix` / `update_track_ui_state` / `replace_window_notes` / `update_synth_graph` / `adopt_intervention`); synth graphs live in `Session.Context.graphs`.
20. **RenderRequest + AdoptRequest** — main wiring done: `prepare_dispatch/1` builds one `RenderRequest` per window via `from_window/3`; `Runner.run/3` is two-phase (check-all → render-all), resolving patches per channel via `Tamale.Patch.resolve/2` against the Configurator `channels` contract (`projection` arity-2 + `target`, PortRef-keyed); check failures aggregate as `{:error, {:check_failed, entries}}`; `Server.adopt_intervention/3` wraps `AdoptRequest.build_patch/3` + `Command.attach_patches`. Channel developer guide: `docs/channel-development.md`. Deferred to the second cut: curve channel, frame-grid `timing_spec`, rasterization.
21. **Editor / Session adaptation**: done — Session manages selection, clipboard, viewport, the coconut History, and the query-side Project. Only `Coconut.Render.Engine` remains as the engine contract naming (the legacy `Equinox.Kernel.Engine` runner was deleted in the oi migration).

**Engine Adapter (2026-08-15 boundary decision; first cut landed)**: the headless-editor role is kernel-owned; coconut's `Render.Engine`/`Resolve`/`Encoder` stack is dormant (marked, not deleted, not adopted). `Equinox.Kernel.EngineAdapter` behaviour is defined with five callbacks (`channels` / `engine_key` / `timing_spec` / `globals` / `adoptables`); `Configurator.new(engine: {adapter, config})` derives channel specs from it (single source, derived wins over hand-injected `:channels`). Per-track granularity: `Session.Context.engines` (a `%{voicebank_id => {adapter, config}}` registry injected via `Server` start opts) + `TrackMeta.voicebank_id` (set via `Server.update_track_voicebank/3`) resolve each track's adapter in `prepare_dispatch`, which hangs derived channel specs on `dispatch.track_channels`; `Runner` looks up specs per unit (fallback `Configurator.channels`). Engine version stamps enter digest bases via `Channel.stamp_base/2` + `AdoptRequest`'s `:engine` option (mount side) and adapter spec projections (check side) — `Server.adopt_intervention/3` stamps automatically. **Globals gate (decided 2026-08-15)**: knob values live in `TrackMeta.globals` (`Server.update_track_globals/3`, key-merge with nil-deletes, not undoable); `prepare_dispatch` hangs values on `dispatch.track_globals` and per-track rules (derived from `adapter.globals/1`) on `track_global_rules` (fallback `Configurator.global_rules`; nil = no declaration = no gate); the Runner check phase validates them with one-vote aggregation, entries `%{kind: :global, track_id, key, reason}` joining the same `check_failed` list as patch conflicts. **Capabilities gating (decided 2026-08-15)**: kernel-owned, adapter-declared — check side stays `:unknown_channel`; adopt side, `Server.adopt_intervention/3` checks the channel atom (module `channel/0`) against the track adapter's `adoptables/1` and fails loud with `{:error, {:not_adoptable, channel}}` (ungated when the track has no adapter). A stub adapter E2E (edit → adopt → check → render, version-upgrade conflict storm, globals gate, capabilities gating) is green in `kernel/test/equinox/engine_adapter_test.exs`. Open details (artifact shape, voicebank descriptor VO): `docs/engine-adapter-design.md`.

### Phase 3 — UI Shell (ui_shell/)
22. **Arranger**: Second SvelteFlow canvas, multi-track mix, slice/utterance alignment, slice-aware editing affordances. Audio tracks: creation + presenter round-trip work; clip insertion needs a declared workspace `frame_rate` and frame-domain UI (not yet wired).
23. **History & Collaboration hooks**: Session-level undo/redo — the substrate (`Coconut.Edit.History` op tree, `undo/1` / `redo/1`, version pins) landed with the coconut migration; what remains is LiveView surfacing (undo/redo events, conflict UI for dead patches — currently only logged); design space for future CRDT.
24. **Plugin System**: Runtime dynamic loading of custom Synth Nodes.
    - Frontend: WebComponent wrapping for SvelteFlow, third-party UI `.js` via dynamic `<script type="module">`.
    - Backend: Distributed Erlang — isolated BEAM `Engine Node` per Session for Orchid graph execution, hot-load `.beam` modules without risking the Phoenix `Web Node`.

## Windowing Semantics

Windowing is **equinox-owned** (`EquinoxDomain.Windowing`); coconut deliberately defers phrase segmentation.

### Windowing Scenarios

- **Continuous Notes Import**: MIDI/ustx import produces dense note sequences. Default behavior (ported from zongzi `RestSplit3Beats`): cuts on rest gaps ≥ 3 beats (1 beat joins the previous window, 2 beats join the next; longer gaps leave a dead zone). `beat_ticks` = `opts[:beat_ticks] || opts[:tpqn] || 480`.
- **Manual Override**: `slice_flag` in `Note.metadata` (via `Score.SliceFlag`) overrides derivation at the boundary **before** the flagged note: `:force_slice` always cuts, `:force_merge` never cuts.
- **Intervention spans widen windows**: tick-ranged (Metric-anchored) patches contribute `extra_spans` that merge into content before cutting — the zongzi "scope widens the window" semantic. The kernel derives `extra_spans` at dispatch time.
- **Edits**: there is no repair step. Flags are stable note metadata; windows are recomputed from scratch by `Score.Track.slice/3` after every edit. Intervention survival across edits is a separate concern handled by coconut's write-time transport (dead patches → graveyard), not by windowing.
- **Window Semantics**: `EquinoxDomain.Windowing.Window` is a transient projection `{start_tick, end_tick, note_ids}` (half-open) — never persisted, never an intervention anchor. User patches live in `Coconut.Edit.Track.patches`, orthogonal to windows. 💡

### `slice_flag` Design

`EquinoxDomain.Score.SliceFlag`:

```elixir
@type t :: :auto | :force_slice | :force_merge
```

Stored as `note.metadata["slice_flag"]` (`"force_slice"` / `"force_merge"`; `:auto` = key absent). The flag governs the boundary **immediately before** the note:

- `:auto`: default; the base RestSplit3Beats rule decides via rest-gap detection.
- `:force_slice`: force a boundary before this note, even with no rest gap.
- `:force_merge`: suppress the boundary before this note, even across a rest gap ≥ threshold.

Each boundary is governed by exactly one note's flag (the note after the boundary), so overrides never conflict with each other. Degenerate cuts (zero-length halves, e.g. chord notes sharing a start tick) are skipped.

### Note Editing (coconut Operations)

Note edits are **gesture requests** lowered to tamale op batches, executed through `Coconut.Edit.History.apply/4` (kernel Session owns this):

- `Operations.InsertNote{track_id, note_id, after_id, span, attrs}` → `[Insert]`
- `Operations.DeleteNote{track_id, note_id}` → `[Delete]`
- `Operations.DragNote{...}` → `[Move, Retime]` in one batch (tamale hard rule)
- `Operations.SplitNote{..., at_tick, new_id}` → `[Split]` — the first child inherits the parent id
- `Operations.MergeNotes{..., note_ids}` → `[Merge]` — adjacency enforced, `into == hd(ids)`
- `Operations.EditNote{..., changes}` → **no ops** — pure content edits (lyric etc.) only rewrite the side table
- `Operations.TrimNote` / `MoveNote` / `DragNoteAcrossTracks` — see coconut sources
- `Edit.Diff.diff/2` — reverse-engineers an op batch from before/after `[{span, attrs}]` (UI whole-window replacement; exact span+content matches keep ids, everything else is visible Delete+Insert)
- `Command.{add_track, remove_track, rename_track, set_time_sigs, attach_patches, consume_dead}` — structural commands via `History.run/3`

Note `Coconut.Edit.Track.Vocal` rejects same-track overlap at gesture validation (half-open spans; abutting is legal). `Coconut.Score.Note` itself only carries content (`key`, `lyric`, `annotation`, `metadata`); timing is always the span.

### Querying (domain facade)

- `Score.Track.notes(project, track_id)` → `{:ok, [{id, Note.t(), {start_tick, end_tick}}]}` (view order: `{start, id}`)
- `Score.Track.note(project, track_id, note_id)`
- `Score.Track.slice(project, track_id, opts)` → `{:ok, [Windowing.Window.t()]}` — one-way windowing projection
- `Score.Project.tempo_map/1` / `time_sig_map/1` — compiled maps on demand

### Data Flow

1. [explicit] Edits enter as `Operations.*`/`Command` through `History` (kernel Session); op batch is atomic, `edit_version` +1.
2. [auto] Workspace write-time transport marches surviving patches; dead ones land in the per-track graveyard and are drained + surfaced (`History.take_dead_patches/1`).
3. [auto] `Score.Track.slice/3` produces transient `Windowing.Window`s.
4. [auto] `RenderRequest.from_window/3` builds the compile request: notes with spans, tempo slice, structurally-survived patches filtered by anchor ∩ window, and the channel registry map.
5. [engine check] The Runner resolves each patch against a fresh projection (`Tamale.Patch.resolve/2`, digest zero tolerance): apply payloads or raise a semantic conflict (one-vote veto).
6. [explicit] Adopting engine output builds + mounts a new patch (`AdoptRequest.build_patch/3` + `Command.attach_patches`).

## Curves

Split into Phase 1 (domain) and Phase 2 (kernel integration). Status after the coconut migration: `Coconut.Curve.*` exists but is **parked at the adapter layer** (float-world, excluded from digests, not yet wired to any channel) — same deferred state as before.

### Goals

1. Continuous parameter curves become first-class, **patch-based** data anchored on notes (not tick ranges).
2. `EquinoxDomain.Windowing.Window` is the transient windowing output; `EquinoxDomain.Segment` is a pure rendering-context VO.
3. Compiler/Runner becomes the sole translator from resolved curve patches → `data_intervention`.
4. Kernel stays semantics-agnostic about individual curve parameters; consumption is Orchid Hook territory.

### Data Structures

- `Coconut.Curve.Chunk`: `{id, adapter, container, start_tick, rasterized | nil, extra}` (adapter/container pattern; `end_tick` is computed via the adapter, not stored). Control points carry `(tick, value, handle_left, handle_right)`.
- `Coconut.Edit.Patch` (curve channels): `{anchor, patch :: Tamale.Patch{base_digest, payload}, channel}` — curve payloads are control-point chunks; the base digest covers the canonical projected values. Anchors: Metric for tick ranges (transported by warps), Ordinal/Relative for note-anchored data.
- RasterCache (deferred): `{stride, samples :: binary, fingerprint}`. Rebuildable from control points; never serialized.
- `EquinoxDomain.Command.RenderRequest`: `{track_id, note_ids, notes, time_range, tempo_segments, patches, channels}`. The only struct passed into the dispatch. Constructed via `from_window/3`.

### Curve Facade API (Phase 2/3 Editor concern)

- A completed stroke becomes a curve patch, mounted via `AdoptRequest.build_patch/3` + `Command.attach_patches` through History. Facade helpers (`apply_curve_stroke`, `erase_curve_range`, `clear_curve_layer`) are Editor-level conveniences built on patch attach/remove.
- Strokes are assumed already-simplified control-point chunks (see ADR-003). The Editor does **not** accept raw sample arrays.
- A curve `Coconut.Render.Channel` (projection + target for continuous data, with canonical digest normalization) is still to be defined — `Port.Channels.PhonemeTiming` is the reference implementation.

### Compiler Integration

1. Caller builds one `RenderRequest` per window via `RenderRequest.from_window/3` (patches filtered by anchor ∩ window).
2. At check time, the Runner resolves patches per channel (`Tamale.Patch.resolve/2` against the channel spec's fresh projection) and dispatches resolved data to `data_interventions`, keyed by `PortRef`. The `PortRef → Orchid key` translation reuses existing `Graph.PortRef.to_orchid_key/1`.
3. Payload shape given to the Hook:
   ```text
   %{param: atom(), start_tick: non_neg_integer(), end_tick: non_neg_integer(),
     stride: pos_integer(), samples: binary()}
   ```
4. No `param_name` is privileged inside Kernel code.

### Phase 1 — Domain

- [x] Curve types come from coconut (`Coconut.Curve.Chunk`, `ControlPoint`, `Adapter.Bezier/CatmullRom`).
- [ ] Curve channel (`Coconut.Render.Channel` impl for continuous data) — pending; reference implementation: `Port.Channels.PhonemeTiming`.
- [ ] Add `RasterCache` + rasterizer — **deferred**: plugs into the resolve-at-check flow.
- [ ] Add stroke-simplification helper (Douglas-Peucker) — **deferred**: same as above.
- [x] ~~`Track.data_channels` / `LayerChunk`~~ — abolished; `Coconut.Edit.Patch` instead.
- [ ] Implement serialization for curve types — **deferred**: pending curve model stabilization (coconut-side).

Each step ends on a green `cd domain && mix precommit`.

### Phase 2 — Kernel Integration

- [x] `EquinoxDomain.Command.RenderRequest` rewritten (patches + channels; `from_window/3`).
- [x] `EquinoxDomain.Command.AdoptRequest` rewritten (`build_patch/3`).
- [x] Legacy `%Segment{}` slimmed to the rendering-context VO (`EquinoxDomain.Segment`).
- [x] Legacy JSON chain removed — `Coconut.Pickle` codecs replace it (domain `Project.dump/load` composes `Coconut.Pickle.Workspace` + TrackMeta codec).
- [x] `Session.Context.prepare_dispatch/1` builds `RenderRequest` per window via `RenderRequest.from_window/3`.
- [x] Runner check phase resolves patches via `Tamale.Patch.resolve/2` (Configurator `channels` contract).
- [ ] Define curve channel(s) and emit curve `data_interventions` (resolve at check time).
- [ ] Thread curve operations through Session-level undo/redo (Phase 3; the `Coconut.Edit.History` substrate is in place).

Each step ends on a green `cd kernel && mix precommit`.

### Orchid Hook Contract

Third-party Hooks integrate via `Equinox.Kernel.Configurator.plugins`. Example configuration (illustrative):

```elixir
Configurator.new(
  plugins: [
    {OrchidCurveHook,
     %{
       pitch:       %{target_node: :vocoder,        target_port: :f0_override},
       energy:      %{target_node: :acoustic_model, target_port: :energy_bias},
       breathiness: %{target_node: :vocoder,        target_port: :breathiness}
     }}
  ]
)
```

Kernel does not ship a reference Hook. Curves integration delivers the contract and payload shape; the first concrete Hook lives outside Kernel (userland or a sibling package).

## 10. Known Issues (kernel scope)

Ordered roughly by priority; do not fix opportunistically without a matching commit plan.

1. `StepRegistry` startup ordering: `Supervisor.start_link` then `register_builtin_steps` — works but not clean.
2. Dead patches are currently only logged (`Logger.warning` after edit batches) — Phase 3 must surface them to the UI as user-visible conflicts (tamale discipline: uncertainty flows to conflict, never to silence).
3. Audio tracks: creation/presenter round-trip works; clip insertion needs a declared workspace `frame_rate` + frame-domain UI; rendering skips frame-domain tracks by design for now.

Facts after the coconut migration (2026-08):

- The kernel legacy JSON chain is gone — `Coconut.Pickle` codecs replace it (domain `Project.dump/load` composes `Coconut.Pickle.Workspace` with the default registry + the TrackMeta codec; registry includes vocal/tempo/audio element codecs). `Kernel.Graph.*` keeps its `@derive Jason.Encoder` (SvelteFlow graph persistence is used by ui_shell), and the `:jason` dependency stays.
- `Equinox.PubSub` naming belongs to ui_shell (configured in `ui_shell/config/config.exs`); kernel has no PubSub code path.
- Note ids are reminted by `Coconut.Edit.Diff` on whole-window replacement (exact span+content matches keep their ids); the frontend receives fresh ids via the `project_load` re-push — this is deliberate (visible death over optimistic survival).
