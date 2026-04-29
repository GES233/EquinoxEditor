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
└─────────────────────────────────┘
```

- **Domain** is the foundation: pure data structures (`Note`, `Segment`, `CurveChunk`, etc.) and stateless domain logic (`Slicer`). Zero dependencies on Kernel, Session, or UI.
- **Kernel** consumes Domain types for compilation, planning, and graph construction. Never imports UI or Session.
- **Session / UI Shell** sit at the outermost layer, consuming both Domain and Kernel.

**Current priority**: The stability of the Domain layer is decoupled from the Domain-Kernel. No new features should be added to the Kernel or UI Shell before the Domain layer is complete.

### EquinoxDomain — Independent Domain Project

The `EquinoxDomain` module lives in `domain/` as a **separate, zero-dependency Elixir project** (`:equinox_domain`). It is the canonical home for all domain types and pure business logic. The `kernel/lib/equinox/domain/` directory is legacy and will be replaced.

**Project location**: `domain/` (root-level, sibling to `kernel/` and `ui_shell/`)

**Key design decisions**:
- `use EquinoxDomain.Util.Model, keys: [...], id_prefix: "Xxx_"` auto-generates `new/1` and `update/2` for all domain structs. `update/2` returns `{:ok, model} | {:error, reason}`.
- `Note.slice_flag` uses `:auto | :force_slice | :force_merge` (simpler than kernel's tuple-based version).
- `Track` holds `notes: %{}` (map by id) and `curve_layers: %{}` (M6).
- `Phoneme` is a standalone value object with timing info (`symbol`, `type`, `tick_offset`, `duration_tick`).
- `Utterance` replaces the kernel's `Segment` concept — it groups notes + phonemes into a continuous vocal phrase, and determines rasterization boundaries for the render pipeline. The engine does not need to understand the Note domain model.
- `Segment` is a pure rendering-context VO (acoustic boundaries, rasterized phonemes/curves) — not a note container.

**Build/Test**: `cd domain && mix test` | **Pre-commit**: `cd domain && mix precommit`

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

- **Domain-First Development**: `EquinoxDomain.*` (in `domain/`) is the cornerstone of the project. All domain models (data structures + pure functional logic) must be completed and thoroughly tested at this layer before development of the Kernel or UI Shell can begin. The Domain project is prohibited from depending on Kernel or UI modules.💡
- **Pure Data**: `Project`, `Track`, `Utterance`, `Note`, `Phoneme`, and `Segment` are pure data structures (JSON/Pickle serializable). No Ecto schemas, no executable closures inside them.
- **Timing Model**: Use **Ticks / Beats** (musical time) for storage. Conversions to acoustic frames or audio samples happen in the Elixir Kernel, never in Svelte.
- **Stateless Kernel**: The Kernel (`Equinox.Kernel.*`, `Equinox.Editor.*`) is pure-functional wherever possible. Domain types come from `EquinoxDomain.*`. Persistent state lives in downstream consumers (`Equinox.Session.Server`, `ui_shell`). The only tolerated stateful Kernel component is `Equinox.Kernel.StepRegistry` (build-time catalog, not session state). 💡
- **Slicer Model**: Slicing is a pure one-way projection `Notes → Slice → Utterance`. `Slicer` never mutates `Utterance`s after materialization; later edits happen on `Track.notes` with automatic slice repair. `slice_flag` (`:auto | :force_slice | :force_merge`) on `Note` is an *input signal* for `Slicer`, not a post-hoc synchronization channel. 💡
- **Curves belong to Track, not Utterance/Segment**: Continuous parameter curves (pitch, energy, breathiness, …) are stored as `CurveLayer`s on `Track`. Utterances hold only notes + phonemes; Segments are pure rendering-context VOs. At compile time, the Compiler slices relevant curves into the active `SegmentContext`. 💡
- **UI Layout Hierarchy**:
  - `EditorLive` (Main Shell) -> Top-level dispatcher.
  - `TrackList` -> Vertical stack for mute/solo.
  - `PianoRoll` / `Arranger` -> SvelteFlow canvases (hybrid rendering with SVG/Canvas overlays).
  - `Synthesizer Node Editor` -> DiffSinger pipeline topology editor.

## 5. Coding Conventions

- **Elixir**: Return `{:ok, value} | {:error, reason}` (except some Context-like structs, which prefer `t() -> t() | {:error, reason}`). API names start with verbs (`create_`, `update_`).
- **Svelte 5**: Runes ONLY (`$state`, `$derived`, `$props`, `$effect`).
- **Tailwind v4**: `!` modifier goes at the END (e.g., `bg-amber-500!`). Gradients use `bg-linear-to-b`.
- **SvelteFlow**: NEVER use reserved node types like `input`/`output`. Use custom names (e.g., `custom_input`).

## 6. Essential Commands

- Domain (`cd domain`): `mix test`, `mix precommit`
- Kernel (`cd kernel`): `mix deps.get`, `mix test`, `mix precommit`
- UI Shell (`cd ui_shell`): `mix deps.get`, `iex -S mix phx.server`, `mix precommit`
- Frontend (`cd ui_shell/assets`): `npm run dev`, `npm run build`, `npm run check`

## 7. Architecture Decision Records 💡

Short, load-bearing decisions. New Agents MUST read these before touching Kernel code.

### ADR-001 — Slicer is a one-way projection (Notes → Utterance)

`EquinoxDomain.Score.Slicer` consumes a flat list of `Note`s and produces `Utterance` structs via `materialize/2`. An `Utterance` groups contiguous notes + phonemes into a renderable vocal phrase. Once an Utterance exists, it becomes the authoritative container for its notes. Re-running the slicer over a Track does **not** silently mutate existing Utterances; callers must explicitly reconcile.

- `Note.slice_flag` (`:auto | :force_slice | :force_merge`) is an input signal for the slicer (manual overrides + rest-gap hints), not a runtime sync channel.
- The rendering engine consumes `Utterance` + rasterized curves via `SegmentContext`; it does not need to understand the Note domain model.
- `Utterance` determines rasterization boundaries for both phonemes and curves.

### ADR-002 — Curves are a Track-level layer

Continuous parameter curves live on `Track.curve_layers`, keyed by `param_name :: atom()` (e.g., `:pitch`, `:energy`). They are orthogonal to Utterance/Segment boundaries and survive re-slicing.

Rationale: Utterances are derived from Notes; forcing curves to live inside Utterances would tie curve continuity to a derivation artifact.

### ADR-003 — Control points authoritative, rasterization is cache

A `CurveChunk` stores sparse control points as truth and a raster cache (`stride` + `binary` samples) as a derivable artifact. Only control points are serialized; raster caches are rebuilt on demand.

Hand-drawn strokes from the UI are simplified (Douglas-Peucker or similar) into control points **before** they enter `Equinox.Editor` / `History`. Raw per-pixel samples never reach History.

### ADR-004 — Curves enter the pipeline as data interventions

The Kernel does not hardcode the semantics of any curve parameter. At compile time, the Compiler:

1. Slices the relevant `CurveLayer`s into the Utterance's tick range.
2. Rasterizes the slice to a binary payload tagged with `param_name`.
3. Emits a `data_intervention` keyed by `PortRef`.

An **Orchid Hook** (user-supplied, registered via `Configurator.plugins`) maps `param_name → (target_node, target_port)` and consumes the payload. Validation is delegated to `Orchid.Param` typing.

### ADR-006 — Domain-Kernel Layered Decoupling

`EquinoxDomain` (in `domain/`) is a separate, zero-dependency Elixir project and the lowest layer. The Kernel can consume Domain types, but the Domain never references the Kernel.

Rules:

- `Equinox.Kernel`, `Equinox.Session`, and `Equinox.Editor` must not appear in the `alias`, `import`, or `use` of any `EquinoxDomain.*` module.
- The Domain only depends on the standard library and its own internal submodules.
- The `graph`, `cluster`, `synth_override`, and `curves` fields are Kernel compile-time concepts and must not appear on Domain structs. They live in `SegmentContext` (compile-time) or `Track` (curves).
- Legacy `Equinox.Domain.*` modules in `kernel/` will be replaced by `EquinoxDomain.*` during Phase 2 integration.

Development order: First, complete all Domain modules and tests in `domain/`; then, integrate Domain into Kernel; and finally, handle the UI Shell.

## 8. Do Not Do 💡

Hard constraints. Violating these means the refactor is wrong.

- Do not add `GenServer` / `Agent` / `:ets` inside `Equinox.Kernel.*` except the existing `StepRegistry`.
- Do not restore `graph`, `cluster`, `synth_override`, or `curves` fields on `%Segment{}` or `%Utterance{}`. They belong on `SegmentContext` (compile-time) or `Track` (curves).
- Do not let `Equinox.Kernel.Compiler` read from `%Track{}` directly. It only sees `%SegmentContext{}`.
- Do not hardcode `:pitch`, `:energy`, etc. anywhere in `Equinox.Kernel.*`. Curve semantics are Hook territory.
- Do not feed raw per-frame drawing samples into `Equinox.Editor` or `History`. Simplify to control points first.
- Do not let `EquinoxDomain.*` modules import or alias anything from `Equinox.Kernel.*`, `Equinox.Session.*`, or `Equinox.Editor.*`.
- Do not add `graph`, `cluster`, `synth_override` fields to Domain models — they belong in Kernel compile-time context (`SegmentContext`).
- Do not start Kernel or UI Shell feature work before the relevant Domain layer is stable and tested.
- Do not re-run `Slicer` implicitly during `Editor` note operations. Utterance materialization is explicit.

## Current Milestones & Focus

Current priority: **Phase 1 (Domain MVP) → Phase 2 (Domain-Kernel integration) → UI Shell**.

```
Phase 1 ──── Domain MVP (domain/)
  Complete all pure domain models + tests.
  Zero dependencies on Kernel or UI.

