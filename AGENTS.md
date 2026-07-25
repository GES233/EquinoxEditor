# AGENTS.md

## 1. Project Overview & Tech Stack

**Equinox** is a vocal synthesis editor (DAW-like) split into a standalone kernel and a UI shell.

- **Backend**: Phoenix 1.8, LiveView 1.1, Bandit, Orchid ecosystem (DAG orchestration).
- **Frontend**: Svelte 5 (Runes mode strictly), SvelteFlow, Tailwind CSS v4, TypeScript, Vite.
- **Banned Tech**: Kino, Livebook, LiteGraph, Svelte 4 syntax.

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
│  EquinoxDomain.*                │  ← Pure data + domain logic, highest priority
├─────────────────────────────────┤
│  Zongzi.* (path dependency)     │  ← SVS kernel: Timeline / Anchor / Windowing / Intervention
└─────────────────────────────────┘
```

- **Zongzi** is the bottom-layer SVS kernel library (separate repo, consumed as a path dependency): note-sequence truth (`Timeline`), structural anchors (`Anchor`), transient windowing (`Windowing`), user-edit intent (`Intervention` + `Declaration`), engine contract (`Engine`), and the base score/curve/util types. It has zero dependencies itself.
- **Domain** sits directly on zongzi: pure data structures and stateless domain logic. Its only allowed dependency is zongzi — never Kernel, Session, or UI.
- **Kernel** consumes Domain types for compilation, planning, and graph construction. Never imports UI or Session.
- **Session / UI Shell** sit at the outermost layer, consuming both Domain and Kernel.

### EquinoxDomain — Independent Domain Project

The `EquinoxDomain` module lives in `domain/` as a **separate Elixir project** (`:equinox_domain`) whose only dependency is `{:zongzi, path: "../../zongzi"}`. It is the canonical home for all domain types and pure business logic. The legacy kernel domain types (`kernel/lib/equinox/domain/`, `Equinox.Track`, `Equinox.Project`) were deleted in the Phase 2 mid-stage migration — kernel and ui_shell consume `EquinoxDomain.*` + zongzi types directly.

**Project location**: `domain/` (root-level, sibling to `kernel/` and `ui_shell/`)

**Key design decisions**:
- Base types come from zongzi: `Zongzi.Score.{Note, Tick, Tempo, TempoMap, TimeSig, TimeSigMap, Record, RecordMap, Grid}`, `Zongzi.Score.Key.*`, `Zongzi.Curve.*`, `Zongzi.Util.*`. EquinoxDomain does not redefine them.
- `use Zongzi.Util.Model, keys: [...], id_prefix: "Xxx_"` auto-generates `new/1`, `update/2`, `validate/1`. `new/1` requires an explicit `:id` (no auto-generation) — callers generate IDs via `Zongzi.Util.ID.generate_id/1`. `update/2` returns `{:ok, model} | {:error, reason}`.
- `Track` holds the zongzi Caller trio — `timeline` (`Zongzi.Timeline.t()`), `notes_by_seq` (`%{SeqID.t() => Zongzi.Score.Note.t()}`), `interventions` (`[Zongzi.Intervention.t()]`) — plus mix/preset/metadata fields. Note CRUD follows the zongzi Caller sync contract (see zongzi `docs/zh/guide/CallerDesigning-zh.md`).
- `slice_flag` (`:auto | :force_slice | :force_merge`) lives in `Note.metadata` (via `EquinoxDomain.Score.SliceFlag`), not in the zongzi Note struct. Windowing runs as a `Zongzi.Windowing.Strategy` pipeline: `EquinoxDomain.Score.SlicePolicy` applies flag overrides on top of `Zongzi.Windowing.RestSplit3Beats`.
- User curve/timing edits are `Zongzi.Intervention`s (structural anchor + snapshot + per-channel `Declaration` lifecycle), stored in `Track.interventions`. The tick-anchored `LayerChunk`/`data_channels` model is abolished. First concrete channel: `EquinoxDomain.Port.Declarations.PhonemeTiming`.
- `Phoneme` is a standalone value object with identity fields (`symbol`, `type`). Timing lives in the engine projection layer; user timing edits are `:phoneme_timing` interventions (see zongzi `intervention-semantics.md`).
- Two different `Segment` concepts coexist: `Zongzi.Windowing.Segment` (transient windowing projection `{start_tick, end_tick, seq_ids}` — the zongzi engine contract consumes this one) and `EquinoxDomain.Segment` (Caller-side rendering-context VO with acoustic boundaries and `phonemes`/`curves`, populated by the Kernel at compile time, not serialized). Keep them distinct.

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

## 4. Core Domain & Architecture Rules

> In this document, "Editor" refers to the entire Equinox application.

- **Domain-First Development**: `EquinoxDomain.*` (in `domain/`) is the cornerstone of the project. All domain models (data structures + pure functional logic) must be completed and thoroughly tested at this layer before development of the Kernel or UI Shell can begin. The Domain project's only allowed dependency is zongzi; it is prohibited from depending on Kernel or UI modules.💡
- **Pure Data**: `Project`, `Track`, `Zongzi.Score.Note`, `Phoneme` are pure data structures (JSON/Pickle serializable). `Segment` is also of type Domain, but its `phonemes` and `curves` fields are cached at runtime and do not participate in serialization. No Ecto schemas, no executable closures inside them.
- **Timing Model**: Use **Ticks / Beats** (musical time) for storage. Conversions to acoustic frames or audio samples happen in the Elixir Kernel, never in Svelte.
- **Headless-capable Kernel**: Kernel business logic (`Equinox.Kernel.*`) stays pure-functional; Domain types come from `EquinoxDomain.*`. Per the 2026-07-25 decision, the Kernel MAY hold session state as a headless editor — `Equinox.Session.Server`/`Context` own the per-session project, synth graphs, compile cache, and render tasks behind named editing APIs. `Equinox.Kernel.StepRegistry` remains a build-time catalog (not session state). `Equinox.Editor.*` was deleted in the Phase 2 mid-stage migration; its operations were absorbed into `Session.Server` + domain Track/Project APIs. 💡
- **Windowing Model**: Windowing is a pure one-way projection `Notes → [Zongzi.Windowing.Segment]` executed by `Zongzi.Windowing` strategies (`Track.slice/2`, pipeline `[EquinoxDomain.Score.SlicePolicy]`). Segments are transient and recomputed from scratch after edits — there is no slice-repair step. `slice_flag` in `Note.metadata` is an *input signal* for the strategy, not a post-hoc synchronization channel. 💡
- **Interventions belong to Track, anchored structurally**: Continuous parameter data (pitch, energy, breathiness, …), phoneme-timing edits, and adopted engine output are stored as `Zongzi.Intervention`s in `Track.interventions` — anchored on SeqID triplets (default `Anchor.NoteTriplet`) with snapshot / `Declaration.resolve` semantics. They are never keyed by tick ranges or window ids. At request time, `RenderRequest.from_window/3` filters survived interventions by `Declaration.scope` ∩ window; semantic resolution happens later at engine check time. 💡
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
- **Language**: AGENTS.md is pure English. Source code, comments, and documentation use Chinese. Project audience: AI assistants and Chinese-speaking developers.

## 6. Essential Commands

- Domain (`cd domain`): `mix test`, `mix precommit`
- Kernel (`cd kernel`): `mix deps.get`, `mix test`, `mix precommit`
- UI Shell (`cd ui_shell`): `mix deps.get`, `iex -S mix phx.server`, `mix precommit`
- Frontend (`cd ui_shell/assets`): `npm run dev`, `npm run build`, `npm run check`
- Commit Messages: Follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `chore:`).   
  - Commit messages should be in English, but the internal code/documentation comments remain in Chinese until user's request.

## 7. Architecture Decision Records 💡

Domain / sequence / intervention / windowing decisions that belong to the **zongzi** kernel live **in the zongzi repo** (no numeric ADR ids):

`../zongzi/docs/zh/spec/decisions/` (or your checkout of [SynapticStrings/Zongzi](https://github.com/SynapticStrings/Zongzi) → `docs/zh/spec/decisions/`).

Index: `decisions/README.md`.

| zongzi decision file | Equinox concern |
|---|---|
| `transient-render-closure.md` | Interventions not keyed by window id |
| `windowing-post-rebase.md` | post-rebase `Strategy.window/1`; Engine check/render (`[Segment]`) |
| `control-points-authoritative.md` | Curve points vs raster cache |
| `key-behaviour-and-protocol.md` | Key dual dispatch |
| `declaration-projection-resolution.md` | Declaration lifecycle |
| `intervention-semantics.md` | What is / is not an intervention |
| `anchor-operate-orthogonality.md` | Structural rebase ⊥ semantic resolve |
| `payload-boundary.md` | `Declaration.on_rebase/4` payload boundary maintenance |
| `boundary-ownership-open.md` | Pad pierce / phrase hash — **Host/Kernel choice** |

> `slicer-is-projection.md` was **deleted upstream** (zongzi removed `Slicer`/`slice_flag` in favor of Windowing strategies). Equinox keeps its `slice_flag` semantics as Caller-side strategy input stored in `Note.metadata` — do not reference the deleted file.

### Equinox-only (not in zongzi)

These remain product / shell / Orchid concerns; they are **not** duplicated into zongzi:

- **slice_flag semantics** — Caller-side windowing override (`Note.metadata` + `Score.SliceFlag` + `Score.SlicePolicy`); deliberately not upstreamed, since zongzi removed the field.
- **Track as zongzi Caller** — timeline/notes_by_seq/interventions trio, sync contract, `rebase_interventions/1` orchestration.
- **synth_graph Session-side storage** — graph/cluster are Kernel compile-time concepts; during the Phase 2 interim they live in `Session.Context.graphs` (`%{track_id => Graph.t()}`) and move into `RenderRequest` with item 20.
- **channel spec (projection/target) contract** — channel→port binding and projection supply are Host-side configuration (`Configurator.channels`), injected into the Runner check phase; they never enter zongzi.
- **Domain–Kernel–Session–UI layering** (`EquinoxDomain` vs Kernel import bans)
- **RenderRequest / Compiler / Orchid Hook** wiring (`param_name → port`)
- **Raster NIF placement** in Kernel (Domain keeps pure reference)
- **UI History**, Douglas-Peucker before History, LiveView bridge
- **Phrase cache implementation** (e.g. Stratum) — constrained by zongzi `boundary-ownership-open`, implemented here

### Historical note

Former numbered ADR-001…014 text that described pure domain rules was **migrated** into zongzi `docs/zh/spec/decisions/*` and de-Equinox'd (no `EquinoxDomain` / Track / Compiler requirements in the kernel docs). Prefer the zongzi files as source of truth for those rules.

When implementing Equinox Host glue:

```text
edit → Track (Timeline + notes_by_seq sync) → Track.rebase_interventions (Anchor.rebase_all)
  → Track.slice (Windowing.Strategy) → [Zongzi.Windowing.Segment]
  → Engine.check(%{segments: ...}) → (user resolution) → Engine.render(%{segments: ...})
```

Do not re-introduce persistent Utterance/Segment-as-identity in Domain.

## 8. Do Not Do 💡

### Domain Red Lines (permanent)

- Do not let `EquinoxDomain.*` modules import, alias, or use anything from `Equinox.Kernel.*`, `Equinox.Session.*`, or `Equinox.Editor.*`. Domain's only allowed dependency is `:zongzi`.
- Do not add `graph`, `cluster`, or `synth_override` fields to Domain structs. These are Kernel compile-time concepts; they belong in `RenderRequest` (ADR-006).
- Do not persist `Zongzi.Windowing.Segment`, and do not re-introduce a `Slicer` module or slice-repair passes. Windowing is an explicit one-way projection via `Track.slice/2`; segments are recomputed from scratch after edits.
- Do not store user/engine interventions as tick-anchored chunks — the `LayerChunk`/`data_channels` model is abolished, and `EquinoxDomain.Rebase.*` must not be revived. Use `Zongzi.Intervention` + `Declaration` with `Anchor` rebase.
- Do not feed raw per-frame drawing samples into Editor or History. Simplify to control points first via Douglas-Peucker (ADR-003).

### Kernel Guidelines

The Kernel layer exists as a thin wrapper over Domain + runtime state management. It introduces no new business logic.

- GenServer usage in Kernel is limited to runtime state management only. No business logic in processes.
- Curve parameter semantics do not leak into Kernel. Never hardcode `:pitch`, `:energy`, or any specific param name (Hook territory, ADR-004).

## 9. Testing Guidelines

- **Domain (Elixir)**: Focus on pure unit tests (`ExUnit`). Avoid mocking in the `domain/` project since everything is pure data/functions. Use table-driven tests (or `Enum.each`) for matrix logic like `SlicePolicy` windowing edge cases.
- **Kernel (Elixir)**: Test stateful boundaries (e.g., GenServers) and integration with Domain types.
- **Frontend (Svelte)**: UI testing is deferred to Phase 3. For pure TS logic (e.g., math, formatting), use standard unit tests.

## Current Milestones & Focus

Current priority: **Phase 1a → 1b → 1c → 1d (Domain MVP) → Phase 2 (Domain-Kernel integration) → Phase 3 (UI Shell)**.

```
Phase 1a ─── Standalone Domain Models (domain/)
  Key.TwelveET, Note (pitch/duration/timing) — now provided by zongzi.
  Deferred: Curves rasterization/simplification, Tempo.Curve (Kernel NIF verification).

Phase 1b ─── Aggregate Roots (domain/)
  Track (zongzi Caller trio + CRUD), Project, Phoneme linkage.

Phase 1c ─── Windowing & Interventions (domain/)
  slice_flag in Note.metadata, SlicePolicy (Windowing strategy),
  Track interventions (mount/rebase), PhonemeTiming declaration.

Phase 1d ─── Polish & Serialization (domain/)
  Editing commands, Session, Pickle + comprehensive tests.

Phase 2 ──── Domain-Kernel Integration (kernel/)
  Replace legacy Domain types with the new domain project.
  Adapt Editor / Session / Compiler to Windowing + RenderRequest + Intervention.
  Curve channel Declaration + resolve-at-check pipeline.

Phase 3 ──── UI Shell Polish (ui_shell/)
  Arranger, History, Plugin System.
```

### Completed

> The following M0–M3 are early milestones that have been completed. Subsequent planning will uniformly use the Phase system.

1. ~~**M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~
5. ~~**Zongzi Migration (domain)**: `:zongzi` path dependency added; duplicated base types (`Timeline.*`, `Key.*`, `Curve.*`, `Util.*`, `Helpers`) deleted in favor of zongzi; `Track` rebuilt on `Zongzi.Timeline` + `notes_by_seq` + `interventions` with the Caller sync contract; `Slicer` replaced by `Score.SlicePolicy` (`slice_flag` in `Note.metadata`); `Rebase.*` / `LayerChunk` / `Port.Declaration` replaced by zongzi Intervention/Declaration (`Port.Declarations.PhonemeTiming` first channel); `RenderRequest` carries survived interventions; `AdoptRequest` mounts interventions.~~

**Completed sector list:**
- Base types (from zongzi): `Tick`, `TempoMap`, `Tempo.Step/Linear`, `TimeSigMap`, `RecordMap`, `Grid`, `Key.TwelveET`, `Curve.Chunk/ControlPoint/Adapters`
- Utilities (from zongzi): `Util.Model`, `Util.Object`, `Util.ID`, `Helpers`
- Score: `Track` (zongzi Caller trio + CRUD + `slice/2`), `Project` (skeletal), `Phoneme`
- Windowing: `Score.SliceFlag`, `Score.SlicePolicy`
- Interventions: `Track.interventions` + `mount_intervention/5` + `rebase_interventions/1`; `Port.Declarations.PhonemeTiming`
- Commands: `Command.RenderRequest` (interventions projection), `Command.AdoptRequest` (mount flow)
- VO: `Segment` (rendering context)
- Deferred: curves rasterization/simplification, Pickle serialization (see Phase 1d)

### Phase 1a — Standalone Domain Models (domain/)
5. **Note (standalone)** — Done, via `Zongzi.Score.Note` (explicit-id `new/1`, pure `split/4` / `merge/4`).
6. **Timeline** — Done, via `Zongzi.Score.{Tempo*, TimeSig*, Record*}` (`TimeSigMap.compile/1`, `Tempo.Linear`). `Tempo.Curve` deferred — reserved as a Kernel NIF integration verification point.
7. **Curves (pure data)** — Done, via `Zongzi.Curve.*`. RasterCache, rasterizer, Douglas-Peucker simplification: **deferred** (see Curves section).

### Phase 1b — Aggregate Roots (domain/)
8. **Track** — Done: zongzi Caller trio (`timeline`, `notes_by_seq`, `interventions`) + mix/preset fields. Note CRUD (`insert_note`, `delete_note`, `split_note`, `merge_notes`, `update_note`, `apply_slice_flag`) follows the zongzi Caller sync contract. The old ADR-012/013 anchor-semantics questions are superseded by zongzi Anchor/Declaration.
9. **Project** — Tracks map + project-level metadata. Track CRUD. **Blocked on Track completion** → unblocked, still skeletal.
10. **Phoneme** — Pure identity VO (`symbol`, `type`); timing lives in the engine projection. User timing edits are `:phoneme_timing` interventions (`Port.Declarations.PhonemeTiming`).

### Phase 1c — Windowing & Interventions (domain/)
11. **Windowing** — Done: `slice_flag` in `Note.metadata`; `Score.SlicePolicy` (`:force_slice` / `:force_merge` overrides on `RestSplit3Beats`). `Notes → [Zongzi.Windowing.Segment]` projection; no materialization step. Slice repair rules abolished — flags are stable note metadata, windows recomputed from scratch.
12. **Interventions** — Done: `Track.interventions` + `mount_intervention/5` + `rebase_interventions/1`; first channel `Port.Declarations.PhonemeTiming`. A curve (continuous-data) channel Declaration is still pending.
13. **Segment** — Rendering context VO: acoustic boundaries, `phonemes`/`curves`. The Domain defines the struct; fields are populated by the Kernel at compile time and do not participate in serialization.

### Phase 1d — Polish & Serialization (domain/)
14. **Editing commands** — `Command.Editing` (DragNote, ResizeNote, EditLyric, SplitNote, MergeNotes, AddTrack, DeleteTrack) + command stack for undo/redo. Orchestrates Track ops + `rebase_interventions/1`. **Blocked on Track + Project CRUD** → Track done; Project CRUD pending.
15. **Session / RenderRequest** — `Command.RenderRequest` rewritten (carries survived interventions + declarations). `Session` still a placeholder; the zongzi Caller state (per-track trio) now lives on `Track`, so Session mainly holds selection, clipboard, viewport.
16. **Pickle (native-object codec)** — Done: per-type `dump/1` / `load/1` producing plain maps/lists/numbers/binaries/atoms/nil (tuples→lists, structs flattened). `EquinoxDomain.Pickle.*` covers zongzi-owned structs (Note/Key/Timeline/Intervention/tempo & time-sig events); Track/Project/Preset carry their own. The old three-layer `Util.Pickle` is deleted. Channel Declarations must keep payload/snapshot dump-safe. Jason remains a trivial future transform, not implemented.

### Phase 2 — Domain-Kernel Integration (kernel/)

> Handoff from the 2026-07-25 session (approved kernel cleanup plan + verified ui_shell↔kernel coupling findings): `docs/phase2-kernel-handoff.md`.

17. **Domain dependency** — done (Phase 2 mid-stage): legacy `Equinox.{Track, Project, Editor, Domain.*, Util.{Id, Attrs}}` deleted; kernel and ui_shell consume `EquinoxDomain.*` + zongzi directly (`:zongzi` path dep added to both).
18. **Slicer → Windowing** — done: the legacy `materialize_segments` path is gone; `Track.slice/2` → `[Zongzi.Windowing.Segment]` drives dispatch (unit id `{track_id, window.start_tick}`; the UI's "segment" is a presenter-side simulation over windows).
19. **Track API** — done: domain Track CRUD + `rebase_interventions/1` are wired through `Session.Server` named editing APIs (`add_track` / `remove_track` / `update_track_mix` / `update_track_ui_state` / `replace_window_notes` / `update_synth_graph`); synth graphs live in `Session.Context.graphs` until item 20 moves them into `RenderRequest`.
20. **RenderRequest + AdoptRequest** — main wiring done: `prepare_dispatch/1` builds one `RenderRequest` per window via `from_window/3` (slice passes `tempo_map` + `interventions` so scopes widen windows); `Runner.run/3` is two-phase (check-all → render-all), resolving interventions per channel via `Declaration.resolve_within/2` and binding resolved artifacts to `data_interventions` through the Configurator `channels` contract (`projection` + `target`, PortRef-keyed); check failures aggregate as `{:error, {:check_failed, entries}}`; `Server.adopt_intervention/4` wraps `AdoptRequest.adopt/3`. Channel developer guide: `docs/channel-development.md`. Deferred to the second cut: curve channel Declaration, frame-grid `timing_spec`, rasterization.
21. **Editor / Session adaptation**: Editor ops → Track API. Session manages selection, clipboard, viewport, and per-track Caller state. Note the naming clash: `Equinox.Kernel.Engine` (Orchid runner) vs `Zongzi.Engine` (check/render contract) — **resolved**: the runner was deleted in the oi migration (absorbed by `Oi.execute/2` via `Equinox.Kernel.Runner`); only `Zongzi.Engine` remains.

### Phase 3 — UI Shell (ui_shell/)
22. **Arranger**: Second SvelteFlow canvas, multi-track mix, slice/utterance alignment, slice-aware editing affordances.
23. **History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.
24. **Plugin System**: Runtime dynamic loading of custom Synth Nodes.
    - Frontend: WebComponent wrapping for SvelteFlow, third-party UI `.js` via dynamic `<script type="module">`.
    - Backend: Distributed Erlang — isolated BEAM `Engine Node` per Session for Orchid graph execution, hot-load `.beam` modules without risking the Phoenix `Web Node`.

## Windowing Semantics

### Windowing Scenarios

- **Continuous Notes Import**: MIDI/ustx import produces dense note sequences. Default behavior: `Zongzi.Windowing.RestSplit3Beats` cuts on rest gaps ≥ 3 beats (1 beat joins the previous segment, 2 beats join the next; longer gaps leave a dead zone).
- **Manual Override**: `slice_flag` in `Note.metadata` (via `Score.SliceFlag`) overrides derivation at the boundary **before** the flagged note: `:force_slice` always cuts, `:force_merge` never cuts.
- **Edits**: there is no repair step. Flags are stable note metadata; windows are recomputed from scratch by `Track.slice/2` after every edit. Intervention survival across edits is a separate concern handled by `Anchor.rebase_all` (via `Track.rebase_interventions/1`), not by windowing.
- **Segment Semantics**: `Zongzi.Windowing.Segment` is a transient projection — never persisted, never an intervention anchor. User interventions live in `Track.interventions`, orthogonal to windows. 💡

### `slice_flag` Design

`EquinoxDomain.Score.SliceFlag`:

```elixir
@type t :: :auto | :force_slice | :force_merge
```

Stored as `note.metadata["slice_flag"]` (`"force_slice"` / `"force_merge"`; `:auto` = key absent). The flag governs the boundary **immediately before** the note:

- `:auto`: default; `RestSplit3Beats` decides via rest-gap detection.
- `:force_slice`: force a boundary before this note, even with no rest gap.
- `:force_merge`: suppress the boundary before this note, even across a rest gap ≥ threshold.

Each boundary is governed by exactly one note's flag (the note after the boundary), so overrides never conflict with each other.

`Score.SlicePolicy` implements `Zongzi.Windowing.Strategy`: it delegates to `RestSplit3Beats.window/1`, then applies force-merge joins and force-slice splits on `current_segments`. Degenerate cuts (zero-length halves, e.g. chord notes sharing a start tick) are skipped.

### Note Editing Functions (`Zongzi.Score.Note`)

Note-local transforms (pure; IDs injected by the caller):

- `new/1(attrs)` — create a note (`:id` required)
- `update/2(note, attrs)` — update note fields
- `drag_note/2`, `drag_duration/2`, `update_lyric/2`, `update_annotation/2`, metadata helpers
- `split/4(note, split_tick, new_id, attrs)` — split at a tick position
- `merge/4(note1, note2, merged_id, opts)` — merge two overlapping notes

### Track Editing Functions (`EquinoxDomain.Score.Track`)

Track owns the zongzi Caller trio (`timeline`, `notes_by_seq`, `interventions`) and follows the zongzi Caller sync contract:

- `insert_note(track, attrs)` → `{:ok, track, note}` — positioned by `start_tick`; seq auto-assigned
- `delete_note(track, seq_id)` → `{:ok, track}`
- `split_note(track, seq_id, split_tick, attrs \\ [])` → `{:ok, track, before, after}` — before keeps its seq, after gets a new seq
- `merge_notes(track, seq_a, seq_b)` → `{:ok, track, merged}` — merged at seq_a; seq_b becomes a merge tombstone
- `update_note(track, seq_id, attrs)` → `{:ok, track}` — re-links via `move_note` when `start_tick` crosses neighbors (seq preserved)
- `apply_slice_flag(track, seq_id, flag)` → `{:ok, track}` — manual override
- `slice(track, opts \\ [])` → `{:ok, [Zongzi.Windowing.Segment.t()]}` — one-way windowing projection
- `note(track, seq_id)`, `active_notes(track)` — queries

Note operations do NOT auto-rebase interventions. After an edit batch, the Caller runs:

- `rebase_interventions(track)` → `{:ok, track, %{conflicts, decisions}}` — wraps `Anchor.rebase_all`; prunes dead interventions, surfaces conflicts for the UI
- `mount_intervention(track, int, payload, seq_id, projection)` → `{:ok, track, mounted}` — derives a `NoteTriplet` anchor and stores the declaration snapshot

### Data Flow

1. [auto] Track edits update `timeline` + `notes_by_seq` per the sync contract.
2. [explicit] Caller runs `Track.rebase_interventions/1` after the edit batch; structural conflicts (dead anchors) surface to the user.
3. [auto] `Track.slice/2` produces transient `Zongzi.Windowing.Segment`s via `SlicePolicy`.
4. [auto] `RenderRequest.from_window/3` builds the compile request: notes by seq, tempo slice, survived interventions filtered by `Declaration.scope` ∩ window, and the channel → declaration-module map.
5. [engine check] The Compiler/engine resolves each intervention against a fresh projection (`Declaration.resolve/2`): apply deltas or raise a semantic conflict.
6. [explicit] Adopting engine output mounts a new intervention (`AdoptRequest.adopt/3`) — it never writes tick-anchored chunks.

## Curves

Split into Phase 1 (domain) and Phase 2 (kernel integration).

### Goals

1. Continuous parameter curves become first-class, **intervention-based** data anchored on notes (not tick ranges).
2. `Zongzi.Windowing.Segment` is the transient windowing output (`start_tick`, `end_tick`, `seq_ids`); `EquinoxDomain.Segment` is a pure rendering-context VO.
3. Compiler becomes the sole translator from resolved curve interventions → `data_intervention`.
4. Kernel stays semantics-agnostic about individual curve parameters; consumption is Orchid Hook territory.

### Data Structures

- `Zongzi.Curve.Chunk`: `{id, adapter, container, start_tick, rasterized | nil, extra}` (adapter/container pattern; `end_tick` is computed via the adapter, not stored). Control points carry `(tick, value, handle_left, handle_right)`.
- `Zongzi.Intervention` (curve channels): `{channel, anchor, payload, snapshot, declaration}` — curve payloads are control-point chunks plus a maintained boundary; snapshots hold the original projected values. Replaces the abolished `EquinoxDomain.LayerChunk`.
- RasterCache (deferred): `{stride, samples :: binary, fingerprint}`. Rebuildable from control points; never serialized.
- `EquinoxDomain.Command.RenderRequest`: `{track_id, note_ids, notes, time_range, tempo_segments, interventions, declarations}`. The only struct passed into `Compiler.compile/1`. Constructed via `from_window/3`.

### Segment Shrinkage

After curves integration, `%EquinoxDomain.Segment{}` retains only rendering-context fields: `track_id, start_tick, end_tick, core_start_sec, core_end_sec, context_start_sec, context_end_sec, phonemes, curves` (the `phonemes` and `curves` fields are populated by the Kernel at compile time and are not serialized).

Removed from Kernel's legacy Segment: `curves`, `synth_override`, `graph`, `cluster`. These move to `RenderRequest` (compile-time) or `Track.interventions`.

### Curve Facade API (Phase 2 Editor concern)

- A completed stroke becomes a curve intervention, mounted via `Track.mount_intervention/5` with the channel's declaration. Facade helpers (`apply_curve_stroke`, `erase_curve_range`, `clear_curve_layer`) are Editor-level conveniences built on intervention mount/remove.
- Strokes are assumed already-simplified control-point chunks (see ADR-003). The Editor does **not** accept raw sample arrays.
- A curve `Declaration` channel (scope/snapshot/resolve for continuous data, per zongzi `declaration-projection-resolution`) is still to be defined — `Port.Declarations.PhonemeTiming` is the reference implementation.

### Compiler Integration

1. Caller builds one `RenderRequest` per window via `RenderRequest.from_window/3` (survived interventions filtered by `Declaration.scope` ∩ window).
2. At check time, the Compiler resolves interventions per channel (`Zongzi.Intervention.Declaration.resolve_within/2`) and dispatches resolved data to `data_interventions`, keyed by `PortRef`. The `PortRef → Orchid key` translation reuses existing `Graph.PortRef.to_orchid_key/1`.
3. Payload shape given to the Hook:
   ```text
   %{param: atom(), start_tick: non_neg_integer(), end_tick: non_neg_integer(),
     stride: pos_integer(), samples: binary()}
   ```
4. No `param_name` is privileged inside Kernel code.

### Phase 1 — Domain

- [x] Curve types come from zongzi (`Zongzi.Curve.Chunk`, `ControlPoint`, `Adapter.Bezier/CatmullRom`).
- [ ] Curve channel `Declaration` (continuous data) — pending; reference implementation: `Port.Declarations.PhonemeTiming`.
- [ ] Add `RasterCache` + rasterizer — **deferred**: plugs into the resolve-at-check flow.
- [ ] Add stroke-simplification helper (Douglas-Peucker) — **deferred**: same as above.
- [x] ~~`Track.data_channels` / `LayerChunk`~~ — abolished; `Track.interventions` instead.
- [ ] Implement serialization for curve types — **deferred**: pending curve model stabilization.

Each step ends on a green `cd domain && mix precommit`.

### Phase 2 — Kernel Integration

After Domain is stable:

- [x] `EquinoxDomain.Command.RenderRequest` rewritten (interventions + declarations; `from_window/3` done).
- [x] `EquinoxDomain.Command.AdoptRequest` rewritten (mount intervention; `adopt/3` done).
- [x] Remove `curves`, `synth_override`, `graph`, `cluster` from legacy `%Segment{}` — done in the mid-stage migration: the legacy Segment module was deleted outright; `EquinoxDomain.Segment` is the rendering-context VO.
- [x] ~~Add legacy-tolerant loader in `Project.from_json/1` for old payloads.~~ — obsolete: the kernel legacy JSON chain was removed in the oi migration; project hydration will be rebuilt on domain Pickle + `Zongzi.Timeline.build/1`.
- [x] Update `Session.Context.prepare_dispatch/1` (formerly `dispatch_to_plans/1`) to build `RenderRequest` per window via `RenderRequest.from_window/3`.
- [ ] Define curve channel Declaration(s) and emit curve `data_interventions` in the Compiler (resolve at check time).
- [ ] Thread curve operations through Session-level undo/redo (Phase 3; the legacy `Equinox.Editor.History` module was removed in the oi migration).

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

## 10. Known Issues (kernel scope — address during Phase 2)

Ordered roughly by priority; do not fix opportunistically without a matching commit plan.

Former #1–#3 (`Track.remove_segment/2` + `Project.remove_track/2` silent failures, `Editor.add_note/4` hard-match, English-only `Equinox.Editor.*` comments) disappeared with the legacy modules in the Phase 2 mid-stage migration. Remaining:

1. `StepRegistry` startup ordering: `Supervisor.start_link` then `register_builtin_steps` — works but not clean.

Resolved during the oi migration (2026-07): former #4 (`Session.Server.handle_info/2` swallowing render-task failures — now logged distinctly) and #6 (`Compiler.compile_cache` typespec mismatch — cache shape rewritten on `Oi.Compiled`).

Facts after the oi migration:

- The kernel legacy JSON chain (`@derive Jason.Encoder` / `from_json` / `from_attrs` on `Project` / `Track` / `Domain.Segment`) has been removed — the domain Pickle codecs replace it. `Kernel.Graph.*` keeps its `@derive` (SvelteFlow graph persistence is used by ui_shell), and the `:jason` dependency stays.
- `Equinox.PubSub` naming belongs to ui_shell; kernel has no PubSub code path (`Kernel.Engine`'s never-implemented PubSub moduledoc claim died with that module).
