
## Agent Work Log

### 2026-04-17 (M0/M1 Data Architecture)
- **Restructured Core Domain (Pure Data)**: Removed Ecto schemas from `Equinox.Project`, `Equinox.Editor.Track`, `Equinox.Editor.Segment`. Converted them to strictly JSON-serializable pure Elixir structs using `Jason.Encoder`.
- **Global History & Clean Segments**: Explicitly removed `history` from `Segment` (history will be managed at the Project/Editor level). `Segment` no longer serializes its runtime `graph` or `cluster`, retaining only `notes` and `curves` (Pure Data) for storage and hash calculation.
- **Project Serialization**: Added symmetric `Project.to_json/1` and `Project.from_json/1` for full recursive hydration of `project.json` in the bundle architecture.
- **App Structure Fix**: Removed the incorrect `apps/` umbrella folder convention and aligned `AGENTS.md` with the actual standard Phoenix structure (`lib/equinox`, `lib/equinox_web`).
