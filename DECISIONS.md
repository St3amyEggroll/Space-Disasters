# DECISIONS

This file records the Phase 0 spike results and every deviation from the build spec, with the reason for each.

---

## Deviations and clarifications

### D1. Body and site display names (Steamy's request)
The game is called **Space Disasters**. The names are meant to be silly but still cool:

| Code name | Display name |
|---|---|
| Sun | Big Toasty |
| Homeworld | Kablamo |
| Moon | Dent |
| Base site | Oopsie Point Launch Complex |

Code, packets and ids still use `Sun` / `Homeworld` / `Moon` (ids 0/1/2), so renaming later only means editing `Config/Bodies.luau`.

### D2. UT anchors live in one string attribute
The spec says the UT anchors and the warp rate are attributes on `ReplicatedStorage.Globals`. They are, but as **one** string attribute: `TimeAnchors = "<utAnchor>|<serverTimeAnchor>|<warpRate>"`, formatted with `%.17g` so the values are exact doubles.
- **Reason:** three separate attributes can replicate as a half-updated set for a frame, and UT would jump during a re-anchor. One attribute changes atomically.
- **Where:** `UniverseTime.encode/decode`. Tests cover the round trip.

### D3. `Shared/Util/Loader.luau` (new file, not in the Section 4 layout)
The Init/Start loader is shared by both bootstraps, so it lives in `Shared/Util`.
- It warns about any module in `Services`/`Controllers` that is missing from `BOOT_ORDER`.
- A module that fails to load or `Init` is skipped, and the failure is logged loudly.

### D4. Phase 0 ground plate and spawn come from the project file
`Workspace.BaseGround` (a 2048 × 20 × 2048 plate, top at y = 0) and `Workspace.BaseSpawn` are defined in `default.project.json`. That satisfies "players spawn in the base pocket (slot 0)" and "the base has a server-side ground plate" from day one. Phase 1 folds them into the base pocket / HomeBase site.

### D5. `Lighting.Technology` can't be synced by `rojo serve`
The live-sync plugin writes properties with script permissions, and scripts can't set Technology. The workflow is therefore `rojo build -o SpaceDisasters.rbxl` once, which bakes in every project property, then `rojo serve` for code. The spike place works the same way: `spikes.project.json` includes its own baseplate, spawn, Sky and Atmosphere, so it builds standalone.

### D6. Phase 2 is split into 2a and 2b (agreed with Steamy)
- **2a:** flight model, launch transfer, pocket rendering, staging, debris, crashes.
- **2b:** parachutes, legs, landing rebase, recovery.

### D7. Offline toolchain and CI (additive)
- `tools/setup.sh` + `tools/check.sh` run stylua, `rojo build`, a strict `luau-lsp` type check against the Roblox definitions, and the `*.spec.luau` tests under Lune.
- Lune rebuilds the Rojo instance tree, so the tests are the same files Studio runs.
- A GitHub Actions workflow runs all of this on every push.
- None of it is needed for Studio development.

### D8. Frames API shape
`Frames` works on body-relative positions (`CraftState.pos`) and takes an optional `bodyOffset = abs(thing's body) − abs(frame's body)` for things on another body. That keeps Frames pure: it needs no Universe/UT. `Universe` (Phase 2) will supply the body offsets. The math is Appendix A exactly, with the rotation also done in doubles.

### D9. Surface frame and lat/lon conventions
- `up(lat, lon) = (cos lat · cos lon, sin lat, cos lat · sin lon)`, so longitude increases toward the east.
- The surface rotation has columns X = east, Y = up, Z = north (right-handed; X = Y × Z).
- At the exact poles, where north is undefined, universe −X projected onto the tangent plane is used instead.
- The base site at lat 0 / lon 0 has pocket +Y = universe +X, pocket +Z = universe +Y (north), and pocket +X = universe +Z (east).

---

## Phase 0 spike results

Spikes live in `spikes/` and run in a separate place (see `PROGRESS.md`). Each row shows what we **expect** from the engine as documented. **Expectations are UNVERIFIED** until Steamy runs the spike and pastes the `[SPIKE ...]` output here.

| Spike | Question | Expected (unverified) | Result | Consequence if the expectation is wrong |
|---|---|---|---|---|
| S1 | Is a 2048-stud sphere culled at 2k / 5k / 10k / 20k, at quality 1 / 5 / 10? | Visible at all four (large parts aren't distance-culled like small ones) | _pending_ | Lower `SCALED_FAR` / `PROXY_MAX_RADIUS` below the culling distance |
| S2 | Does LocalTransparencyModifier hide non-character parts, decals and textures? Do hidden parts cast shadows? | Parts hide. Decals/textures may **not** follow. Hidden parts likely **still cast shadows** and still block raycasts | _pending_ | PocketController also sets `CastShadow = false` locally and hides decals/textures/GUIs explicitly (already planned in 7.5); raycasts use Include filters |
| S3 | Does client-side `workspace.Gravity` affect only the local character? | Yes | _pending_ | A per-character VectorForce to fake gravity |
| S4 | Does `Sky.SkyboxOrientation` rotate the skybox at runtime? | Yes | _pending_ | Use the procedural star shell (600 neon parts) from 7.6 |
| S5 | Can ClockTime + GeographicLatitude reach any sun direction? | Directions above the horizon: yes. **Below the horizon, Roblox may switch to night/moon lighting** | _pending_ | If so, a CRAFT_ALIGNED pocket whose sun sits "below" pocket-down would be lit like night. Options: hide the lighting change behind space darkness, or add a directional fill light. Will be raised with Steamy if confirmed |
| S6 | EditableMesh sphere patch: time, memory, availability, publishing requirements | Works at runtime, with a memory budget. Published games need Game Settings → Security → "Allow Mesh / Image APIs" | _pending_ | Upload one patch mesh and use MeshParts |
| S7 | UnreliableRemoteEvent payload limit; are buffers supported? | About 900–1000 bytes; buffers are supported | _pending_ | Adjust `UNRELIABLE_PAYLOAD_LIMIT` / `MAX_STATES_PER_PACKET` |
| S8 | Server moves a part, then fires a reliable event: has the client already seen the move when the event arrives? | Yes (property replication and reliable remotes are ordered together) | _pending_ | PocketTransfer carries the expected pose, and the client waits for the parts to match |
| S9 | A Humanoid in an anchored Seat moved with PivotTo: does the character follow on all clients? | Yes, through the SeatWeld | _pending_ | Weld-based ride-along, or client-side character carry |
| S10 | Any visible jitter for characters and anchored geometry at 12,000 studs? | None (float32 resolution at 12k is ~0.001 stud) | _pending_ | Shrink `POCKET_SPACING` or the lattice |
