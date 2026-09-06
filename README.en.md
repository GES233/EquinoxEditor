![icon](artwoks/icon_dark.svg)

# Equinox

[简体中文](README.md)

**Equinox** is a singing-synthesis editor built on the **Neume** kernel. Neume names both the editing paradigm — the Tamale/Coconut edit model (History, pin interventions, check/repatch discipline) — and its Elixir implementation: the kernel apps of this repository (`apps/coconut`, `apps/coconut_oi`, `apps/neume`, `apps/neumu`), which perform DiffSinger analysis and rendering through Oi pipelines.

## Umbrella Layout

- `apps/coconut`: the source of truth for edit state, History, Patch, Resolve and serialization; imported from the formerly standalone Coconut repository and now maintained inside this umbrella.
- `apps/coconut_oi`: a thin adapter that only translates Coconut interventions to the Oi data/execute boundary.
- `apps/neume`: the singing engine, probe/alignment, windowed cache and artifacts; multi-track scheduling, mixing, buses and export aggregation are also implemented as Oi graphs/steps declared here.
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

For Neume usage, the real DiffSinger environment and current limitations, see [`apps/neume/README.md`](apps/neume/README.md) and the Neume Implementation Status section in [`AGENTS.md`](AGENTS.md).
