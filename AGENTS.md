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
- **Stateless Kernel**: The Kernel (`Equinox.Kernel.*`, `Equinox.Domain.*`, `Equinox.Editor.*`) is pure-functional wherever possible. Persistent state lives in downstream consumers (`Equinox.Session.Server`, `ui_shell`). The only tolerated stateful Kernel component is `Equinox.Kernel.StepRegistry` (build-time catalog, not session state). 💡
- **Slicer Model**: Slicing is a pure one-way projection `Notes → Slice → Segment`. `Slicer` never mutates `Segment`s after materialization; later edits happen directly on `Segment.notes` through `Equinox.Editor`. `slice_flag` on `Note` is an *input signal* for `Slicer`, not a post-hoc synchronization channel. 💡
- **Curves belong to Track, not Segment**: Continuous parameter curves (pitch, energy, breathiness, …) are stored as `CurveLayer`s on `Track`. Segments hold only discrete notes. At compile time, the Compiler slices relevant curves into the active `SegmentContext`. 💡
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

- Kernel (`cd kernel`): `mix deps.get`, `mix test`
- UI Shell (`cd ui_shell`): `mix deps.get`, `iex -S mix phx.server`
- Frontend (`cd ui_shell/assets`): `npm run dev`, `npm run build`, `npm run check`
- Pre-commit: `cd kernel && mix precommit`, `cd ui_shell && mix precommit`

## 7. Architecture Decision Records 💡

Short, load-bearing decisions. New Agents MUST read these before touching Kernel code.

### ADR-001 — Slicer is a one-way projection

`Equinox.Domain.Slicer` consumes a flat list of `Note`s and produces either transient `slice()` maps or concrete `%Segment{}`s via `materialize_segments/3`. Once a Segment exists, it becomes the authoritative container for its notes. Re-running the slicer over a Track does **not** silently mutate existing Segments; callers must explicitly reconcile.

- `Note.slice_flag` is an input signal for the slicer (manual overrides + rest-gap hints), not a runtime sync channel.
- `Segment.extra.slice_id` is a weak provenance pointer, not a foreign key.

### ADR-002 — Curves are a Track-level layer

Continuous parameter curves live on `Track.curve_layers`, keyed by `param_name :: atom()` (e.g., `:pitch`, `:energy`). They are orthogonal to Segment boundaries and survive re-slicing.

Rationale: Segments are derived from Notes; forcing curves to live inside Segments would tie curve continuity to a derivation artifact.

### ADR-003 — Control points authoritative, rasterization is cache

A `CurveChunk` stores sparse control points as truth and a raster cache (`stride` + `binary` samples) as a derivable artifact. Only control points are serialized; raster caches are rebuilt on demand.

Hand-drawn strokes from the UI are simplified (Douglas-Peucker or similar) into control points **before** they enter `Equinox.Editor` / `History`. Raw per-pixel samples never reach History.

### ADR-004 — Curves enter the pipeline as data interventions

The Kernel does not hardcode the semantics of any curve parameter. At compile time, the Compiler:

1. Slices the relevant `CurveLayer`s into the Segment's tick range.
2. Rasterizes the slice to a binary payload tagged with `param_name`.
3. Emits a `data_intervention` keyed by `PortRef`.

An **Orchid Hook** (user-supplied, registered via `Configurator.plugins`) maps `param_name → (target_node, target_port)` and consumes the payload. Validation is delegated to `Orchid.Param` typing.

### ADR-005 — `SegmentContext` is Compiler's input DTO

`Segment` is pure note-bearing data. Compile-time fields (`graph`, `cluster`, `synth_override`, resolved `curve_slices`, `history`) live on `Equinox.Kernel.Compiler.SegmentContext`, constructed per call.

`Compiler.compile_segment/2` takes `%SegmentContext{}`, not `%Segment{}`.

## 8. Do Not Do 💡

Hard constraints. Violating these means the refactor is wrong.

- Do not add `GenServer` / `Agent` / `:ets` inside `Equinox.Kernel.*` except the existing `StepRegistry`.
- Do not restore `graph`, `cluster`, `synth_override`, or `curves` fields on `%Segment{}`. They belong on `SegmentContext` (compile-time) or `Track` (curves).
- Do not let `Equinox.Kernel.Compiler` read from `%Track{}` directly. It only sees `%SegmentContext{}`.
- Do not hardcode `:pitch`, `:energy`, etc. anywhere in `Equinox.Kernel.*`. Curve semantics are Hook territory.
- Do not feed raw per-frame drawing samples into `Equinox.Editor` or `History`. Simplify to control points first.
- Do not re-run `Slicer` implicitly during `Editor` note operations. Segment mutations are explicit.

