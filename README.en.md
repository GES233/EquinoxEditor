![icon](artwoks/icon_dark.svg)

# Equinox

[简体中文](README.md)

**Equinox** is a singing-synthesis editor built on the **Neume** kernel. Neume names both the editing paradigm — the Tamale/Coconut edit model (History, pin interventions, check/repatch discipline) — and its Elixir implementation. Concrete synthesis runtimes plug into that kernel; `apps/neume_opu_ds` currently performs OpenUTAU DiffSinger analysis and rendering through Oi pipelines.

## Umbrella Layout

- `apps/coconut`: the source of truth for edit state, History, Patch, Resolve and serialization; imported from the formerly standalone Coconut repository and now maintained inside this umbrella.
- `apps/coconut_oi`: a thin adapter that only translates Coconut interventions to the Oi data/execute boundary.
- `apps/neume`: stable editing, pin identity/adjudication and runtime/provider contracts, plus generic windowing, caching, mixing and artifact semantics.
- `apps/neume_opu_ds`: OpenUTAU DiffSinger scanning, probe/alignment, Pure-FP, Python worker and synthesis Oi graphs.
- `apps/neumu`: an OTP application service over Neume — per-project `ProjectServer` processes, async rendering, runtime artifact store, and a UI-facing facade. `apps/neume_lab` is a Livebook/Kino development bench, not the product UI.

The project no longer depends on sibling Coconut or CoconutOi checkouts.

## Validation

```powershell
mix deps.get
mix compile --force --warnings-as-errors
mix test
mix format --check-formatted
mix dialyzer
```

For Neume boundaries, see [`apps/neume/README.md`](apps/neume/README.md). For the real DiffSinger environment, see [`apps/neume_opu_ds/README.md`](apps/neume_opu_ds/README.md). Current limitations remain in the Neume Implementation Status section of [`AGENTS.md`](AGENTS.md).
