# Editor Mental Model

## Status

> **Outdated object model, still relevant intent**: This document describes the pre-coconut migration object model where `Segment` was a persistent render container. The current implementation runs on coconut + tamale: `EquinoxDomain.Score.Project` wraps `Coconut.Edit.Workspace` plus a `tracks_meta` side table, phrase windows are transient `EquinoxDomain.Windowing.Window` projections, and user/engine edits are `Coconut.Edit.Patch` anchored by tamale anchors. The sections below retain the *interaction intent* (Track-centered, per-window focus, graph-configurable synthesis), but the concrete object ownership should be read through `AGENTS.md` §7 and `docs/coconut-migration.md`.

This document defines the default object model and interaction model for Equinox during the M3 stage.
It is intended to constrain future implementation, not to describe every possible advanced workflow.

## Core Statement

Equinox is a track-centered vocal synthesis editor.

- `Track` is the default user-facing object.
- `Window` is a transient per-track phrase projection used for incremental render dispatch; it is not a persisted domain object.
- `Segment` (in the current code) is a rendering-context value object populated by the Kernel at compile time; it carries acoustic boundaries and resolved phonemes/curves for one window, but is not a container that owns notes.
- An Arranger entry node is the Arranger-side projection of a `Track`, not a separate domain object.
- Node graphs are configuration surfaces for synthesis and routing, not the primary timeline object model.

## Object Model

### Project

`Project` owns global timing and top-level routing.

Responsibilities:

- global tempo map
- ticks-per-beat settings
- track collection
- project-level routing or bus graph
- future session-wide history entry points

`Project` should not own note-level editing state.

### Track

`Track` is the primary editing object and the main unit of user selection.

Responsibilities:

- identity, label, color, type
- mixer parameters such as mute, solo, gain, pan
- default synthesis configuration
- ordered collection of notes (spans live in the coconut workspace, not on a `Segment` container)
- view metadata for Track projections, such as arranger node position

`Track` is the object selected from TrackList, represented in Arranger, and configured in the default Node Editor view.

### Window / Segment

`Window` is a transient phrase projection derived from a Track's notes + spans + `slice_flag` metadata. It is computed from scratch after every edit and is used only to batch notes for render dispatch. See `EquinoxDomain.Windowing`.

`Segment` (current code) is a rendering-context value object produced by the Kernel for one window at compile time. It carries:

- acoustic boundaries (`start_tick`, `end_tick`)
- resolved phonemes and curves for that window

It is **not** a container for notes, nor a persisted identity. Notes live in the coconut workspace; windows are recomputed; segments are runtime output.

### Arranger Entry Node

An Arranger entry node is a view of a `Track` in the routing and mix context.

It must not introduce a second state container for the same musical object.

Rules:

- entry node `id` should map directly to `track_id`
- node-level mute or solo must write back to `Track`
- purely visual node placement should live in view metadata, not duplicate Track identity

## Two-Stage Signal Flow

Track audio should be understood in two stages.

### Stage 1: Synthesis

This stage converts symbolic musical data into track-local audio.

```text
Track notes / lyrics / curves / patches
  -> windowing (transient Window projection)
  -> per-window synthesis
  -> window audio
  -> track assembly
  -> track dry audio
```

Primary ownership:

- The coconut workspace owns symbolic inputs (notes + spans + patches).
- `Track` owns the default synth graph or synth provider configuration.
- A window may carry a local synthesis override only when required.

### Stage 2: Mixing and Routing

This stage processes track audio streams after synthesis.

```text
track dry audio
  -> track FX / gain / pan / sends
  -> arranger routing / buses
  -> master output
```

Primary ownership:

- `Track` owns track-level mixer parameters and insert FX
- `Project` owns cross-track routing, buses, and master output structure

## Graph Types

Equinox should not overload one generic `graph` concept for every layer.

At minimum, the editor model should distinguish between:

### Synth Graph

Purpose:

- transform symbolic track/window data into audio

Typical scope:

- default scope is `Track`
- optional override scope is a per-window render context (not a persisted Segment identity)

Examples:

- phonemizer
- acoustic model
- vocoder
- singer-specific control modules

### Mix or Routing Graph

Purpose:

- transform or route audio streams that already exist at Track level

Typical scope:

- `Project` for track-to-bus-to-master routing
- `Track` for inserts, gain, pan, sends, and local FX chains

Examples:

- track insert FX
- bus routing
- master chain