## Current Milestones & Focus

1. ~~**M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~
5. **M4 — Slicer semantics & segment application**: Finalize `Note.slice_flag` model, automatic rest-gap slicing, user overrides, and the editor/session flow that materializes slices into `Segment` updates.
   - Status: `Notes -> Slice -> Segment` projection and session-level `slice_id -> Segment.id` remapping are in place; covered by bulk-import and incremental-entry workflow tests.
6. **M5 — Arranger**: Second SvelteFlow canvas, multi-track mix, slice/segment alignment, and slice-aware editing affordances.
7. **M6 — Curves**: Track-level `CurveLayer` model, control-point + rasterization pipeline, Compiler injection as `data_intervention`, Orchid Hook contract. 💡
8. **M7 — History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.
9. **M8 — Plugin System**: Runtime dynamic loading of custom Synth Nodes.
   - Frontend: Implement WebComponent wrapping for SvelteFlow to load arbitrary third-party UI `.js` securely via dynamic `<script type="module">`.
   - Backend: Distributed Erlang Architecture. Spawn isolated BEAM OS processes (`Engine Node`) per Session to execute Orchid graphs. Safely hot-load `.beam` modules at runtime without risking the main Phoenix `Web Node` stability.

## M4 — Slicer Semantics & Note Editing

### Slicer Scenarios

- **Continuous Notes Import**: MIDI/ustx import produces dense note sequences. Default behavior: derive initial slice boundaries from rest-gap detection (`min_rest_ticks` threshold). This covers the majority of initial modeling.
- **Manual Override**: User can explicitly mark a note as slice start/end, overriding automatic derivation.
- **Edit Repair**: After split/merge/drag/time-change operations, locally recalculate and repair `slice_flag` to ensure slices don't dangle or overlap.
- **Materialization**: Slice semantics are note-level; generating/updating `Segment` is a separate, explicit step — never an implicit side effect of note edits. 💡

### `slice_flag` Design

Define `slice_flag` on `Equinox.Domain.Note` as:

```elixir
@type slice_flag :: {:on_start, slice_id :: String.t()} | :on_end | nil
```

- `{:on_start, slice_id}`: marks the start of a new slice
- `:on_end`: marks the end of current slice
- `nil`: note is inside a slice (not a boundary)
- Single-note slice: `{:on_start, slice_id}` alone is enough; the slice is closed by the next `{:on_start, _}` or the end of the note stream.

`slice_id` is a stable logical grouping identifier. During materialization, it maps onto persisted `Segment.id` via a session-level registry passed through `Slicer.materialize_segments/3` (`:segment_ids`).

### Note Editing Functions (`Equinox.Domain.Note`)

Note-local transforms:

- `new/1(attrs)` — create a new note
- `update/2(note, attrs)` — update note fields
- `merge/2(note1, note2)` — merge two overlapping notes
- `split/3(note, split_tick, attrs)` — split note at a tick position

### Track Editing Functions (`Equinox.Track`)

Track orchestrates note operations and repairs slice boundaries:

- `insert_note/3(track, note, opts)` — insert and repair affected slice
- `delete_note/2(track, note_id)` — delete and repair affected slice
- `split_note/3(track, note_id, split_tick)` — split and repair
- `merge_notes/3(track, note_id1, note_id2)` — merge and repair
- `update_note/3(track, note_id, attrs)` — update and repair if timing changed
- `apply_slice_flag/3(track, note_id, slice_flag)` — manual override

### Slice Repair Rules

After each track edit, repair algorithm:

1. Identify affected interval (expanded to cover adjacent slice boundaries).
2. Reset slice flags in affected interval to `nil`.
3. Re-run rest-gap detection to assign `{:on_start, slice_id}` and `:on_end`.
4. Preserve user manual overrides where possible.
5. Ensure consistency: every `:on_end` has a preceding `{:on_start, _}`.

### Materialization Flow

Editor/Session layer:

1. Track edits update `track.notes` with repaired `slice_flag`.
2. Session materializes slices into `Segment` updates:
   - For each slice, create/update `Segment` with slice's note references.
   - Maintain `slice_id → Segment.id` mapping.