Phase 2 ──── Domain-Kernel Integration (kernel/)
  Replace legacy Domain types with the new domain project.
  Adapt Editor / Session / Compiler to Utterance + SegmentContext.
  M6 curve compilation pipeline.

Phase 3 ──── UI Shell Polish (ui_shell/)
  M5 Arranger, M7 History, M8 Plugin System.
```

### Completed
1. ~~**M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~

### Phase 1 — Domain MVP (domain/)
5. **M4 — Slicer semantics & Utterance materialization**: Implement `Note.slice_flag` (`:auto | :force_slice | :force_merge`), rest-gap slicing, `Notes → Slice → Utterance` projection, and `Materialize` as an explicit step. Track-level note CRUD with automatic slice repair.
6. **M6a — Curves (pure data)**: `CurveChunk`, `CurveLayer`, `RasterCache` modules + rasterizer (linear / cubic / step interpolation) + stroke simplification (Douglas-Peucker). Control points authoritative, raster cache derivable.
7. **Score models**: Complete `Key.TwelveET`, `Note` (split/merge/metadata), `Track` (note CRUD + curve layer management), `Project`, `Utterance`, `Phoneme` linkage.
8. **Timeline**: Complete `TimeSigMap.compile/1`, `Tempo.Linear`, `Tempo.Curve`.
9. **Editing commands**: Implement `Command.Editing` concrete commands (DragNote, ResizeNote, EditLyric, SplitNote, MergeNotes, AddTrack, DeleteTrack) + command stack for undo/redo.
10. **Session / Render request**: Define `Session` (selection, clipboard, viewport) and `Command.RenderRequest`.
11. **Serialization + Tests**: `Pickle` protocol implementations for all domain types + comprehensive test coverage.

### Phase 2 — Domain-Kernel Integration (kernel/)
12. **Domain dependency**: Add `:equinox_domain` to kernel, delete legacy `Equinox.Domain.*`, replace all references.
13. **Slicer → Utterance**: Rewrite Slicer for new `slice_flag` model; `materialize_utterances` replaces `materialize_segments`.
14. **Track API**: `insert_note`, `delete_note`, `split_note`, `merge_notes`, `update_note` with automatic slice repair.
15. **SegmentContext + M6b**: Introduce `SegmentContext`, remove `graph`/`cluster`/`synth_override`/`curves` from Segment. Slice `CurveLayer`s into tick range, rasterize, emit `data_interventions` via Hook contract.
16. **Editor / Session adaptation**: Editor ops → Track API → explicit materialization. Session manages `utterance_id ↔ segment_id` mapping.

### Phase 3 — UI Shell (ui_shell/)
17. **M5 — Arranger**: Second SvelteFlow canvas, multi-track mix, slice/utterance alignment, slice-aware editing affordances.
18. **M7 — History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.
19. **M8 — Plugin System**: Runtime dynamic loading of custom Synth Nodes.
    - Frontend: WebComponent wrapping for SvelteFlow, third-party UI `.js` via dynamic `<script type="module">`.
    - Backend: Distributed Erlang — isolated BEAM `Engine Node` per Session for Orchid graph execution, hot-load `.beam` modules without risking the Phoenix `Web Node`.

## M4 — Slicer Semantics & Utterance Materialization

### Slicer Scenarios

- **Continuous Notes Import**: MIDI/ustx import produces dense note sequences. Default behavior: derive initial slice boundaries from rest-gap detection (`min_rest_ticks` threshold). This covers the majority of initial modeling.
- **Manual Override**: User can explicitly mark a note with `:force_slice` or `:force_merge`, overriding automatic derivation.
- **Edit Repair**: After split/merge/drag/time-change operations, locally recalculate and repair `slice_flag` to ensure slices don't dangle or overlap.
- **Materialization**: Slice semantics are note-level; generating/updating `Utterance` is a separate, explicit step — never an implicit side effect of note edits. 💡

### `slice_flag` Design

Define `slice_flag` on `EquinoxDomain.Score.Note` as:

```elixir
@type slice_flag :: :auto | :force_slice | :force_merge
```

- `:auto`: default; Slicer decides boundaries via rest-gap detection.
- `:force_slice`: force a slice boundary at this note's start (equivalent to the next note being `{:on_start, new_id}`). A single `:force_slice` note forms a standalone utterance.
- `:force_merge`: prevent a slice boundary even if a rest gap exceeds the threshold.

The Slicer produces `Utterance` structs — continuous vocal phrases that group notes and their associated phonemes. The rendering engine works with `Utterance` + rasterized curves; it does not need to understand the Note domain model.

### Note Editing Functions (`EquinoxDomain.Score.Note`)

Note-local transforms:

- `new/1(attrs)` — create a new note
- `update/2(note, attrs)` — update note fields
- `merge/2(note1, note2)` — merge two overlapping notes
- `split/3(note, split_tick, attrs)` — split note at a tick position

### Track Editing Functions

Track directly owns `notes` as `%{note_id => Note.t()}` and orchestrates note operations with slice repair:

- `insert_note/3(track, note, opts)` — insert and repair affected slice
- `delete_note/2(track, note_id)` — delete and repair affected slice
- `split_note/3(track, note_id, split_tick)` — split and repair
- `merge_notes/3(track, note_id1, note_id2)` — merge and repair
- `update_note/3(track, note_id, attrs)` — update and repair if timing changed
- `apply_slice_flag/3(track, note_id, slice_flag)` — manual override

### Slice Repair Rules

After each track edit, repair algorithm:

1. Identify affected interval (expanded to cover adjacent slice boundaries).
2. Reset slice flags in affected interval to `:auto`.
3. Re-run rest-gap detection to determine natural boundaries.
4. Preserve user `:force_slice` / `:force_merge` overrides where possible.
5. Ensure consistency: no orphaned boundaries.

### Materialization Flow

Editor/Session layer:

1. Track edits update `track.notes` with repaired `slice_flag`.
2. Slicer produces `Utterance` structs: `Notes → Slice → Utterance`.
3. Session materializes utterances and maintains `utterance_id` mapping.
4. Compiler renders from `Utterance` level — utterances determine rasterization boundaries for both phonemes and curves.

## M6 — Curves

Split into M6a (pure data, Phase 1) and M6b (kernel integration, Phase 2).

### Goals

1. Continuous parameter curves become a first-class, **Track-scoped** data layer.
2. Utterance stays a minimal note + phoneme container; Segment is a pure rendering context VO.
3. Compiler becomes the sole translator from `CurveLayer` → `data_intervention`.
4. Kernel stays semantics-agnostic about individual curve parameters; consumption is Orchid Hook territory.

### Data Structures (matching domain project)

- `EquinoxDomain.Curve.Chunk`: `{id, start_tick, end_tick, control_points, rasterized | nil, source, extra}`. Control points carry `(tick, value, kind, tension)`.
- `EquinoxDomain.Curve.Layer`: `{param :: atom(), chunks :: [Chunk.t()], extra}`. Lives on `Track.curve_layers`. No default mode — absent coverage means "no intervention".
- `EquinoxDomain.Curve.RasterCache`: `{stride, samples :: binary, fingerprint}`. Rebuildable from control points; never serialized.
- `Equinox.Kernel.Compiler.SegmentContext`: `{utterance, curve_slices, synth_override, graph, cluster, history}`. The only struct passed into `Compiler.compile/2`.

### Segment Shrinkage

After M6, `%EquinoxDomain.Segment{}` retains only rendering-context fields: `track_id, utterance_id, start_tick, end_tick, core_start_sec, core_end_sec, context_start_sec, context_end_sec, rasterized_phonemes, rasterized_curves`.

Removed from Kernel's legacy Segment: `curves`, `synth_override`, `graph`, `cluster`. These move to `SegmentContext` (compile-time) or `Track` (curves).

### Editor API Additions

- `Editor.apply_curve_stroke(project, track_id, param, %Chunk{})`: atomic insertion of a completed stroke. Emits history entries.
- `Editor.erase_curve_range(project, track_id, param, start_tick, end_tick)`: erase within a range.
- `Editor.clear_curve_layer(project, track_id, param)`: wipe a whole layer.

Strokes are assumed already-simplified control-point chunks (see ADR-003). The Editor does **not** accept raw sample arrays.

### Compiler Integration

1. Caller builds one `SegmentContext` per `(Track, Utterance)` pair, slicing all relevant `CurveLayer`s to `[utterance.start_tick, utterance.start_tick + utterance.duration_tick)` and rebasing to local ticks.
2. `Compiler.compile/2` dispatches curve slices to `data_interventions`, keyed by `PortRef`. The `PortRef → Orchid key` translation reuses existing `Graph.PortRef.to_orchid_key/1`.
3. Payload shape given to the Hook:
   ```text
   %{param: atom(), start_tick: non_neg_integer(), end_tick: non_neg_integer(),
     stride: pos_integer(), samples: binary()}
   ```
4. No `param_name` is privileged inside Kernel code.

### M6a — Domain (Phase 1)

Pure data modules inside `domain/`, no impact on Kernel:

- [ ] Complete `EquinoxDomain.Curve.Chunk` + unit tests.
- [ ] Add `EquinoxDomain.Curve.Layer` + unit tests (insert/replace/erase/slice).
- [ ] Add `EquinoxDomain.Curve.RasterCache` + rasterizer (linear / cubic / step interpolation).
- [ ] Add stroke-simplification helper (Douglas-Peucker, tunable epsilon).
- [ ] Add `curve_layers` field to `EquinoxDomain.Score.Track`, default `%{}`.
- [ ] Implement `Pickle` serialization for all curve types.

Each step ends on a green `cd domain && mix precommit`.

### M6b — Kernel Integration (Phase 2)

After Domain is stable:

- [ ] Introduce `Equinox.Kernel.Compiler.SegmentContext` (wraps Utterance + curve slices).
- [ ] Remove `curves`, `synth_override`, `graph`, `cluster` from legacy `%Segment{}` and its `Jason.Encoder` impl.
- [ ] Add legacy-tolerant loader in `Project.from_json/1` for old payloads.
- [ ] Change primary `Compiler.compile/2` to accept `%SegmentContext{}`.
- [ ] Update `Session.Context.dispatch_to_plans/1` to build `SegmentContext` per utterance from its owning `Track`.
- [ ] Emit curve `data_interventions` in the Compiler.
- [ ] Thread curve operations through `Editor.History.Operation`.

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

Kernel does not ship a reference Hook. M6 delivers the contract and payload shape; the first concrete Hook lives outside Kernel (userland or a sibling package).

## Refactor In Progress — Domain MVP → Domain-Kernel Integration

Current priorities: Complete Domain MVP in `domain/` (Phase 1), then integrate into Kernel (Phase 2).

### Phase 1 — Domain MVP (domain/)

The `domain/` project (`EquinoxDomain`) is the canonical home for all domain types and pure business logic. It is a zero-dependency project built bottom-up.

**Completed:**
- Core timeline: `Tick`, `TempoMap`, `Tempo.Step`, `Grid`
- Utilities: `Util.Model`, `Util.Object`, `Util.ID`, `Util.Pickle`, `Helpers`
- Score data structures: `Note` (partial), `Phoneme`, `Utterance` (skeletal), `Track` (skeletal), `Project` (skeletal)
- VO: `Segment` (rendering context)
- Curve skeletal: `Curve.Chunk`

**In Progress / TODO (see milestones 5-11):**
- Complete `Note` (split/merge/metadata/serialization), `Track` (note CRUD + curve layers), `Project`
- `Slicer`: `Notes → Slice → Utterance` with `:auto | :force_slice | :force_merge` flags
- `Key.TwelveET`, `TimeSigMap.compile/1`, `Tempo.Linear`, `Tempo.Curve`
- M6a: `Curve.Layer`, `Curve.RasterCache`, rasterizer, stroke simplification
- `Command.Editing` implementations, `Session`, `Command.RenderRequest`
- `Pickle` protocol for all types + comprehensive tests

### Phase 2 — Domain-Kernel Integration (kernel/)

After Domain is stable: add `:equinox_domain` dep, delete legacy `Equinox.Domain.*`, adapt Editor/Session/Compiler to `EquinoxDomain.*`.

**Legacy cleanup (kernel scope):**
- Delete `kernel/lib/equinox/domain/note.ex`, `segment.ex`, `slicer.ex`
- Replace all `Equinox.Domain.*` references with `EquinoxDomain.*`
- Replace `Equinox.Util.Id` / `Equinox.Util.Attrs` with domain equivalents

**SegmentContext + M6b (kernel scope):**
- Introduce `Equinox.Kernel.Compiler.SegmentContext`
- Remove `graph`/`cluster`/`synth_override`/`curves` from legacy `%Segment{}`, add legacy-tolerant loader in `Project.from_json/1`
- `Compiler.compile/2` accepts `%SegmentContext{}`
- `Session.Context` builds `SegmentContext` per utterance from owning `Track`

### Known Smells (kernel scope — address during Phase 2)

Ordered roughly by priority; do not fix opportunistically without a matching commit plan.

1. `Track.remove_segment/2` and `Project.remove_track/2` fail silently — contract mismatch.
2. `Editor.add_note/4` hard-matches `{:ok, _} = Track.update_segment(...)` — violates error handling convention.
3. Comment language mixed: `Equinox.Editor` module is all English (AI smell), rest is Chinese. Standardize to Chinese.
4. `Equinox.Editor` misnamed — does not emit `History.Operation`; `History` is effectively orphaned.
5. `Session.Server.handle_info/2` only handles task success; failures get swallowed by `Logger.warning("unknown message")`.
6. `StepRegistry` startup ordering: `Supervisor.start_link` then `register_builtin_steps` — works but not clean.
7. `Compiler.compile_cache` typespec disagrees with actual shape.
