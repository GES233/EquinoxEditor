# AGENTS.md

## Project Status

Equinox is a Mix umbrella for the second Neume iteration. The active product is currently a headless singing-synthesis editor and render kernel; there is no active Phoenix/Svelte UI shell in this branch.

The source of truth for implementation status is `apps/neume/STATUS.md`.

## Repository Layout

- `apps/coconut/` — engine-agnostic editor core. It owns score/edit state, History, Patch/Resolve, and persistence. It was imported from the archived standalone Coconut repository and is now maintained as part of this umbrella.
- `apps/coconut_oi/` — intentionally small bridge from `Coconut.Render.Engine` requests and interventions to Oi data and `Oi.execute/2`.
- `apps/neume/` — product and engine layer: editor facade, DiffSinger scanning, probe/alignment, inference, windowed cache, debug export, and render artifacts.
- `config/` — shared umbrella configuration.

The repository must build without sibling Coconut or CoconutOi checkouts. Tamale, Oi, and Orchid packages remain external dependencies resolved by Mix.

## Architecture Boundaries

```text
Coconut (edit/history/patch/persistence)
        ↓
CoconutOi (intervention-to-Oi translation only)
        ↓
Neume Oi graphs and engine steps
        ↓
DiffSinger worker / ONNX / artifacts
```

- Coconut must remain engine-agnostic. Do not add DiffSinger, Oi graph, playback, mixing, or UI semantics to it.
- CoconutOi must remain a thin adapter. Do not add engine compilation, phoneme alignment, track scheduling, mixing, buses, playback, or export management to it.
- Multi-track scheduling, mixing, buses, and export aggregation are implemented as Neume-owned Oi graphs/steps.
- Phoneme types, frame grids, G2P, vowel anchoring, and model probes belong to the Neume DiffSinger adapter/worker.
- Coconut History remains the only entry for persistent score, patch, track-extras, and undoable edits.
- Model paths, generated models, caches, and WAV files are not committed.

## Development Rules

- Use forward slashes in portable documentation and commands where practical.
- Search before acting; do not assume paths from the previous Equinox architecture.
- Source code, comments, and project documentation are written in Chinese unless an external contract requires otherwise.
- Return tagged results for expected failures instead of raising at public boundaries.
- Preserve exact/canonical values at Tamale-facing boundaries; do not feed raw floats into anchors or digests.
- Do not revive code from CoconutIntervention wholesale. Extract only behavior required by the current production path, place it in the owning app, and cover it with focused tests.

## Dependencies

Umbrella apps use `in_umbrella: true`:

```elixir
{:coconut, in_umbrella: true}
{:coconut_oi, in_umbrella: true}
```

Do not replace these with sibling checkout paths. Keep one resolved version/source for Tamale, Oi, and Orchid dependencies across the umbrella.

## Validation

From the repository root:

```powershell
mix deps.get
mix deps.tree
mix compile --force --warnings-as-errors
mix test
mix format --check-formatted
mix dialyzer
git diff --check
```

Neume real-voicebank tests are excluded by default. Run them explicitly only with the required external voicebank and Python environment:

```powershell
cd apps/neume
mix test --include integration test/neume/diff_singer_integration_test.exs
```

Python worker tests must run from `apps/neume/priv/diffsinger` with the inference dependencies installed.

## Current Product Direction

The headless single-track real DiffSinger loop is complete. Current product gaps include voicebank discovery/registration, multi-track Oi scheduling and mixing, playback/export management, and an interactive editor UI. Do not implement these concerns in CoconutOi merely because it sits near the Oi boundary.