3. Compiler renders from `Segment` level (via `SegmentContext`).

## M6 — Curves (Refactor Spec) 💡

### Goals

1. Continuous parameter curves become a first-class, **Track-scoped** data layer.
2. Segment stays a minimal note container.
3. Compiler becomes the sole translator from `CurveLayer` → `data_intervention`.
4. Kernel stays semantics-agnostic about individual curve parameters; consumption is Orchid Hook territory.

### Target Module Layout

```text
kernel/lib/equinox/
├── domain/
│   ├── note.ex
│   ├── slicer.ex
│   ├── curve_chunk.ex        # new
│   ├── curve_layer.ex        # new
│   └── raster_cache.ex       # new
├── editor/
│   ├── editor.ex             # + curve operations
│   ├── history.ex
│   └── segment.ex            # slimmed down
├── kernel/
│   ├── compiler.ex           # accepts SegmentContext
│   ├── compiler/
│   │   └── segment_context.ex  # new
│   └── ...
└── ...
```

### Data Structures (intent, not literal code)

- `Equinox.Domain.CurveChunk`: `{id, start_tick, end_tick, control_points, rasterized | nil, source, extra}`. Control points carry `(tick, value, kind, tension)`.
- `Equinox.Domain.CurveLayer`: `{param :: atom(), chunks :: [CurveChunk.t()], extra}`. No default mode — absent coverage means "no intervention".
- `Equinox.Domain.RasterCache`: `{stride, samples :: binary, fingerprint}`. Rebuildable from control points; never serialized.
- `Equinox.Kernel.Compiler.SegmentContext`: `{segment, curve_slices, synth_override, graph, cluster, history}`. The only struct passed into `Compiler.compile_segment/2`.

### Segment Shrinkage

After M6, `%Equinox.Domain.Segment{}` keeps only: `id, track_id, name, offset_tick, notes, extra`.
Removed: `curves`, `synth_override`, `graph`, `cluster`.

A legacy loader path in `Project.from_json/1` should tolerate old payloads containing the removed fields (skip them or emit a one-time migration notice).

### Editor API Additions

- `Equinox.Editor.apply_curve_stroke(project, track_id, param, %CurveChunk{})`: atomic insertion of a completed stroke. Emits `{:set_intervention, ...}`-shaped history entries under the hood.
- `Equinox.Editor.erase_curve_range(project, track_id, param, start_tick, end_tick)`: erase within a range.
- `Equinox.Editor.clear_curve_layer(project, track_id, param)`: wipe a whole layer.

Strokes are assumed already-simplified control-point chunks (see ADR-003). The Editor does **not** accept raw sample arrays.

### Compiler Integration

1. Caller builds one `SegmentContext` per `(Track, Segment)` pair, slicing all relevant `CurveLayer`s to `[offset_tick, offset_tick + segment_span)` and rebasing to local ticks.
2. `Compiler.compile_segment/2` dispatches curve slices to `data_interventions`, keyed by `PortRef`. The `PortRef → Orchid key` translation reuses existing `Graph.PortRef.to_orchid_key/1`.
3. Payload shape given to the Hook:
   ```text
   %{param: atom(), start_tick: non_neg_integer(), end_tick: non_neg_integer(),
     stride: pos_integer(), samples: binary()}
   ```
4. No `param_name` is privileged inside Kernel code.

### Migration Steps (Agent Checklist)

Phase 1 — Pure data (no impact on main flow):

- [ ] Add `Equinox.Domain.CurveChunk` + unit tests.
- [ ] Add `Equinox.Domain.CurveLayer` + unit tests (insert/replace/erase/slice).
- [ ] Add `Equinox.Domain.RasterCache` + rasterizer (linear / cubic / step interpolation).
- [ ] Add stroke-simplification helper (Douglas-Peucker, tunable epsilon).

Phase 2 — Storage integration:

- [ ] Add `curve_layers` field to `%Equinox.Track{}`, default `%{}`.
- [ ] Extend `Track.from_attrs/1` and `Jason.Encoder` derivation to round-trip `curve_layers`.
- [ ] Add `Editor.apply_curve_stroke/4`, `erase_curve_range/5`, `clear_curve_layer/3`.
- [ ] Thread curve operations through `Editor.History.Operation` (reuse `data_interventions` shape).

