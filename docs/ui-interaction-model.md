# UI Interaction Model

## Status

> **Outdated object references, still relevant interaction intent**: The interaction loops below describe the *intent* (Track-centered, debounced commits, explicit empty states), but object-model references (`Segment` as render unit, `current_segment_id`, tick-anchored edits) predate the zongzi/coconut migrations. The domain now runs on coconut (`Coconut.Edit.Workspace` + `Track` + patches, transient `EquinoxDomain.Windowing` windows, tamale anchor/digest conflict surfacing via `History.take_dead_patches/1`). Read `AGENTS.md` §7 and `docs/coconut-migration.md` as the current source of truth. Replace `Segment` / `current_segment_id` in this document with `Window` / `current_window_id` (or simply "focused phrase inside the current Track") when reading.

This document defines the intended interaction model for Equinox as a track-centered editor.
It complements `docs/editor-mental-model.md` and focuses on user-facing behavior rather than data ownership.

## Core Principle

Equinox should feel like a vocal editor with DAW-shaped interaction, not a generic graph editor with music widgets attached.

The primary user loop is:

```text
select Track
  -> focus window/phrase
  -> edit notes and curves
  -> adjust Track synth or mix settings
  -> render current Track or Project
```

## Global Editor Context

The UI should always maintain an explicit editor context.

Minimum fields:

```text
current_track_id
current_window_id / current_phrase_id
current_scope
```

Where `current_scope` is one of:

- `:track`
- `:window` / `:phrase`
- `:track_synth`
- `:project_mix`

This context is the source of truth for which object the user is editing.

## Selection Hierarchy

Selection is hierarchical, not flat.

### Track Selection

`Track` is the default root selection object.

Effects of selecting a Track:

- Track becomes the active editing context
- Piano Roll switches to that Track's active Segment
- Node Editor switches to that Track's synth graph
- Inspector panels should show Track-level data by default

### Window / Phrase Focus

`Window` is a focused transient child of the selected Track.

Effects of focusing a window:

- Piano Roll edits notes within that window (when the UI chooses to scope)
- timeline highlights that window
- Node Editor does not automatically switch away from Track-level synth editing unless the user explicitly enters override mode

### Graph Scope

Graph editing scope must be explicit.

Default:

- Node Editor edits Track synth configuration

Advanced:

- user may switch Node Editor into Segment override mode
- user may switch a separate routing editor into Project mix mode

The UI should never make graph scope ambiguous.

## Primary Views

### TrackList

TrackList is the most literal source of Track selection.

Responsibilities:

- select active Track
- rename Track
- basic mute and solo
- color and type visibility
- future add, duplicate, delete operations

Single click on a Track row:

- sets `current_track_id`
- keeps current Segment if it belongs to that Track
- otherwise chooses that Track's default Segment

### Arranger

Arranger is the global song and routing view.

Responsibilities:

- show windows/phrases in musical time
- show Track participation in song structure
- show Track routing into output or buses
- allow Track selection through Track entry nodes

Single click on a Track node:

- selects the Track

Single click on a window/phrase block:

- selects the Track
- focuses the window

Double click on a window/phrase block:

- selects the Track
- focuses the window
- moves user attention to Piano Roll editing

Dragging a window/phrase block:

- updates window placement in time (slice_flag / note move, depending on implementation)
- should be optimistic in UI
- commits after drag end

Dragging a Track node:

- updates only arranger projection position
- must not mutate Track identity or routing semantics by itself

### Piano Roll

Piano Roll is the symbolic editing surface for the active Segment.

Responsibilities:

- note timing
- pitch
- lyric editing
- phoneme display or editing
- curves inside the focused window/phrase

If no window/phrase is focused:

- Piano Roll should show an empty state, not silently edit the first window in the project

Creating notes:

- attaches notes to the selected Track (within the focused window when the UI scopes)

Dragging notes:

- optimistic update during drag
- debounce or commit on drag end

Editing lyrics or phonemes:

- debounce before backend sync

### Node Editor

Node Editor is not the default navigation surface.
It is a configuration surface for synthesis.

Default behavior:

- show the selected Track's synth graph

Optional behavior:

- show a window/phrase-level override graph only when user explicitly enters override mode

The header should always make current graph scope obvious.

Examples:

- `Track Synth · Main Vocal`
- `Window Override · Chorus 1`

### Inspector

Even if not implemented yet, the future inspector should be context-driven.

When `current_scope == :track`:

- show Track name, color, mute, solo, gain, pan

When `current_scope == :window` / `:phrase`:

- show window/phrase start, end, and local metadata

When `current_scope == :track_synth`:

- show synth parameters for the Track graph or provider

## Interaction Rules

### Rule 1: Selection Must Be Visible

The UI should always show:

- which Track is selected
- which window/phrase is focused
- which editor scope is active

No view should operate on hidden implicit context.

### Rule 2: Selection Changes Are Cheap

Changing Track or window/phrase selection should be immediate and local.
It should not require render or graph recompilation.

### Rule 3: Editing Follows Focus

Only the focused window/phrase is editable in Piano Roll.
Only the selected Track is editable in default Node Editor mode.

### Rule 4: Views Coordinate Through Context

Views should not infer context independently.
They should consume the shared editor context.

Bad:

- Piano Roll picks the first Track by itself
- Node Editor hardcodes `track_1`
- Arranger invents a separate Track identity

Good:

- Arranger updates selection
- shared context changes
- Piano Roll and Node Editor react to that context

## Commit Model

Different interactions should commit differently.

### Immediate Commit

Use for:

- selection changes
- button toggles like mute or solo
- explicit mode switches

### Debounced Commit

Use for:

- lyric edits
- note collection edits during rapid interaction
- curve edits
- parameter typing

### Commit On End

Use for:

- drag move end
- resize end
- node move end
- connect or disconnect end

This keeps the UI responsive without turning every mousemove into backend traffic.

## Default Empty-State Logic

The UI must avoid silent fallback behavior that edits the wrong object.

If there is no Track:

- show create-first-track empty state

If there is a Track but no window/phrase focused:

- show create-first-window/phrase empty state in Piano Roll

If there is no graph:

- Node Editor should show an empty graph state for the selected Track, not pretend another Track is active

## Render Actions

Render actions should be scoped and named clearly.

Recommended commands:

- `Render Window/Phrase`
- `Render Track`
- `Render Project`

Default toolbar action should likely be `Render Track` if Track is the primary object.

## Recommended First Implementation Pass

The next UI pass should not aim for completeness.
It should only make the core interaction loop coherent.

### Pass 1

- explicit editor context store or LiveView assigns
- Track selection from Arranger and TrackList
- window/phrase focus from Arranger
- Piano Roll bound to focused window/phrase
- Node Editor bound to selected Track

### Pass 2

- clear scope indicator in Node Editor
- commit semantics for drag versus text edits
- empty states instead of implicit first-item fallback

### Pass 3

- window/phrase override mode
- inspector panel
- render scope commands

## Working Summary

The intended behavior is simple:

- user thinks in Tracks
- user edits one window/phrase at a time
- user configures synthesis at Track scope by default
- all panels stay synchronized through explicit shared context

If this remains true, the editor will feel coherent even while the backend is still evolving.
