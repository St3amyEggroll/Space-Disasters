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

### D12. Saves also keep the hangar contents (`current`)
The save record is `{version = 1, slots = {["1"]..["10"] = design JSON}, current = design JSON?}`.
- `current` is additive. It holds the hangar contents, saved on leave and shutdown and restored into your plot on the next join.
- That's what "save on player leave" saves.
- Explicit saves go to the 10 slots.
- If DataStores are unavailable (an unpublished place, or Studio without API access), saves last only for the session and a warning is printed.

### D13. HomeBase is a shared builder module, not a replicated template
The spec puts the site template at `ReplicatedStorage.Assets.Sites.HomeBase`. Instead, `Shared/Sites/HomeBase.luau` builds the site deterministically from `Config/BaseLayout`.
- The server builds it into the base pocket.
- Clients in other pockets (Phase 2) call the same function to render it. That avoids replicating a second ~735-part copy.

### D14. Remote additions and shapes
- `SaveSlots` (server→client: slot names) and `Notify` (server→client: toast text) are new.
- `RemoveBlock` takes a grid cell `(gx, gy, gz)` instead of a block id, so undo works without the client knowing server ids.
- Symmetry is done on the client, as several `PlaceBlock` calls that are each validated on the server.

### D15. Seats are sat through prompts
Every Seat is `Disabled` by default, so walking into one does nothing.
- Its `SitPrompt` asks the server, which checks boarding permission, enables the seat and calls `Seat:Sit`.
- The seat stays enabled only while occupied.
- Cabin hatches are prompts that teleport the character between `HatchOutside` and `HatchInside` (Enter checks permission, Exit doesn't).

### D16. Design grid, orientation and wire conventions
- A block's `(gx, gy, gz)` is the minimum corner of its oriented box.
- `rot = upIndex * 4 + yawIndex` (24 orientations; 0 = identity).
- `Parts` definition order is the stable wire index for design buffers, so new parts may only be appended.
- Part-local front is -Z; the mounting/back face is +Z (cabin door, fin root, leg mount, radial decoupler plate).

### D17. Ladders are rung ladders, not TrussParts
A TrussPart can't be narrower than 2 studs, and the ladder is 1×4×1. The ladder is two rails with rungs 1 stud apart, which Roblox characters climb.

### D18. The project file no longer has `BaseGround` / `BaseSpawn`
The base site now provides the ground and spawn. **Rebuild the place** (`rojo build -o SpaceDisasters.rbxl`); a place built in Phase 0 still contains the old plate and spawn, because `rojo serve` doesn't delete them.

### D19. Phase 1 MassProps scope
MassProps computes mass, CoM, inertia, fuel groups, projected areas, leading drag factors, fin area, centre of pressure, and per-stage Δv/TWR.
- Contact hull points are computed with the flight model in Phase 2, which is their only user.
- Stage Δv is simulated exactly between flameouts at full throttle.
- Solid boosters burn only their own fuel.

---

## Phase 0 spike results

Steamy ran all ten spikes in Studio on 2026-09-30. The raw `[SPIKE ...]` output is summarized here.

| Spike | Question | Result | Decision |
|---|---|---|---|
| S1 | Is a 2048-stud sphere culled at 2k/5k/10k/20k, at quality 1/5/10? | **Quality 10: drawn at every distance. Quality 1 and 5: not drawn at ANY distance, not even 2,000 studs** (confirmed by scene triangle counts, not just by eye). | **Blocker for the universe renderer on low settings.** Follow-up spike **S11** measures the real cut-off per quality level and part size. Scaled-space distances (`SCALED_NEAR/FAR`, `PROXY_MAX_RADIUS`) will be set from its results before Phase 2's scaled-space work. |
| S2 | Does LocalTransparencyModifier hide world parts, decals and textures? Shadows? | The part hides (the model test was clear). **Decals, SurfaceGuis and BillboardGuis stay visible.** Hidden parts **still block raycasts**. The explicit fallback (Transparency 1 on decals/textures, GUIs disabled, CastShadow false) hides everything, shadows included. | As planned in 7.5: PocketController hides decals/textures/GUIs explicitly, sets CastShadow false locally, and every client raycast uses an Include filter. |
| S3 | Does client-side `workspace.Gravity` affect only that client? | **Yes.** Gravity 50 gave 18.1-stud jumps against 4.7 for the other player, seen the same on every screen. Server Gravity stayed 196.2. | Spec 7.5 works as written. |
| S4 | Does `Sky.SkyboxOrientation` rotate the skybox at runtime? | **Yes**, with any values, at 1.6 µs per write. Night skybox rotation was visible ("a bit choppy"). The daytime sky did not rotate, because it's drawn by the Atmosphere and not the skybox. Procedural stars weren't visible. `CelestialBodiesShown = false` leaves only the sun glow. | Use SkyboxOrientation with our own star skybox textures. In space Atmosphere.Density is 0, so the skybox shows. The 600-part star shell isn't needed. |
| S5 | Can ClockTime + GeographicLatitude reach any sun direction? | **Above the horizon: yes.** 291/300 random directions were solved exactly; the misses were near the latitude clamp, and the engine accepts latitude beyond ±90, so widening the search fixes them. Warm-started tracking: max 0.03° error, 0.58 ms per step. **Below the horizon, Roblox switches to night/moonlight lighting**, even though `GetSunDirection()` reports the right direction. | **Engine limit → question for Steamy (Q1 below).** |
| S6 | EditableMesh sphere patch: time, memory, availability | **Works in Studio.** Building a 2,048-triangle patch takes about 4 ms. It stays at full detail out to 20,000 studs, and textures via EditableImage work. **But:** (1) creation hit **"memory budget limits" after only ~7 patches**; (2) **a MeshPart disappears when its EditableMesh is destroyed**, so meshes must stay alive; (3) Size clamps to 2048 per axis as expected. | **Blocker for 24-patch proxies built as separate meshes.** All 24 patches of a cube-sphere have the same shape, so the plan is **one shared patch mesh for every proxy**. Follow-up spike **S12** checks that many MeshParts can share one EditableMesh, and measures the real budget. Fallback: upload the single patch mesh as an asset. |
| S7 | UnreliableRemoteEvent payload limit; buffers? | **Buffers work** (typeof `buffer`, intact). **Nothing was dropped up to 1,200 bytes**, the largest size tested, in both directions, with and without extra arguments. A reliable 50 KB buffer arrives intact. | Studio's local networking may not enforce the live-server limit, so `UNRELIABLE_PAYLOAD_LIMIT` stays at a conservative 900 bytes. It will be re-checked on a published server in Phase 3. |
| S8 | Server moves a part, then fires a reliable event: has the client already seen the move? | **Yes, for position, rotation, model pivot and attributes: 300/300.** The client state was never older than the event. **Re-parenting was not always ordered:** 12/300 events arrived before the model's new Parent, which caught up 5–14 frames later. | The PocketTransfer protocol can rely on PivotTo moves and attributes. **The client must not assume a re-parented craft is already in the destination pocket's folder.** It waits for the parent change, with a timeout, and PocketId attributes are the source of truth. |
| S9 | A seated Humanoid in a Seat moved with PivotTo: does it follow on all clients? | **Anchored Seat: follows perfectly on server and both clients.** **Unanchored Seat welded to an anchored root: the character gets thrown out of the seat** during smooth moves and rotations (SeatWeld lost, 10-stud drift). | **Craft parts, seats included, are all individually Anchored.** Of the spec's "anchored, or welded to an anchored root" (I3), we take the anchored option. |
| S10 | Jitter at 12,000 studs? | **None**, at 12,000 or 24,000: zero measured jitter and "None" to every visual check. | The pocket lattice is safe, with 2× headroom. |

### Follow-up spike results (S11, S12), 2026-09-30

**S11, the distance at which a part stops being drawn** (distance measured to the part's centre, by scene triangle counts):

| Quality | 4-stud part | 64-stud part | 512-stud part | 2048-stud part |
|---|---|---|---|---|
| 1 | 300 | 300 | 500 | 1,250 |
| 3 | 500 | 500 | 800 | 1,500 |
| 5 | 650 | 650 | 800 | 1,500 |
| 7 | 2,000 | 2,000 | 2,500 | 3,000 |
| 10 | 5,000 | 20,000+ | 20,000+ | 20,000+ |

Roblox cuts off drawing by distance, and the cutoff depends on the quality level. Bigger parts survive somewhat farther. At quality 1–5, the planned scaled-space layout (bodies at 400–1,800 studs, dominant proxy up to 2,800 studs in radius, star shell at 1,950) **would be partly or fully invisible**.

**Decision D10, a quality-adaptive scaled space (implemented with the universe renderer in Phase 2):**
- A client `RenderBudget` measures the current draw distance at startup, and again whenever the quality setting changes. It uses the S11 method: a hidden probe part and a triangle-count check, taking about 0.5 s. This also covers "Automatic" quality, whose real level can't be read.
- `SCALED_NEAR/FAR`, `PROXY_MAX_RADIUS` and the star distance are then scaled to fit inside that budget, keeping everything at least ~20% inside the cutoff. At quality 1 that means bodies at about 150–250 studs and a smaller dominant proxy. The config values become the maxima, used at high quality.
- The trade-off at low quality: the proxy→surface handover altitude (`PROXY_MIN_ALT`) rises and the near render radius shrinks. Low-quality players see a slightly less detailed world, but **nothing disappears**, which is the pillar that matters.
- Star sky: the skybox (S4) is used instead of star parts, so stars are unaffected by culling.

**S12, EditableMesh budget and sharing (Studio):**
- **The EditableMesh budget is a count, not a size: 8 meshes**, whether each has 81 or 4,225 vertices. The budget frees up again after `Destroy()`.
- **One EditableMesh can feed many MeshParts:** 24× `CreateMeshPartAsync` from one mesh succeeded, and `MeshPart:Clone()` works.
- The visual check came back "some missing". That's explained by a mistake in the test layout: each copy was spun about its own axis before being turned toward the camera, so some faced away and were back-face culled. The API result stands.
- EditableImage: 200× 256×256 fit without complaint; 1024×1024 hit the budget after 19.

**Decision D11:**
- **All scaled-space proxies share ONE patch EditableMesh.** All 24 cube-sphere patches are congruent, so each body is 24 MeshParts, all rotated copies. Fallback: upload the patch as a mesh asset.
- Body textures come from EditableImages, which are plentiful at 256–512 px, or from uploaded textures.
- **Phase 8 terrain can't use one EditableMesh per chunk** under an 8-mesh budget. It needs a different design, e.g. client-side Roblox Terrain voxels or a few large merged meshes. That will be re-spiked at the start of Phase 8.

---

## Open questions for Steamy

### Q1. Sun "below" the pocket floor: Roblox lights the scene like night (ANSWERED: A)
In a flying craft's pocket the craft is always upright, so the sun can be in any direction relative to the floor, including underneath it. Roblox only does proper sunlight (bright, with shadows) when the sun is above the horizon. S5 confirmed this. With the sun below pocket-down, you'd get night/moonlight: dim, bluish, no sun shadows. It happens whenever the sun is on the "floor side" of the craft, which could be close to half the time in orbit.

Options:
- **A (recommended for v1):** accept it and style it. When the sun is below the pocket horizon, switch to a "shadow side" look: no direct sun, ambient tinted slightly warm so things stay readable. Planets and the sky still render correctly, because they're drawn by our own code. Only the lighting on the craft itself is affected. Cheap and honest.
- **B:** mirror the sun above the horizon (light from the reflected direction). The craft stays brightly lit, but shadows and lit faces are on the wrong side, so the sun can appear to shine through the floor.
- **C:** research a custom lighting rig (e.g. many SurfaceLights/SpotLights around the craft). Complex, costly, and short-ranged (60 studs). Not recommended.

**Decision (Steamy, 2026-09-30): A.** When the sun is below the pocket horizon, SkyLightingController switches to a styled "shadow side" look: no direct sun, and ambient/OutdoorAmbient tinted slightly warm and bright enough to stay readable. Scaled-space bodies and the skybox are unaffected, because our own code draws them. The sun solve also searches latitudes beyond ±90° to fix the S5 near-pole misses.