## Default Selection Model

The editor should behave as if selection always has a current Track context.

### Default Rules

- selecting a Track in TrackList sets the global editing context
- selecting an Arranger entry node selects that same `Track`
- focusing a window/phrase refines focus within the selected `Track`
- Piano Roll edits the notes of the selected `Track` (scoped to the focused window for convenience)
- Node Editor defaults to editing the selected `Track`'s synth configuration

### Consequence

The Arranger should not compete with the Node Editor for semantic ownership of Tracks.
Arranger is about placement, routing, and mix context.
Node Editor is about synthesis configuration or explicit override editing.

## Override Rules

Overrides must remain exceptional and local.

### Track Defaults

By default, a `Track` provides:

- synth graph or synth provider
- track-level mixer parameters
- track-level insert FX

### Window Overrides

A window-level render context may override:

- selected synthesis parameters
- selected synthesis nodes
- limited intervention data for incremental generation

A window override should not casually replace the entire track mix context.

### Project Overrides

`Project` may define:

- routing topology
- buses
- master processing

`Project` should not directly own per-segment symbolic editing state.

## Invalidation Rules

Incremental execution should follow user intent.

### Window-Scope Changes

Examples:

- note move inside a window
- lyric edit
- phoneme edit
- curve edit

Expected invalidation:

- dirty only the affected transient window
- rerun that window's synthesis path
- rebuild downstream Track assembly as needed
- rerun downstream mix stages that consume the updated Track output

### Track Synth Changes

Examples:

- changing the default synth graph
- swapping singer or provider
- editing Track-level synthesis parameters

Expected invalidation:

- dirty relevant windows in that `Track`
- rerun synthesis for affected windows
- preserve unrelated Tracks

### Track Mix Changes

Examples:

- gain
- pan
- mute
- solo
- insert FX settings

Expected invalidation:

- do not rerun per-window synthesis
- rerun Track mix stage and downstream routing only

### Project Routing Changes

Examples:

- bus routing
- master chain changes
- track-to-output assignment

Expected invalidation:

- do not rerun per-window synthesis
- do not rebuild unrelated Track dry renders
- rerun affected bus and master stages only

## UI Surface Responsibilities

### TrackList

Primary role:

- choose current `Track`
- expose basic Track controls

Typical controls:

- name
- color
- mute
- solo
- maybe arm or monitor in future

### Arranger

Primary role:

- show Track participation in global time and routing

Responsibilities:

- window/phrase placement in timeline context
- track ordering in song structure
- Track entry nodes as mix inputs
- bus and output routing

Arranger is not the canonical owner of Track identity.

### Piano Roll

Primary role:

- edit symbolic content of the selected `Track` (often scoped to a focused window for convenience)

Responsibilities:

- note editing
- lyric editing
- pitch and control curves
- window-scoped musical manipulation

### Node Editor

Primary role:

- edit synthesis or routing configuration for the current scope

Default scope:

- selected `Track`

Advanced scope:

- per-window synthesis override
- project-level routing or bus graph if explicitly switched

## Practical Data Direction

The current codebase should gradually converge toward a shape like this:

```text
Project
  workspace :: Coconut.Edit.Workspace   # notes, spans, tempo, patches
  tracks_meta: %{track_id => TrackMeta}  # mix, voicebank, globals, ui_state
  arranger_graph: track and bus routing

Track (user-facing + meta side table)
  id
  name
  type
  mix_params
  insert_fx_chain
  synth_graph or synth_ref
  ui_state: arranger projection metadata

Window (transient projection)
  start_tick
  end_tick
  note_ids

Segment (runtime rendering-context VO, populated by Kernel)
  start_tick
  end_tick
  phonemes
  curves
```

This is a target shape, not a mandatory immediate refactor. Notes are not owned by `Segment`; they live in the coconut workspace and are projected into windows on demand.

## Non-Goals

The following should not become the default model:

- every view inventing its own object identity
- Arranger nodes and Tracks drifting into duplicated state
- `Segment` (or `Window`) becoming the primary editor object for all workflows
- one generic graph type owning synthesis, mixing, routing, and timeline semantics at once

## Working Summary

Equinox should behave like a DAW-shaped vocal editor:

- Track-centered at the interaction level
- Window-granular at the synthesis and cache level
- graph-configurable at the synthesis and routing level

This keeps the user model stable while still allowing Orchid-based incremental execution under the hood.
