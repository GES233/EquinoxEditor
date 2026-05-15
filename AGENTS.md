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

### EquinoxDomain — Independent Domain Project

The `EquinoxDomain` module lives in `domain/` as a **separate, zero-dependency Elixir project** (`:equinox_domain`). It is the canonical home for all domain types and pure business logic. The `kernel/lib/equinox/domain/` directory is frozen — all new development targets `domain/`.

**Project location**: `domain/` (root-level, sibling to `kernel/` and `ui_shell/`)

**Key design decisions**:
- `use EquinoxDomain.Util.Model, keys: [...], id_prefix: "Xxx_"` auto-generates `new/1` and `update/2` for all domain structs. `update/2` returns `{:ok, model} | {:error, reason}`.
- `Note.slice_flag` uses `:auto | :force_slice | :force_merge` (simpler than kernel's tuple-based version).
- `Track` holds `notes: %{}` (map by id) and `data_channels: %{Channel.channel() => [LayerChunk.t()]}` (unified curve + adoption data).
- `Phoneme` is a standalone value object with identity fields (`symbol`, `type`). Timing (tick_offset, duration_tick, preutterance) lives in `TimedEvent` at the Kernel projection layer (see ADR-009).
- `Window` replaces the kernel's `Segment` concept — it groups contiguous notes by time window and determines rasterization boundaries for the render pipeline. Phonemes are a runtime projection (see ADR-009); the engine does not need to understand the Note domain model.
- `Segment` is a pure rendering-context VO (acoustic boundaries, `phonemes`/`curves`) — not a note container. The Domain defines the struct; `phonemes` and `curves` are populated by the Kernel at compile time and do not participate in serialization.

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

- **Domain-First Development**: `EquinoxDomain.*` (in `domain/`) is the cornerstone of the project. All domain models (data structures + pure functional logic) must be completed and thoroughly tested at this layer before development of the Kernel or UI Shell can begin. The Domain project is prohibited from depending on Kernel or UI modules.💡
- **Pure Data**: `Project`, `Track`, `Note`, `Phoneme` are pure data structures (JSON/Pickle serializable). `Segment` is also of type Domain, but its `phonemes` and `curves` fields are cached at runtime and do not participate in serialization. No Ecto schemas, no executable closures inside them.
- **Timing Model**: Use **Ticks / Beats** (musical time) for storage. Conversions to acoustic frames or audio samples happen in the Elixir Kernel, never in Svelte.
- **Stateless Kernel**: The Kernel (`Equinox.Kernel.*`) is pure-functional wherever possible. Domain types come from `EquinoxDomain.*`. Persistent state lives in downstream consumers (`Equinox.Session.Server`, `ui_shell`). The only tolerated stateful Kernel component is `Equinox.Kernel.StepRegistry` (build-time catalog, not session state). `Equinox.Editor.*` is partially obsolete and is no longer considered an independent concept. 💡
- **Slicer Model**: Slicing is a pure one-way projection `Notes → [Window]`. `Slicer` produces transient `Window` structs; later edits happen on `Track.notes` with automatic slice repair. `slice_flag` (`:auto | :force_slice | :force_merge`) on `Note` is an *input signal* for `Slicer`, not a post-hoc synchronization channel. 💡
- **Curves belong to Track, not Window/Segment**: Continuous parameter data (pitch, energy, breathiness, …) are stored as `[LayerChunk]` in `Track.data_channels`. Windows hold only `note_ids`; phonemes are runtime projection. Segments are pure rendering-context VOs. At compile time, the Compiler slices `data_channels` into the `RenderRequest` that feeds the Compiler. 💡
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

Short, load-bearing decisions. New Agents MUST read these before touching Kernel code.

### ADR-001 — Slicer is a one-way projection (Notes → Window)

> **Superseded by ADR-010.** The `Utterance` entity described below was retired. Rationale: Utterance originally carried phoneme timing and engine-adopted data, coupling the core domain to a specific phonetics backend. Moving phonetics-support code out of the domain (into external adapters/plugins) enables multi-backend engine adaptation — DiffSinger, NNSVS, world-level synthesizers, or custom G2P pipelines can plug in without the domain knowing their internals. The `Window` struct (transient, no identity, not serialized) is now the Slicer's sole output; all persistent interventions live in `Track.data_channels`.

`EquinoxDomain.Score.Slicer` consumes a flat list of `Note`s and produces `Window` structs — transient time-window descriptors. A `Window` is a pure slice artifact; it has no identity and is not persisted.

Without user intervention, `Window`s flow directly into the Compiler and are discarded — no persistent entity is created. All user interventions (curve strokes, engine output adoption) write to `Track.data_channels` as `LayerChunk`s, orthogonal to Slicer windows.

- `Note.slice_flag` (`:auto | :force_slice | :force_merge`) is an input signal for the slicer (manual overrides + rest-gap hints), not a runtime sync channel.
- The rendering engine consumes `RenderRequest` (which carries notes, data_slices, tempo_segments, and declarations); it does not need to understand the Note domain model.
- `Window` determines rasterization boundaries for both phonemes and curves.
- **Revised during ADR-009 implementation**: Port declarations live on `Track.presets[active_preset]` and are injected at compile time. The `note↔phoneme` mapping is a runtime Projection produced by the Kernel. `Window` is the Slicer's direct output — no intermediate entity is materialized.

### ADR-002 — Curves are a Track-level layer

All time-varying data — curves, adopted engine output, timing — lives in `Track.data_channels` as `[LayerChunk.t()]`, keyed by `Channel.channel()`. Each `LayerChunk` carries `source: :user | :adopted`; within the same channel, `:adopted` chunks override `:user` chunks on overlapping intervals. Data is orthogonal to Window/Segment boundaries and survives re-slicing.

Rationale: Windows are derived from Notes; forcing curves to live inside a slice entity would tie curve continuity to a derivation artifact.

### ADR-003 — Control points authoritative, rasterization is cache

A `CurveChunk` stores sparse control points as truth and a raster cache (`stride` + `binary` samples) as a derivable artifact. Only control points are serialized; raster caches are rebuilt on demand.

Hand-drawn strokes from the UI are simplified (Douglas-Peucker or similar) into control points **before** they enter the editing pipeline / `History`. Raw per-pixel samples never reach History.

### ADR-004 — Curves enter the pipeline as data interventions

The Kernel does not hardcode the semantics of any curve parameter. At compile time, the Compiler:

1. Slices the relevant `Curve.Cluster`s into the Window's tick range.
2. Rasterizes the slice to a binary payload tagged with `param_name`.
3. Emits a `data_intervention` keyed by `PortRef`.

An **Orchid Hook** (user-supplied, registered via `Configurator.plugins`) maps `param_name → (target_node, target_port)` and consumes the payload. Validation is delegated to `Orchid.Param` typing.

### ADR-005 — (retired, absorbed into Phase 3; numbering preserved)

### ADR-006 — Domain-Kernel Layered Decoupling

`EquinoxDomain` (in `domain/`) is a separate, zero-dependency Elixir project and the lowest layer. The Kernel can consume Domain types, but the Domain never references the Kernel.

Rules:

- `Equinox.Kernel`, `Equinox.Session`, and `Equinox.Editor` must not appear in the `alias`, `import`, or `use` of any `EquinoxDomain.*` module.
- The Domain only depends on the standard library and its own internal submodules.
- The `graph`, `cluster`, `synth_override`, and `curves` fields are Kernel compile-time concepts and must not appear on Domain structs. They live in `RenderRequest` (compile-time) or `Track.data_channels`.
- Legacy `Equinox.Domain.*` modules in `kernel/` will be replaced by `EquinoxDomain.*` during Phase 2 integration.

Development order: First, complete all Domain modules and tests in `domain/`; then, integrate Domain into Kernel; and finally, handle the UI Shell.

### ADR-007 — Rasterization Strategy (Domain behaviour, Kernel/NIF implementation)

Rasterization of control points into sample sequences is a performance-sensitive one-dimensional time-series operation. The strategy:

1. The Domain layer defines rasterization behavior (pure Elixir reference implementation).
2. The Kernel/NIF layer can be replaced with a high-performance implementation, using behavior contract constraints on the interface.
3. All rasterized data is cached at runtime and does not participate in serialization.

Rationale: Domain already possesses complete semantics for one-dimensional time series, but extensive rasterization on BEAM may present a performance bottleneck. Separating the definition and implementation allows for subsequent replacement with NIF without affecting the pure functional properties of the Domain layer.

### ADR-008 — Key is a Behaviour + nested Protocol, not a single Protocol

Pitch representation (`EquinoxDomain.Score.Key`) uses a dual-discipline architecture:

- **`Key` (Behaviour)**: Construction callbacks (`new/1`, `from_score/3`, `from_midi/2`). Module-level dispatch — the caller must know which tuning implementation to invoke. Wrapper functions (`Key.new/2`, `Key.from_midi/3`) proxy to the concrete module for polymorphic factory dispatch.
- **`Key.Inner` (Protocol)**: Outbound conversion functions (`to_midi/1`, `to_frequency/2`, `to_score/3`). Value-level dispatch — any `Key` struct automatically routes to the correct implementation.

Rationale:
- Construction needs module-level knowledge (you must choose TwelveET vs Pythagorean vs Just), which suits Behaviour.
- Conversion needs value-level polymorphism (a Track holds `Key.t()` and calls `Key.Inner.to_midi/1` without knowing the tuning), which suits Protocol.
- A single Protocol would force construction (which has no `Key.t()` instance yet) into awkward static functions on each module. Separating them keeps each dispatch mode in its natural home.

MVP contract: MIDI/frequency (`to_midi`/`to_frequency`) are fully implemented. Staff notation (`from_score`/`to_score`) signatures are reserved but return `{:error, :not_implemented}` — no runtime cost, no interface breakage when added later.

### ADR-009 — Unified Declaration → Projection → Resolution pipeline

All data that can be both engine-generated and user-modified goes through one lifecycle, regardless of payload shape.

**Two shapes:**

| Shape | Payload | Examples |
|---|---|---|
| `:continuous` | `{stride, float32 binary}` | pitch delta, energy, breathiness |
| `:event_sequence` | `[TimedEvent{at, dur, entity}]` | phoneme timing, note quantization |

**Pipeline:**

```
Domain Declaration  →  Projection  →  Resolved Input  →  Artifact
   (what constraints,   (engine         (merged: facts   (engine output,
    what merge strategy) prediction)     + projection    not Domain fact)
                                         + overrides)
                                                    ↓ (optional)
                                            Adoption Command
                                                    ↓
                                             Domain Fact
```

**Domain types (Phase 1 — done):**

- `EquinoxDomain.Port.Declaration` — serializable adapter intent: scope, hape discriminator, operate module, constraints, fallback.
- `EquinoxDomain.Port.Resolver.Operate` — behaviour with single callback `merge/2`. Shares contract with `OrchidIntervention.Operate`. Built-in implementations: `Override`, `Delta`, `Replace`.
- `Track.presets` + `Track.active_preset` added; declarations live on `Track.presets[active_preset]` (no longer on a slice entity). `note_phoneme_map` moved to the Kernel Projection layer.
- `Phoneme` reduced to pure identity `{symbol, type}` — timing moves to `TimedEvent` in resolved layer. Consonant preutterance (old `note_offset`) computed by duration calculate service at Projection stage.

**Pending (Phase 2 — Kernel):**

- `Equinox.Kernel.Param.Projection` / `Event.Projection` — shape-specific projection carriers.
- Resolver engine — consumes Declaration + Projection + Domain facts, produces Resolved Input.
- `RenderRequest` integration — wires data_channel slices + tempo_segments + adoption resolution into `Compiler.compile/1`.
- Legacy loader for old `%Segment{}` fields (`phoneme_map`, etc.).

**Key rules:**

- Engine outputs are artifacts — never Domain facts by default.
- Only explicit Adoption Commands convert artifacts into persistent, undoable Domain facts.
- Domain stores declarations and user-authored deltas; Kernel executes adapters and resolves.

### ADR-010 — Retire Utterance: Window + DataChannels + Artifact Pipeline

#### Summary

`Utterance` is retired. The pipeline becomes:

```text
Track.notes → Slicer.index/2 → [Window] → RenderRequest.from_window/3 → Kernel → Artifact → optional AdoptRequest → Track.data_channels
```

#### Core Decisions

**1. Window is the Slicer's sole output.**

- Transient, immutable, no persistent ID, never serialized.
- Regenerated from scratch on every Slicer run; no reconciliation logic.

**2. `Track.data_channels` is the sole persistence for all interventions.**

- User-drawn curves, adopted engine output, timing corrections — all stored as `LayerChunk`s keyed by `Channel.channel()`.
- Editing and adoption anchor to absolute tick ranges, orthogonal to Slicer windows.
- Re-running the Slicer never mutates `data_channels`.

**3. `RenderRequest.from_window/3` is the only Compiler entry point.**

- Slices `data_channels`, resolves adopted-over-user overlaps, pulls `tempo_segments` + `declarations`.
- `RenderRequest.from_utterance/3` is removed from the planned API surface.
- `tempo_segments` lives on `RenderRequest`; tick → physical-time conversion happens in Kernel/Compiler, never in UI.

**4. `Artifact` is the engine's temporary result container.**

- Engine output is an artifact — not a Domain fact by default.
- Used for UI display, diagnostics, diff, and user approval.
- Not serialized into the project file.
- Only explicit adoption writes it back to `Track.data_channels`.

**5. `EventSeq` is a rich domain model for `:event_sequence` payloads.**

- Contains `[TimedEvent.t()]` where each event holds `{at, duration, entity, metadata}`.
- `TimedEvent` anchors to the outer container (`LayerChunk.start_tick` or `Artifact.time_range`) via relative tick offsets.
- `EventSeq` owns its own validation, clipping, shifting, and rebasing — `LayerChunk` owns the outer time boundary.
- Domain checks structural legality only (non-negative durations, valid ordering, etc.). Adapter-specific semantics (phoneme validity, preutterance rules, cross-note constraints) are not Domain's responsibility.

**6. `Declaration.constraints` are opaque adapter config.**

- Domain stores them but never interprets them.
- Validation of constraint semantics belongs to the Adapter / Kernel plugin that registered the operate signature.

**7. Inference-time merge is plugin-owned.**

- How upstream projection + user intervention + adapter config are combined into a resolved input is decided by each Adapter/Plugin, not by Domain.

**8. Adoption conflict is user-decided.**

- When an `AdoptRequest` overlaps existing user/adopted data, the system must detect the conflict and surface it to the user.
- Domain does not silently resolve overlap. The user chooses a strategy (replace, keep, fill-gaps, manual merge, etc.) before data is written.
- The current `AdoptRequest.adopt/2` implementation that silently trims overlapping chunks is temporary and will be replaced by a conflict-aware two-phase flow.

**9. `Segment` retains only rendering-context fields.**

- `{track_id, start_tick, end_tick, core_start/end_sec, context_start/end_sec, phonemes, curves}`.
- `phonemes` and `curves` are Kernel compile-time caches, not serialized.
- Identity derives from `{track_id, start_tick, end_tick}` or RenderRequest content hash.

#### Supersedes / Consequences

- ADR-001 materialization clause: superseded. Slicer is a pure projection `Notes → [Window]`.
- ADR-002 wording: curves (and all time-varying interventions) derive alongside Windows, never owned by a persistent slice entity.
- ADR-009 Utterance-materialization clause: removed. `Track.presets` and the Declaration → Projection → Resolution pipeline are unaffected.
- **Rationale for retiring Utterance**: Utterance coupled the core domain to phonetics-backend assumptions (phoneme timing, G2P pipelines). Removing it moves phonetics-support code to external adapters/plugins, enabling multi-backend engine adaptation (DiffSinger, NNSVS, custom G2P, etc.) without domain changes.
- Session no longer maintains `utterance_id ↔ segment_id` mapping.
- Phase milestones referencing Utterance materialization (1b/1c) are updated to reference Window + DataChannels.

## 8. Do Not Do 💡

### Domain Red Lines (permanent)

- Do not let `EquinoxDomain.*` modules import, alias, or use anything from `Equinox.Kernel.*`, `Equinox.Session.*`, or `Equinox.Editor.*`. Domain is a zero-dependency project.
- Do not add `graph`, `cluster`, or `synth_override` fields to Domain structs. These are Kernel compile-time concepts; they belong in `RenderRequest` (ADR-006).
- Do not re-run `Slicer` implicitly during Editor note operations. Slicing is an explicit one-way projection: `Notes → [Window]` (ADR-001, ADR-010).
- Do not feed raw per-frame drawing samples into Editor or History. Simplify to control points first via Douglas-Peucker (ADR-003).

### Kernel Guidelines

The Kernel layer exists as a thin wrapper over Domain + runtime state management. It introduces no new business logic.

- GenServer usage in Kernel is limited to runtime state management only. No business logic in processes.
- Curve parameter semantics do not leak into Kernel. Never hardcode `:pitch`, `:energy`, or any specific param name (Hook territory, ADR-004).

## 9. Testing Guidelines

- **Domain (Elixir)**: Focus on pure unit tests (`ExUnit`). Avoid mocking in the `domain/` project since everything is pure data/functions. Use table-driven tests (or `Enum.each`) for matrix logic like `Slicer` edge cases.
- **Kernel (Elixir)**: Test stateful boundaries (e.g., GenServers) and integration with Domain types.
- **Frontend (Svelte)**: UI testing is deferred to Phase 3. For pure TS logic (e.g., math, formatting), use standard unit tests.

## Current Milestones & Focus

Current priority: **Phase 1a → 1b → 1c → 1d (Domain MVP) → Phase 2 (Domain-Kernel integration) → Phase 3 (UI Shell)**.

```
Phase 1a ─── Standalone Domain Models (domain/)
  Key.TwelveET, Note (pitch/duration/timing).
  Deferred: Curves rasterization/simplification (pending ADR-010 apply_intervention design),
  Tempo.Curve (reserved for Kernel NIF integration verification).

Phase 1b ─── Aggregate Roots (domain/)
  Track, Project, Phoneme linkage.
  Note CRUD at Track level.

Phase 1c ─── Slicer (domain/)
  Note.slice_flag, Slicer: Notes → [Window] projection,
  Track note CRUD with slice repair.

Phase 1d ─── Polish & Serialization (domain/)
  Editing commands, Session/RenderRequest, Pickle + comprehensive tests.

Phase 2 ──── Domain-Kernel Integration (kernel/)
  Replace legacy Domain types with the new domain project.
  Adapt Editor / Session / Compiler to Window + RenderRequest.
  Curve compilation pipeline.

Phase 3 ──── UI Shell Polish (ui_shell/)
  Arranger, History, Plugin System.
```

### Completed

> The following M0–M3 are early milestones that have been completed. Subsequent planning will uniformly use the Phase system.

1. ~~**M0 — Skeleton**: Umbrella scaffolded, Vite ↔ Phoenix wiring verified on Windows, `MockBridge` + `LiveBridge` both render an empty PianoRoll.~~
2. ~~**M1 — Piano Roll parity**: Port notes/viewport/grid from KinoBayanroll.~~
3. ~~**M2 — Node Editor parity**: SvelteFlow-based Synth editor, StepRegistry-driven palette, graph persistence via `Equinox.Project`.~~
4. ~~**M3 — Kernel compile/runtime decoupling**: `Compiler`, `Planner`, `Session.Context`, and OrchidStratum-backed session storage are wired into the render path.~~

**Completed sector list:**
- Core timeline: `Tick`, `TempoMap`, `Tempo.Step`, `Grid`
- Utilities: `Util.Model`, `Util.Object`, `Util.ID`, `Util.Pickle`, `Helpers`
- Score data structures: `Note` (partial), `Phoneme`, `Track` (skeletal, +`presets`/`active_preset`), `Project` (skeletal)
- VO: `Segment` (rendering context)
- Curve: `Curve.Chunk` (struct + adapter/container pattern); `Curve.Cluster` (skeletal); rasterization & simplification deferred (ADR-010 pending)
- Key: behaviour + Inner protocol + `Key.TwelveET` implementation — MIDI/frequency conversion complete; staff notation (`from_score`/`to_score`) deferred to post-MVP(signatures reserved, stubs return `{:error, :not_implemented}`)

### Phase 1a — Standalone Domain Models (domain/)
5. **Note (standalone)** — Note struct with duration, pitch, timing (`start_tick`, `duration_tick`). Pure value fields; no Track-level concerns.
6. **Timeline** — `TimeSigMap.compile/1`, `Tempo.Linear`. Musical time ↔ physical time conversion. `Tempo.Curve` deferred — reserved as a Kernel NIF integration verification point.
7. **Curves (pure data)** — `Curve.Chunk` (done). `Curve.Cluster` (skeletal — needs design clarification with `data_channel`). RasterCache, rasterizer, Douglas-Peucker simplification: **deferred** — these plug into ADR-010's `apply_intervention` / `apply_approve` flow, which needs further design before implementation.

### Phase 1b — Aggregate Roots (domain/)
8. **Track** — Notes map (`%{note_id => Note.t()}`) + `data_channels: %{channel => [LayerChunk]}`. Note CRUD at Track level (insert, delete, split, merge, update). **Blocked**: `data_channel` ↔ `notes` relationship needs design clarification before Track operations can be finalized.
9. **Project** — Tracks map + project-level metadata. Track CRUD. **Blocked on Track completion**.
10. **Phoneme** — Phoneme is a pure identity VO (`symbol`, `type`); timing lives in `TimedEvent` (ADR-009). Slicer-produced `Window` determines rasterization boundaries.

### Phase 1c — Slicer (domain/)
11. **Slicer** — `Note.slice_flag` (`:auto | :force_slice | :force_merge`). Rest-gap slicing. `Notes → [Window]` projection. No materialization step — Window is transient.
12. **Track slice repair** — After insert/delete/split/merge/update, auto-repair `slice_flag` in affected interval. **Blocked on Track note CRUD**.
13. **Segment** — Rendering context VO: acoustic boundaries, `phonemes`/`curves`. The Domain defines the struct; fields are populated by the Kernel at compile time and do not participate in serialization (see ADR-007).

### Phase 1d — Polish & Serialization (domain/)
14. **Editing commands** — `Command.Editing` (DragNote, ResizeNote, EditLyric, SplitNote, MergeNotes, AddTrack, DeleteTrack) + command stack for undo/redo. **Blocked on Track + Project CRUD**.
15. **Session / RenderRequest** — `Session` (selection, clipboard, viewport) — **manual review in progress**; `Command.RenderRequest` done.
16. **Pickle + comprehensive tests** — **暂缓。** 当前三层 Pickle 协议（`Pickle` / `Pickle.Pure` / `Pickle.Plugable`）过度设计了——只有 `Tick`、`Key`、`Tempo` 事件有实现，而核心聚合根（`Project`、`Track`、`Note`）反而没接。建议方向：
    - Phase 1d 只需做一个最简单的 Jason JSON 序列化——`Util.Model` 已自动生成 `new/1`，直接用 `Jason.Encoder` derive 就能持久化 Project/Track/Note。
    - `Pickle.Plugable` 的 scope/signature dispatch 机制（envelope 格式 + registry）暂时搁置，等引擎接口（`data_intervention` 契约、`AdoptRequest` 回写格式）明确后再决定是否需要这么复杂的 layer。
    - Curve 类型的序列化同样 **deferred** pending curve model stabilization。

### Phase 2 — Domain-Kernel Integration (kernel/)
17. **Domain dependency**: Add `:equinox_domain` to kernel, delete legacy `Equinox.Domain.*`, replace all references.
18. **Slicer → Window**: Rewrite Slicer for new `slice_flag` model; Window-based slicing replaces `materialize_segments`.
19. **Track API**: `insert_note`, `delete_note`, `split_note`, `merge_notes`, `update_note` with automatic slice repair.
20. **RenderRequest + AdoptRequest**: Introduce `RenderRequest` as Compiler's sole input (replaces SegmentContext). `RenderRequest.from_window/3` slices `data_channels`, resolves adopted-over-user overlaps, and pulls tempo_segments + declarations. `AdoptRequest.adopt/2` writes engine output back to `Track.data_channels` as `:adopted` LayerChunks.
21. **Editor / Session adaptation**: Editor ops → Track API. Session manages selection, clipboard, and viewport state.

### Phase 3 — UI Shell (ui_shell/)
22. **Arranger**: Second SvelteFlow canvas, multi-track mix, slice/utterance alignment, slice-aware editing affordances.
23. **History & Collaboration hooks**: Session-level undo/redo; design space for future CRDT.
24. **Plugin System**: Runtime dynamic loading of custom Synth Nodes.
    - Frontend: WebComponent wrapping for SvelteFlow, third-party UI `.js` via dynamic `<script type="module">`.
    - Backend: Distributed Erlang — isolated BEAM `Engine Node` per Session for Orchid graph execution, hot-load `.beam` modules without risking the Phoenix `Web Node`.

## Slicer Semantics

### Slicer Scenarios

- **Continuous Notes Import**: MIDI/ustx import produces dense note sequences. Default behavior: derive initial slice boundaries from rest-gap detection (`min_rest_ticks` threshold). This covers the majority of initial modeling.
- **Manual Override**: User can explicitly mark a note with `:force_slice` or `:force_merge`, overriding automatic derivation.
- **Edit Repair**: After split/merge/drag/time-change operations, locally recalculate and repair `slice_flag` to ensure slices don't dangle or overlap.
- **Window Semantics**: Slice semantics are note-level; `Window` is a transient projection — never a persisted entity. User interventions write to `Track.data_channels` as `LayerChunk`s, orthogonal to Slicer windows. 💡

### `slice_flag` Design

Define `slice_flag` on `EquinoxDomain.Score.Note` as:

```elixir
@type slice_flag :: :auto | :force_slice | :force_merge
```

- `:auto`: default; Slicer decides boundaries via rest-gap detection.
- `:force_slice`: force a slice boundary at this note's start (equivalent to the next note being `{:on_start, new_id}`). A single `:force_slice` note forms a standalone utterance.
- `:force_merge`: prevent a slice boundary even if a rest gap exceeds the threshold.

The Slicer produces `Window` structs — transient time-window descriptors. `Window` is never persisted; it flows directly into the Compiler for preview/playback. The rendering engine works with `Window` + curve slices via `RenderRequest`; it does not need to understand the Note domain model.

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

### Data Flow

1. [auto] Track edits update `track.notes` with repaired `slice_flag`.
2. [auto] Slicer produces `Window` structs: `Notes → [Window]`.
3. [auto] `Window`s flow into `RenderRequest.from_window/3` → `Compiler.compile/1` for preview/playback.
4. [explicit] User interventions (curve strokes, engine output adoption) write to `Track.data_channels` as `LayerChunk`s — orthogonal to Slicer windows.
5. [auto] On re-slice, new `Window`s are generated from scratch; `data_channels` survive unaffected.
6. [auto] Compiler renders from `RenderRequest` (which carries `Window` note_ids + `data_channels` slices) — `RenderRequest` determines rasterization boundaries for phonemes and curves.

## Curves

Split into Phase 1 (domain) and Phase 2 (kernel integration).

### Goals

1. Continuous parameter curves become a first-class, **Track-scoped** data layer.
2. Window is the Slicer's transient output (`note_ids`, `tick_start`, `tick_end`); Segment is a pure rendering context VO.
3. Compiler becomes the sole translator from `Curve.Cluster` → `data_intervention`.
4. Kernel stays semantics-agnostic about individual curve parameters; consumption is Orchid Hook territory.

### Data Structures (matching domain project)

- `EquinoxDomain.Curve.Chunk`: `{id, start_tick, end_tick, control_points, rasterized | nil, source, extra}`. Control points carry `(tick, value, kind, tension)`.
- `EquinoxDomain.LayerChunk`: `{start_tick, end_tick, payload, source :: :user | :adopted}`. Unified time-slice container for curves and adopted data. Lives in `Track.data_channels`. Within the same channel, `:adopted` chunks override `:user` chunks on overlapping intervals.
- `EquinoxDomain.Curve.RasterCache`: `{stride, samples :: binary, fingerprint}`. Rebuildable from control points; never serialized.
- `EquinoxDomain.Command.RenderRequest`: `{notes, time_range, tempo_segments, data_slices, declarations}`. The only struct passed into `Compiler.compile/1`. Constructed via `from_window/3` or `from_utterance/3`.

### Segment Shrinkage

After curves integration, `%EquinoxDomain.Segment{}` retains only rendering-context fields: `track_id, start_tick, end_tick, core_start_sec, core_end_sec, context_start_sec, context_end_sec, phonemes, curves` (the `phonemes` and `curves` fields are populated by the Kernel at compile time and are not serialized).

Removed from Kernel's legacy Segment: `curves`, `synth_override`, `graph`, `cluster`. These move to `RenderRequest` (compile-time) or `Track.data_channels`.

### Curve Facade API Additions

- `apply_curve_stroke(project, track_id, param, %Chunk{})`: atomic insertion of a completed stroke. Emits history entries.
- `erase_curve_range(project, track_id, param, start_tick, end_tick)`: erase within a range.
- `clear_curve_layer(project, track_id, param)`: wipe a whole layer.

Strokes are assumed already-simplified control-point chunks (see ADR-003). The Editor does **not** accept raw sample arrays.

### Compiler Integration

1. Caller builds one `RenderRequest` per `Window` via `RenderRequest.from_window/3`, which slices `data_channels`, resolves adopted-over-user overlaps, and pulls tempo_segments + declarations.
2. `Compiler.compile/1` dispatches data_slices to `data_interventions`, keyed by `PortRef`. The `PortRef → Orchid key` translation reuses existing `Graph.PortRef.to_orchid_key/1`.
3. Payload shape given to the Hook:
   ```text
   %{param: atom(), start_tick: non_neg_integer(), end_tick: non_neg_integer(),
     stride: pos_integer(), samples: binary()}
   ```
4. No `param_name` is privileged inside Kernel code.

### Phase 1 — Domain

Pure data modules inside `domain/`, no impact on Kernel:

- [x] Add `EquinoxDomain.Curve.Chunk` (struct + adapter/container pattern).
- [x] Add `EquinoxDomain.LayerChunk` + unit tests.
- [ ] Add `EquinoxDomain.Curve.RasterCache` + rasterizer — **deferred**: plugs into ADR-010 `apply_intervention` / `apply_approve` flow.
- [ ] Add stroke-simplification helper (Douglas-Peucker) — **deferred**: same as above.
- [x] Add `data_channels` field to `EquinoxDomain.Score.Track`, default `%{}`.
- [ ] Implement `Pickle` serialization for all curve types — **deferred**: pending curve model stabilization.

Each step ends on a green `cd domain && mix precommit`.

### Phase 2 — Kernel Integration

After Domain is stable:

- [x] Introduce `EquinoxDomain.Command.RenderRequest` (wraps notes + time_range + tempo_segments + data_slices + declarations; `from_window/3` done).
- [x] Add `EquinoxDomain.Command.AdoptRequest` + `adopt/2` — basic implementation done (silent overlap trim); conflict-aware two-phase flow pending (see ADR-010).
- [ ] Remove `curves`, `synth_override`, `graph`, `cluster` from legacy `%Segment{}` and its `Jason.Encoder` impl.
- [ ] Add legacy-tolerant loader in `Project.from_json/1` for old payloads.
- [ ] Update `Session.Context.dispatch_to_plans/1` to build `RenderRequest` per Window via `RenderRequest.from_window/3`.
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

Kernel does not ship a reference Hook. Curves integration delivers the contract and payload shape; the first concrete Hook lives outside Kernel (userland or a sibling package).

## 10. Known Issues (kernel scope — address during Phase 2)

Ordered roughly by priority; do not fix opportunistically without a matching commit plan.

1. `Track.remove_segment/2` and `Project.remove_track/2` fail silently — contract mismatch.
2. `Editor.add_note/4` hard-matches `{:ok, _} = Track.update_segment(...)` — violates error handling convention.
3. The comments in the `Equinox.Editor.*` module are all in English (likely a legacy of early AI generation), while the comments in other modules are in Chinese. In Phase 2, they will all be in Chinese.
4. `Session.Server.handle_info/2` only handles task success; failures get swallowed by `Logger.warning("unknown message")`.
5. `StepRegistry` startup ordering: `Supervisor.start_link` then `register_builtin_steps` — works but not clean.
6. `Compiler.compile_cache` typespec disagrees with actual shape.