Phase 3 — Compiler integration:

- [ ] Introduce `Equinox.Kernel.Compiler.SegmentContext`.
- [ ] Add adapter `Compiler.compile_segment(%Segment{}, cache)` → wraps a zero-curves `SegmentContext` for backward compatibility.
- [ ] Change primary `Compiler.compile_segment/2` to accept `%SegmentContext{}`.
- [ ] Update `Session.Context.dispatch_to_plans/1` to build `SegmentContext` per segment from its owning `Track`.
- [ ] Emit curve `data_interventions` in the Compiler.

Phase 4 — Cleanup:

- [ ] Remove `curves`, `synth_override`, `graph`, `cluster` from `%Segment{}` and its `Jason.Encoder` impl.
- [ ] Add legacy-tolerant loader in `Project.from_json/1`.
- [ ] Delete the `Segment`-taking adapter from Phase 3 once all call sites pass `SegmentContext`.

Each phase ends on a green `cd kernel && mix precommit`.

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

## Refactor In Progress — Vibe Cleanup + M6 Phase 4 Prep

Ongoing cleanup sweep; pick up here on resume.

### Done

- `Equinox.Util.Id.generate/0` extracted; 5 duplicated `generate_id/0` call sites replaced.
- `Equinox.Util.Attrs.normalize/1` extracted (string→atom direction only). Slicer's reverse-direction `segment_ids` key normalization is inlined at the call site on purpose — it is a `slice_id → segment_id` map, not attrs.
- `%Equinox.Editor.Segment{}` relocated to `%Equinox.Domain.Segment{}`; all references updated (kernel, tests, `ui_shell`).
- `Equinox.Util.Attrs` moduledoc carries a TODO about atom-table leak via `String.to_atom/1` (revisit with `to_existing_atom/1` or a field whitelist).

### Open — Segment Shrinkage (M6 Phase 4 early)

Target: remove `curves / synth_override / graph / cluster` from `%Segment{}`. Held back pending Worker's architectural review.

When resuming:

- Shrink `defstruct`, `@type t`, `new/1`, `from_attrs/1`, and the `Jason.Encoder` impl in `kernel/lib/equinox/domain/segment.ex`.
- Tolerate reads in `Equinox.Kernel.Compiler` temporarily via `Map.get(segment, :graph, %Graph{})` / `Map.get(segment, :cluster, %Graph.Cluster{})` / `Map.get(segment, :data_interventions, %{})`. Mark each such site with a comment pointing to M6 Phase 4 / `SegmentContext`. Current concrete sites:
  - `compiler.ex:77` — `Enum.group_by(resolved_items, &{&1.graph, &1.segment.cluster})`
  - `compiler.ex` `resolve_effective_state/1` — reads `segment.graph`
  - `compiler.ex` `apply_bundles` closure — reads `segment.data_interventions` (already `Map.get/3`, keep)
- `Project.from_json/1`: drop removed fields silently, `Logger.debug/1` a one-line notice. Do not crash on legacy payloads.
- If tests depend on the removed fields, list them for review before deleting.

### Known Smells Not Yet Addressed

Ordered roughly by priority; do not fix opportunistically without a matching commit plan.

1. `Track.remove_segment/2` and `Project.remove_track/2` fail silently — contract mismatch with §5.
2. `Editor.add_note/4` hard-matches `{:ok, _} = Track.update_segment(...)` — violates §5.
3. Comment language mixed: `Equinox.Editor` module is all English (AI smell), rest is Chinese. Standardize to Chinese.
4. `Equinox.Editor` misnamed — does not emit `History.Operation`; `History` is effectively orphaned. Needs an architectural decision before any rename/merge.
5. `Session.Server.handle_info/2` only handles task success; failures get swallowed by `Logger.warning("unknown message")`. Bug.
6. `StepRegistry` startup ordering: `Supervisor.start_link` then `register_builtin_steps` — works but not clean.
7. `Compiler.compile_cache` typespec disagrees with actual shape.

## Next Session Starting Point

- M4 close-out: lock the exact automatic slicing invariants for `Note.slice_flag` across split/merge/tail-append edits, and confirm `slice_id ↔ Segment.id` mapping lives in session-level registry rather than Slicer itself.
- M6 kickoff: start Phase 1 (pure `Domain.Curve*` modules) — no other subsystems are touched, so it can proceed in parallel with M5 UI work.
