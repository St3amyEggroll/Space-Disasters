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
(D12–D17 were written for the first Phase 1 build; D20 supersedes the hangar, plot size and pad parts of them.)
The base site now provides the ground and spawn. **Rebuild the place** (`rojo build -o SpaceDisasters.rbxl`); a place built in Phase 0 still contains the old plate and spawn, because `rojo serve` doesn't delete them.

### D19. Phase 1 MassProps scope
MassProps computes mass, CoM, inertia, fuel groups, projected areas, leading drag factors, fin area, centre of pressure, and per-stage Δv/TWR.
- Contact hull points are computed with the flight model in Phase 2, which is their only user.
- Stage Δv is simulated exactly between flameouts at full throttle.
- Solid boosters burn only their own fuel.

### D20. Plane Crazy-style building (Steamy, Phase 1 playtest feedback)
Steamy asked for building that's "less like KSP, more like Plane Crazy". **Flight stays KSP-style** as in the spec.
- **Block grid:** one build block = `GameConfig.GRID_SIZE` = **4 studs**, about 3/4 of a character's height.
  - Part sizes in `Config/Parts` are now in blocks, and design coordinates are in blocks. `CraftDesign.blockCFrame` and `MassProps` convert to studs, which are still meters.
  - New part sizes:

    | Size | Parts |
    |---|---|
    | 1×1×1 | pod, small tank, small engine, nose, decouplers, chute, block, ladder, seat |
    | 1×2×1 | long small tank, fin, leg |
    | 1×3×1 | solid booster |
    | 1×1×3 | beam |
    | 2×1×2 | large tank, large decoupler, adapter |
    | 2×2×2 | cabin (7×7×7 interior), long large tank, large engine, large nose |
    | 3×1×3 | deck (was "plate") |

  - Part stats (masses, thrust, Isp, fuel) are unchanged, so the Section 6.2 sanity numbers still hold.
- **Open plots:**
  - There's no hangar building. Each plot is a raised 80×80 baseplate (20×20 blocks) with a 4-stud grid drawn on it, and a build height of 50 blocks (200 studs). Steamy picked the "Large" plot size.
  - The grid origin is the baseplate top (y = 1).
- **Shared launch area:**
  - There are 8 pads north of the plots.
  - Roll Out reuses your pad (replacing your previous rocket), else takes the first free pad. If all pads are busy, it says so.
- **Paint tool:**
  - There's a 16-colour palette (`Config/Paint`, append-only indices).
  - A block's `color` is saved in the design JSON (`c`) and in the network buffer, which is now **12 bytes per block**, matching the spec's "about 12".
  - `PaintBlock` is validated on the server, and paint can be undone.
- **Mirror mode:** mirror across the plot's X or Z centre plane, or both, as well as radial 2/4 symmetry.
  - A mirrored part uses the reflected orientation S·R·S, which is always one of the 24 rotations.
- **Controls:** B build, P paint, X delete, R/T rotate, 1/2/4 radial, M cycles mirror, Ctrl+Z undo.
- **Builder UI:** redesigned, with a tool hotbar, category tabs with 3D part previews, a paint palette, a stats card, a save panel and a big Roll Out button.

### D21. Flight model details (Phase 2a)
- **State:** the craft state is the root block's centre (else the lowest block id), in doubles, relative to the dominant body. The centre of mass is tracked inside the model, so staging never makes the reference point jump.
- **Integration:**
  - Position uses velocity Verlet.
  - Rotation is semi-implicit on the diagonal inertia (the craft's principal axes are approximated by its block axes).
  - Fixed steps at `GameConfig.SIM_RATE` (60 Hz), with 2 substeps in flight and 4 near the ground.
- **Contact:** penalty springs whose stiffness is scaled by the craft's mass (natural frequency 7 Hz, damping ratio 0.8), so heavy and light crafts land with the same feel. A block breaks when its impact speed exceeds its part's `CrashTolerance`.
- **SAS:** a PD controller (`SAS_KP`, `SAS_KD`), limited by the gimbal torque budget and `MAX_ANGULAR_SPEED`.
- **Staging:** the stage list is fixed at launch (from `CraftGraph`), as in KSP.
  - Decoupling splits the craft graph. Every piece without the root block becomes debris, with the decoupler's push applied.
  - Debris state is computed **before** the blocks are removed from the parent.

### D22. Who simulates what (Phase 2a)
- The **pilot's client** simulates its own craft and sends a `PilotState` at 20 Hz.
- The server also runs a copy and validates the pilot's state against it. Implausible jumps earn strikes, and repeated strikes send a `FlightOverride`.
- The **server** simulates debris, and any craft whose pilot left (`ServerSimService`, `DEBRIS_SIM_RATE`).
- The server streams every craft's state in batches (`CraftStates`, 77 bytes per craft, packets kept under 900 bytes, spike S7).
- **Crashes are reported by the pilot** (`ReportPartsDestroyed`). The server accepts a report only if its own copy agrees within `CRASH_REPORT_MARGIN`.

### D23. Other crafts and debris are drawn from Phase 2a (earlier than Phase 3)
Staging needs debris you can see, so `RemoteCraftRenderer` exists now.
- It draws a local cosmetic copy of every craft and debris piece in your pocket from the design buffer, interpolated `INTERP_DELAY` behind.
- Phase 3 still owns the rest of multiplayer crafts: joining someone else's pocket mid-flight and pocket merging.

### D24. Hatches lock in flight
Cabin hatches only open while the craft is on the pad (`State = Prelaunch`). Otherwise someone could walk out of a moving craft into the pocket void. EVA is Phase 6.

### D25. `client/Render/` folder (layout addition)
The render layers are plain modules, not controllers, so they live in `StarterPlayerScripts/Client/Render`:
- `ScaledSpace`, `Surface`, `SkyLighting`, `ChaseCamera`, `Plumes`
- `RenderContext` and `HudData`, which only define types

The new `UniverseRenderer` controller runs them all once per frame (after the camera) in this order: ScaledSpace, Surface, SkyLighting, RemoteCraftRenderer.

### D26. Scaled space and sky lighting done in 2a
The 2a request included the sky, so the D10/D11 scaled space and the Q1 = A lighting are built now instead of in Phase 4.
- **Draw distance per quality level** (from S11), in studs:

  | Quality | Studs |
  |---|---|
  | 1 | 1250 |
  | 2 | 1400 |
  | 3–5 | 1500 |
  | 6 | 2200 |
  | 7 | 3000 |
  | 8 | 5000 |
  | 9 | 8000 |
  | 10 | 20000 |
  | Automatic | 3000 |

- **The limb budget:** a proxy sphere only needs its visible limb within the draw distance, not its far hemisphere. Budgeting for the limb lets proxies sit closer and bigger than the first, far-side budget allowed.
- **Fallback:** if EditableMesh is unavailable (the place isn't published, or the Mesh/Image APIs setting is off), bodies are drawn as single Ball parts.

### D27. Smaller planets (Steamy, Phase 2a feedback). SUPERSEDED by D41
> D41 brought back the 60 km Earth and the 15 km Mun at 450 km.

Steamy felt Kablamo was too big, so both bodies are **half size**. This deviates from the spec's Section 6.1 values.
- **Kablamo:** radius 30 km (was 60 km), surface gravity still 9.81. The atmosphere top is 7 km (was 8 km), with a 1 km scale height.
  - Low orbit at 10 km altitude is about 470 m/s (was about 710), with a period of about 8.9 minutes.
  - The sanity rocket (about 2,100 m/s) now reaches orbit easily.
- **Dent:** radius 7.5 km, orbit 220 km (was 450 km). Its SOI is about 35 km and its period about 6,900 s.

### D28. Flight starts when the pilot sits; real physics on the pad (Steamy, Phase 2a feedback)
- **Spawning:** players spawn (and respawn) on their own plot, near its street edge. `/base` also takes you to your plot.
- **Roll Out:**
  - Roll Out puts the owner straight into the craft's pilot seat. Both command parts (Command Pod, Crew Cabin) have one.
  - Without a command part, Roll Out refuses: "You need a Command Pod (or Crew Cabin) to fly!"
- **Flight start:**
  - When a pilot sits in a Prelaunch craft, the flight starts right away: the pocket transfer, then `FlightStart` with **no stage fired**. The launch countdown is gone.
  - The rocket stands on its pad under the real flight model. It can tip over if it's badly balanced.
  - Throttle, SAS and steering work on the pad. **Space ignites stage 1**, and that's also when the pad is freed.
- **Platforms in the ground height:** `SurfaceHeight.height` now includes the launch-site platforms (`BaseLayout.platformHeight`): the 1-stud pads and plot baseplates. That way the rocket stands on the pad top instead of sinking 1 stud.
- **Return to pad:** pressing **F** before ignition (no stage fired, no parts lost) moves the craft back into the base pocket as Prelaunch, where it stands now.
  - The pilot is put beside the pad, and the flight pocket is released.
  - This keeps boarding possible: friends board while the craft is Prelaunch, then the pilot sits down again to restart the flight.
- **Debris:** none can exist before ignition, so returning to the pad is always clean.

### D29. Level camera (Steamy, Phase 2a feedback)
The flight camera no longer turns with the rocket.
- **Why it used to:** a CRAFT_ALIGNED pocket turns with the craft, so orbiting about pocket Y followed every rotation.
- **How it works now:**
  - The orbit lives in universe axes. Its "up" is gravity up (away from the body's centre) below max(2 km, atmosphere top).
  - Over the next 3 km it smoothly blends to the solar-system plane's normal (universe +Y; every orbit is in the XZ plane).
  - Controls are like the Roblox camera: right-drag to orbit, wheel to zoom. The horizontal view direction is carried along as "up" changes, so nothing jumps.
- **Who gets it:** everyone aboard a flying craft, not just the pilot. **V** switches back to the stock Roblox camera.

### D30. Planet visuals (Steamy: "make the planet look better")
- **`Shared/Sim/Biome`:** a pure, deterministic look model sampled by direction. It's shared by the space view and the ground view, so they match.
  - **Kablamo:** about 61% ocean, with shallows, beaches, grass, forest, desert, mountains with snowy peaks, and ice caps.
  - **Dent:** maria, craters at several sizes, and ray craters.
  - The base always sits on flat grassland, with the sea about 6–7 km to the east.
  - It uses the built-in `math.noise` (about 20× faster than pure Luau). That is Luau's own C code, so Roblox and Lune give the same results.
- **From space:**
  - Every scaled-space patch gets its own EditableImage texture: 24 × 256 px for Kablamo and 24 × 128 px for Dent, through UVs on the shared patch mesh.
  - Textures are painted in the background (about 4 ms per frame). Until a patch is done it shows the planet's average colour.
  - Kablamo also gets a cloud shell (SurfaceAppearance with transparency) and a thin atmosphere shell, each with an on/off tunable.
  - This updates D11: one shared mesh, but per-part textures.
- **On the ground:**
  - Tiles are coloured from Biome and get a 64 px texture through a shared tile mesh. The textures are cached and painted nearest-first at 2 ms per frame.
  - Cosmetic props: trees, pines, cacti, bushes and rocks on Kablamo; boulders and crater rims on Dent.
  - Props are placed deterministically per cell, capped at 600 parts, kept 800 m clear of the base, and never collide.
- **Budgets:**
  - At most 120 EditableImages (S12 measured 200 × 256² as fine) and 2 EditableMeshes (the budget is 8).
  - Every creation is guarded. Without "Allow Mesh / Image APIs", everything falls back to flat Biome colours with one warning.
- **Heads-up for Studio:** if textures look mirrored inside a patch or tile, set `UV_FLIP_V = true` in `Biome.luau`.

### D31. Flight pockets are HORIZON_ALIGNED, not CRAFT_ALIGNED (Steamy, Phase 2a playtest)
**This deviates from the spec,** which made flight pockets CRAFT_ALIGNED.

**The problem:** with CRAFT_ALIGNED pockets, workspace "up" was the rocket's up. But Roblox draws its sky, horizon haze, sun and day/night around workspace Y. So when the rocket pitched over, the sky tilted with it, and the screen split into a "day" half and a "night" half. The stars turned with the rocket too.

**What changed:**
- **Pocket axes:** a flight pocket's reference point still follows the craft, but its axes come from `Universe.pocketRotation`:
  - Low down, up is the local vertical (away from the body's centre).
  - Above max(2 km, atmosphere top), up turns smoothly toward the sun over 3 km.
- **Why it turns toward the sun:** in space, "day" means the sun can be seen. But Roblox lights a scene only while the sun is above the workspace horizon, and in orbit the visible sun can sit far below the local horizon.
- **Planet shadow** keeps the Q1 = A shadow-side look (SkyLighting).
- **The rocket now turns inside the pocket:**
  - The server places the real model once at flight start and never moves it in flight.
  - Every client poses the model each frame from the craft state: its own simulation for the pilot, the interpolated stream for passengers. It moves the anchored parts with BulkMoveTo, and seats one by one so seated characters ride along.
  - A model is posed only while its `FlightPocket` attribute names the client's current pocket. The server clears that attribute before moving the model out again, because a stale local pose would otherwise stick (replication only sends changes).
  - `PoseEpoch` bumps on every server move, so the client re-reads part offsets.
- **Return to pad:** the craft moves by "craft frame now (in base) × craft frame on the server⁻¹". Unseated crew use the horizon frame at the craft's current state.
- **Known limits:**
  - On the server, the model sits at its flight-start pose. Server checks that use bounding boxes (crew standing inside, occupants of a destroyed command part) are approximate. Seated checks are exact.
  - Unseated characters inside a flying cabin stand on a floor that turns under them. Hatches stay locked in flight (D24).
- **Space sky (`Render/StarSky`):**
  - Above the lower half of the atmosphere (air factor < 0.5), the Sky shows six painted black star faces (EditableImage), kept fixed to universe axes by SkyboxOrientation as before.
  - Below that, the original skybox shows under the Atmosphere.
  - If the Sky refuses painted faces, it warns once and keeps the default sky.
- **Clouds** from D30 are off (`CLOUDS_ENABLED = false`). Studio does not let game scripts set `SurfaceAppearance.ColorMapContent` ("lacking capability Plugin").
- **Plumes:** each engine's flame now follows `FlightModel.engineBurning` exactly, and every flame goes out when the local simulation ends. Remote copies no longer keep a minimum 5% flame on throttled-down liquid engines. Solid boosters (SRBs) still can't be throttled, as in KSP.

### D32. No Roblox Atmosphere: we paint the whole sky (Steamy, Phase 2a playtest 3)
**What went wrong:** S4 concluded that "in space Atmosphere.Density is 0, so the skybox shows". Play proved that wrong. Whenever an Atmosphere instance exists, Roblox draws its own procedural sky, even at Density 0. That sky has a fixed grey "below the horizon" half. It split the screen into blue and grey (on the ground too) and kept space blue.

**What changed:**
- **The Atmosphere is gone.** SkyLighting removes any Atmosphere in Lighting, including ones added later.
- **StarSky paints all six skybox faces** (EditableImage) as a blend:
  - space: near-black with point stars, fixed to universe axes by SkyboxOrientation
  - day: one flat sky colour, blue and warmer toward sunset
- **How much "day":** `day = smoothstep(sun elevation from -0.08 to 0.1) × air^0.7 × (1 − shadow)`.
  - Daylight low in the air gives a blue sky; night, space, Dent and planet shadow all give black with stars.
  - A flat day colour needs no knowledge of the skybox faces' directions, so there are no seams.
- **Cost:** a repaint is a fast background fill plus the star pixels. It runs only when the blend moved by more than 0.01, two faces per frame.
- **Night stars:** Roblox's own `StarCount` is now 0, because those stars would turn with the pocket.
- **What we lose:** Roblox's aerial haze on distant parts.
- **Invisible rocket:** a craft model that reaches the shown pocket after the pocket switch is now un-hidden on arrival. A re-parent can lag the transfer event (S8), and the model kept the hidden state of the pocket it left. In the playtest the rocket flew invisible, with only its seat prompt showing.

### D33. Roblox's sky near the ground, SkyCube for space, `/time` (Steamy, Phase 2a playtest 4)
**What went wrong:** painting the Sky's faces with EditableImages (D32) did not show in Studio. Roblox fell back to its default cloud skybox, which we were still rotating to universe axes, so the clouds stood on end.

**What changed:**
- **Near the ground:** Roblox's own skybox stays upright (`SkyboxOrientation` 0) and is the sky.
  - Flight pockets are horizon-aligned low down (D31), and the sun solve matches the real sun, so Roblox's day/night follows the real sun: blue with clouds by day, dark with Roblox's stars (`StarCount` 3000) at night.
  - There is still no Atmosphere (D32).
- **Space is `Render/SkyCube`:** a cube of 54 transparent panels around the camera.
  - Each panel has an unlit SurfaceGui (`LightInfluence` 0) with a near-black background and a painted star image (EditableImage in an ImageLabel, the engine's main EditableImage route).
  - The cube is fixed to universe axes, so the stars don't turn with the rocket.
- **Cube opacity:**
  - 0 while the true-scale ground is drawn (surface mode), so far ground tiles are never hidden.
  - 1 above the ground view for bodies without air.
  - With air: smoothstep from the proxy handover altitude (about 3.2 km) to the atmosphere top.
- **Cube size:** the half-size is 0.9 × draw distance, between 400 and 2,900 studs. Everything ScaledSpace draws stays inside it.
- **Low graphics quality:** the engine may cull far panels, and Roblox's sky shows through there.
- **`/time <hour>` (debug):** sets the base's local time.
  - It is a sun phase offset replicated as the Globals attribute `SunPhaseOffset`, applied on the server and on every client. Orbits and UT are untouched.
  - The F3 universe line shows the base time.
  - A day is still `DAY_LENGTH_S` = 20 minutes.
- **StarSky (D32) is removed.**

### D34. Part remodel, removed parts, animated landing legs (Steamy)
- **Removed:** the Crew Cabin (`cabin_l`) and the Ladder (`ladder`), at Steamy's request.
  - Their definitions are gone, so palette and wire indices shift. Both ends share `Parts.List`, and saves store part ids, so that's safe.
  - `CraftDesign.fromJson` drops blocks of unknown parts, so old saves still load without them.
  - The Command Pod is now the only command part.
- **Remodelled** (`PartVisuals`), only the parts Steamy chose:
  - **Command Pod:** a simple octagonal capsule (Steamy asked for simple) on a heat shield, with one framed window, a docking ring and an orange hatch.
  - **Engines:** mounting plate, thrust frame, chamber with turbopump, gimbal actuators, and a hollow faceted bell with a glow in the throat.
  - **Solid Booster:** flat top (stack a nose cone on it), segment joints, an orange band, roll panels, lugs, and a faceted nozzle.
  - **Decouplers:** collars, a hazard band with slashes, a separation groove with explosive bolts. The radial one is a bolted plate with a piston, hazard collar, struts and a clamp pad.
  - **Size Adapter and nose cones:** faceted shells.
  - **How the faceted shells are built:** exact n-sided frusta (a plate plus two triangle wedges per side, so sides meet edge to edge). Cones no longer look like stacked cylinders.
  - Tanks, fin, chute, seat and blocks are unchanged.
- **Landing leg:** a white sleeve on a hinged bracket.
  - The piston, spring collar, ankle and foot pad slide 3 studs up into the sleeve when stowed.
  - Every moving part stores its stowed part-local CFrame in the `GearStowed` attribute.
  - **G** toggles the legs. The state is `FlightModel.FLAG_GEAR_UP` in `CraftState.flags`, so it streams to everyone.
  - `Render/Gear` animates the real model (PocketController) and the cosmetic copies (RemoteCraftRenderer) over 1.2 s.
  - The animation is visual only: ground contact still uses each leg block's full box.
- **Tests:** every primitive, in both the deployed and stowed pose, must stay inside its part's box. Old saves with removed parts still load.
- **Preview:** `tools/export-parts.luau` and `tools/part-preview` render the parts offline (the "Part Hangar" page).

### D35. Phase 3 (multiplayer crafts) decisions
- **Interest management** (`Shared/Net/Interest`):
  - **Rates:** craft in your pocket 20 Hz; within 50 km 20 Hz; same SOI 2 Hz; anything else 0.5 Hz.
  - **Budget:** enforced per client at `CRAFT_STATES_BUDGET` (18 KB/s of payload).
    - Your own pocket always keeps 20 Hz.
    - Everything else first drops to 0.5 Hz. Rate is given back to crafts before debris, then by tier, nearest first.
  - **Send credits:** each (client, craft) pair keeps a send credit.
  - **Your own craft:** a pilot is never sent its own craft.
  - The budget counts payload only. F3's "Net in" line shows the real total.
- **Snapshot:** the client asks for it (`RequestSnapshot`) once its handlers are connected, rather than the server pushing it on join. Pad (Prelaunch) crafts are announced too, so other pockets see them.
- **Starved streams** (`Shared/Net/StateBuffer`):
  - 20 Hz streams extrapolate 0.25 s, then freeze (spec).
  - Slow streams extrapolate up to 1.25 × their interval (at most 2.5 s).
  - Never blends across an SOI change.
- **Markers** (`Render/CraftMarkers`):
  - "Name (Owner)" and distance, at most 200 studs from the camera, drawn on top.
  - Hidden behind planets by a line-of-sight test in doubles. Lines that pass less than 300 m below the surface don't count as blocked.
  - No markers for debris.
  - Copy or marker is chosen with ±10% hysteresis.
- **Puppets** (`Render/Puppets`):
  - Appearance clones built from each player's HumanoidDescription. If that fails, a blocky stand-in is used, and the real look is retried every 30 s.
  - **Seated:** pose = seat × SeatWeld C0·C1⁻¹, relative to the real model's craft frame.
  - **Standing:** the interpolated stream (D31: the server model never turns).
  - Only within `PUPPET_DISTANCE`.
- **Hand-over:**
  - Leaving the pilot seat after ignition, dying or disconnecting hands the craft to the server (`FlightEnd`), with zero input and the throttle cut to 0. SRBs keep burning.
  - This also fixed the server copy keeping its launch throttle of 1.
  - Anyone allowed to board who sits in the pilot seat of a server-flown craft takes it back (`FlightStart` with `resume` data). That works on rails too (D36).
- **`crewOf`:** a standing character must be inside the craft's box **and** above part of it (a short downward ray), so bystanders aren't pulled into a launching craft's pocket.

### D36. Phase 5 (orbits, rails, map, navball) decisions
- **`Shared/Sim/Kepler`:**
  - Universal-variable propagation for elliptic, parabolic, hyperbolic and radial orbits.
  - Robust elements, apsides with the time to each, and conic points for the map.
  - SOI crossing search with bounded steps plus bisection to 0.01 s.
  - Placed in `Sim/`, not the spec's `Math/`.
- **`Shared/Sim/Rails`:**
  - A rail is `{bodyId, epochUT, r0, v0, rot, angVel, com, throttle, flags}`. The centre of mass follows the conic and the root turns around it, as FlightModel does.
  - With SAS on, attitude is frozen (after settling below 0.05 rad/s). Otherwise the angular velocity is held.
  - **Rails floor:** max(atmosphere top, 500 m) + 100 m hysteresis. `exitUT` is precomputed, which also stops crafts sinking into airless Dent.
- **Authority:**
  - **Server crafts and debris:** `RailsService` puts them on rails after 0.5 s eligible.
  - **Piloted crafts:** the pilot proposes with `RequestRails`. The server validates against its last valid state, then broadcasts `CraftRails`.
  - **Leaving rails:** any pilot input or thrust ends rails. The pilot resumes PilotState, and the first newer state takes the server off rails. `CraftOffRails` carries UT.
  - **Streaming:** no CraftStates or PilotState while on rails.
  - **SOI changes on rails:** RailsService checks every 1 s and bisects the crossing; clients mirror SOI changes for display.
- **Debris:** suborbital debris more than 30 km from every occupied pocket is deleted every 1 s. Orbital debris persists.
- **Navball:** a ViewportFrame ball built from primitives.
  - Screen up = craft +Z, right = craft +X. The horizon frame is the true radial up, not the sun-tilted pocket up.
  - Prograde/retrograde markers and N/E/S/W are 2D overlays.
- **Map view:**
  - `MAP_SCALE` 0.002 studs/m, around a map origin at the slot origin ± 2000 studs Y. Zoom changes the scale (the camera stays 160 studs away), so everything stays inside draw distance.
  - The SkyCube becomes an opaque star box around the map camera.
  - Orbit lines are Beams. BillboardGui markers live in PlayerGui so they can be clicked.
- **Merge note:** both phases were built in parallel and merged. On rails the relay skips the craft (Phase 3's `shouldStream` only streams "Flying"), and `RemoteCraftRenderer.sampleState` reads rails first.

### D37. Two new phases (Steamy)
- **Phase 10: Effects.** Better effects for rockets and everything else: plumes, smoke, explosions, separation, re-entry heat and the rest.
- **Phase 11: UI renovation.** A new look for the builder, flight HUD, map and menus.

### D38. Phase 10 effects
Steamy asked for "an effects phase, to update effects of rockets and everything". He was away, so these are our choices.

- **Where it lives:**
  - `Render/Effects` (new) draws every rocket effect. `Render/EffectsMath` (new) holds the pure curves, with 12 offline tests.
  - `Render/Plumes` is now only called by Effects. Effects is stepped by `UniverseRenderer` once per frame, after the copies are posed.
  - Everything is client-only and cosmetic (I5/I6). Nothing is replicated and nothing uses Roblox physics (I3).
- **Same effects for everyone, with no new remotes:** they come from data every client already has (`FLAG_BURNING`, throttle, ignited engines, velocity, position, `CraftStaged`, `PartsDestroyed`).
  - **The pilot's own rocket:** `FlightController` reports it every frame from its own simulation. Its predicted staging and crash reports trigger the puffs and explosions straight away.
  - **Everyone else's rockets and debris:** `RemoteCraftRenderer` reports every copy it draws.
  - **Passengers:** the pocket's real rocket is reported too, so passengers now see their own rocket's flames. That was missing before.
  - **The pilot wins:** when both report the same rocket, the pilot's simulation is used. The server's echo of a predicted event is ignored, and no block explodes or separates twice within 3 s.
- **Hidden things stay hidden:** a rocket that isn't reported for 2 frames loses its effects. That covers other pockets, the far-away marker view and the map view, so effects never show for rockets that aren't drawn.
- **Smoke in a moving flight pocket:**
  - In a flight pocket the rocket hardly moves and the world streams past it. So smoke, dust and debris move at the air's velocity in pocket axes: `drift = vectorToWorkspace(v_body(craft) − v_body(pocket ref) − v_pocket)`.
  - `PocketController.frameVelocity()` (new) gives `v_pocket`: the primary rocket's velocity in a flight pocket, and zero in the base.
  - **Aiming the particles:** ParticleEmitters can't add a velocity to their particles. So each emitter is pointed along drift plus its own push, with the cone opened just enough for the random part (`EffectsMath.driftEmission`).
  - **No drag on moving smoke:** the pocket's acceleration, smoothed, is applied as −a to the drifting particles, and they get no Drag. Drag would pull them back toward the pocket.
  - **Pocket switches:** they clear all one-shot effects.
- **The effects:**
  - **Engine plumes:**
    - At sea level they are narrow, bright and tight. In vacuum they become a long, faint cone that keeps widening, with a shorter core and paler, bluer glow (driven by air pressure).
    - Solid boosters are detected by their part: thicker, longer, yellower, with grey-brown smoke.
    - An engine that lights on a rocket already in view flares (light and core) for 0.35 s with a burst of flame and sparks. One that cuts out leaves a smoke puff (smaller in thin air).
  - **Smoke trail:**
    - One trail per rocket while engines burn in air. It is full below about 1.2 km and gone above about 5.5 km, on a log scale.
    - It is thicker for boosters and thin for liquid engines.
    - Puffs stay put in the air, so the trail is up to 900 studs long. Puffs grow with speed so the trail never breaks into dots.
  - **Launch and landing dust:**
    - Below 40 m (nozzle height above the SurfaceHeight ground plane, so pads count), there is a ring of 6 emitters on the ground under the burning nozzles.
    - It is stronger closer to the ground and with more downward thrust.
    - The colour comes from the ground under it (Biome), with white spray over the sea.
  - **Stage separation:** a white puff, sparks and a short flash at every decoupler that fired.
  - **Explosions** (`PartsDestroyed` or the pilot's own crash report): for the 6 largest destroyed blocks of an event, each gets:
    - a growing, fading Neon fireball
    - fire, dark smoke and sparks
    - 5 glowing debris bits with short trails
    - a light flash
    - Roblox's classic Explosion, with BlastPressure 0 and DestroyJointRadiusPercent 0. It's skipped when the air streams past faster than 30 m/s, because the classic effect can't move with it.
    - Everything scales with block size. There's a budget of 12 explosions in a burst, refilling at 10 per second.
  - **Re-entry heating:**
    - Driven by heat = ρ·v³ on a log scale (1.5e5 to 3e6), times a speed gate from 380 to 460 m/s.
    - A re-entry from a 15 km orbit glows from about 6 km down, strongest around 4 km. A normal ascent stays dark; a very fast one (400 m/s at 4.5 km) only glimmers.
    - What you see on the leading side: an orange-pink plasma envelope (two beams), a glowing cap, flame streaks streaming back along the rocket, and an orange light.
  - **Transonic vapour cone:** a white flickering cone between Mach 0.93 and 1.12 (we use 340 m/s everywhere), only below about 1.9 km.
- **Budgets:**
  - Everything is pooled: 6 trails, 4 dust rings, 4 heated rockets, 16 bursts, 10 fireballs and 40 debris bits at most.
  - Particle rates scale with the graphics quality: x0.3 at level 1, x1 at level 10, x0.8 on Automatic.
  - The F3 overlay has an "Effects:" line (counts and quality) and an "Effects" timing.
- **No sounds yet.** They need uploaded audio asset ids. That's a follow-up for Steamy.
- **Known limits:**
  - Copies of other rockets only know "something is burning" plus which engines were ignited, so a burnt-out booster on someone else's rocket keeps its flame until the whole rocket stops burning. This is unchanged from before.
  - Explosions on other players' rockets appear where their copy is drawn, 0.1 s behind the real rocket, which is also when the blocks vanish.
  - How the particles look (built-in Roblox textures, stretched sparks and streaks) can only be judged in Studio.

### D39. New names (Steamy)
- **Game:** Space Disasters Inc. The launch site is also "Space Disasters Inc." (`GameConfig.BASE_SITE_NAME`, on the base sign).
- **Bodies:** home planet **Earth** (was Kablamo), moon **Mun** (was Dent), sun **Sol** (was Big Toasty).
  - These are display names only. Body ids and code names (`Homeworld`, `Moon`, `Sun`) are unchanged.
  - `/orbit` accepts either name (e.g. `/orbit 10 mun` or `/orbit 10 moon`).
- Earlier entries in this file keep the old names as written at the time.
- **Mars (Steamy's choice: a real solar system):** Earth (with the Mun) and Mars will both orbit Sol, with Sol as the root body. This is a new Phase 7b after time warp, because interplanetary transfers are long. Planned scale: orbits sized so an Earth-to-Mars transfer takes a few minutes at 50× warp.

---

### D40. Phase 11: UI renovation (Steamy)
- **Look:** KSP 1.x, after Steamy's reference photo:
  - dark translucent rounded panels with yellow-green titles;
  - light grey buttons with dark text;
  - gunmetal gauge bezels and plates.
- **Where the look lives:** `UI/Theme` holds the design tokens and DisplayOrders. `UI/Kit` is the widget kit. `UI/KitMath` has the pure helpers.
  - `Kit.screen` returns a ScreenGui plus a design-pixel canvas.
  - The canvas has one UIScale: screen fit (1366x710 reference) times the UI size setting.
- **Global UI state (`UI/UIState`):** whether the menu is open, a set of modals, and `isInputBlocked`.
  - Gameplay input (flight, build, map, chase camera, `Keybinds.isDown`) is ignored while the menu or any modal is open.
  - The character's own PlayerModule controls are disabled too, so Space can't make you jump out of a seat while you rebind keys.
- **Settings:**
  - Shared schema `Config/SettingsSchema`. It is pure and tested, and holds the fields, ranges, the action list with default keys, and the allowed and reserved keys.
  - Client store `Settings/Settings` and `Settings/Keybinds`.
  - Saved by `SettingsController` through the remotes `RequestSettings`, `SettingsData` and `SaveSettings`, into the new optional `settings` field of the existing DataStore entry (SaveService, still DATA_VERSION 1).
  - `SettingsService` validates the JSON size, sanitizes it and rate-limits saves.
  - Future sounds must use the `SoundService.Music` / `SoundService.Effects` SoundGroups, which follow the volume sliders.
- **Keys:** every key action is a named action (`FlightController.performAction` / `setHeld`, `BuildController.performAction`), so phone buttons can call the same code later.
  - The pilot's ContextActionService binding always sinks the old fixed key set (Space, WASD, QE, Shift, Ctrl, ...) plus whatever is rebound. A key that is no longer used still can't reach Roblox's jump.
  - Ctrl+Z (undo), F3 (debug) and Escape are fixed.
- **Main menu (`MainMenuController`, `Render/MenuScene*`, `UI/MainMenu*`):**
  - The scene is client-only, at MENU_ORIGIN (0, -6000, 0).
  - `UniverseRenderer.setViewOverride` draws the real Earth, Mun and Sol around a viewpoint 10 km up. The view is solved so Earth sits low, Sol top-right and the Mun near the top.
  - It shows a clone of the player's own avatar in a floating pose (Motor6D.Transform), up to 3 other players, tumbling junk built from game parts, a satellite, shooting stars, Bloom, SunRays and a GUI lens flare.
  - Play fades through black, about 0.6 s. The builder's Menu button reopens the menu, but not while in flight.
  - If building the menu fails, the controller unlocks the game instead of leaving input blocked.
- **Flight HUD (`UI/FlightHUD`, `UI/HudMath`):**
  - Top centre: an odometer altimeter (SEA LVL / RADAR), an ATMOSPHERE bar and a log VSI needle.
  - Bottom centre: the navball in a bezel with a Surface / Orbit speed plate, a clickable SAS button, the throttle arc and HDG.
  - Right: the stage stack.
  - Bottom left: THR / FUEL gauges and the SAS / LEGS / ENGINES lamps.
  - Key hints come from Keybinds. F2 hides the HUD.
- **End Flight (Steamy: no pause menu, only End Flight with a confirmation):** a new remote, `EndFlight`.
  - **Pilot, or the owner anywhere aboard:** everyone aboard and in the pocket is unseated and placed at their own plot (the server places them, then sends an identity PocketTransfer to base). The craft is removed and the pocket released. The others get "Flight ended by <name>".
  - **Passenger:** "Leave Flight" sends only them home.
  - Rolling out never clears the hangar, so the design stays.
- **Builder:**
  - The UI is split into `BuildUI` plus `BuildCatalog`, `BuildToolbar`, `BuildStaging`, `BuildSlots`, `BuildHints` and `BuildInfo` (pure, tested).
  - KSP staging list on the right: stage 1, the launch stage, at the bottom. Each stage shows dV ASL/Vac, TWR (red if the launch stage is below 1), burn time and chips.
  - A stats card and the ROLL OUT button sit under the list.
  - Clear, overwrite and load-over-a-craft go through `Kit.confirm`.
  - Clicks on the UI never place blocks (`isPointerOverUI`).

### D41. Physics feel: visual-scale aero, engines x1.5, 60 km Earth (Steamy: "the rocket feels too slow for its size")
- **Audit result:** a measured audit found no unit or timing bug.
  - The cause was D20: 4-stud blocks with KSP 1.25 m masses and thrusts.
  - Drag on the full 4 m face was about 13x too strong per kg. The starter rocket was stuck near 70-125 m/s while the ground was in view.
  - Planet size does not change the launch (gravity is 9.81 at any radius); it only sets the orbit speed.
- **Fix (Steamy chose this, plus the bigger planet):**
  - `GameConfig.AERO_METERS_PER_STUD = 0.3`. Every aero area (body drag and fin lift) is multiplied by 0.09 in one place, MassProps. Parachute CdA in Phase 2b must use the same factor.
  - Engines x1.5 with the same Isp: Small Engine 135 kN, Large Engine 600 kN, Solid Booster 292.5 kN (burns for about 22 s).
  - Bodies back to before D27: Earth 60 km (air top 8 km, scale height 1.1 km), Mun 15 km at 450 km. Low orbit is about 710 m/s.
  - Map scales halved. Re-entry heat gate is 600/700 m/s. Anti-cheat MAX_ACCEL is 500.
- **Measured on the sanity rocket:**

  | | Before | After |
  |---|---|---|
  | TWR | 1.9 | 2.9 |
  | Time to 100 m/s | 15.8 s | 5.2 s |
  | Speed at 1 km | 106 m/s | 201 m/s |
  | dV to orbit | 1,187 m/s | 1,082 m/s, 39% fuel left |

- **Pods without chutes still crash:** terminal speed is about 105 m/s, against a crash tolerance of 12. Parachutes (Phase 2b) are still to do.
- **Speed cues:**
  - (a cloud deck was tried and removed: Steamy said it looked bad);
  - trees and rocks right up to the site plate;
  - a vapour cone that can actually trigger (pressure gate 0.005-0.05);
  - chase zoom fitted to the craft size;
  - camera shake from thrust and dynamic pressure, with a "Camera shake" setting;
  - a stronger trail, longer flames;
  - an 80-stud launch tower with beacons.

### D42. Multiplayer fixes after playtest (Steamy)
- **Deploying jumped backwards:** other crafts are sampled INTERP_DELAY (0.1 s) in the past but drawn next to our present craft, so they sat velocity x delay behind (50-70 m in orbit).
  - `StateBuffer.lead` carries the sample to the present with its own velocity, capped at the delay.
  - Crafts on rails are sampled at the present.
- **Boarding a craft whose pilot already sat:**
  - Seats on the cosmetic copy get client ProximityPrompts (`Render/BoardPrompts`).
  - A new remote, `BoardCraft(craftId, seatBlockId)`. The server checks the base pocket, permission, a free seat, speed below 5 m/s and range within radius + 25 m. It then seats the player in the flight pocket and sends an identity PocketTransfer.
  - A one-pod rocket has no free seat; add an External Seat.
- **Seeing players on foot from other pockets:** `Puppets` draws them as animated puppets at their true position (12 nearest, up to 1.5 km, line of sight).
  - Each frame the hidden real character's Motor6D.Transform values are copied to the puppet.

### D43. Effects v2 and one graphics tier (Steamy: "effects still look shitty ... working on mobile ... go with graphics quality")
- **One tier:** `Render/Quality` is the only source of detail.
  - SavedQualityLevel 1-3 is Low, 4-6 Medium, 7-10 High.
  - Automatic is High on PC and Medium on phones and consoles.
  - Phones and consoles never go above Medium.
  - Every costly client layer reads it and reacts to `Quality.onChanged`.
- **Effects:** `Effects`, `EffectsMath` and `Plumes` were reworked.
  - Re-entry plasma: a shock-layer shell on the windward side, flame tongues and streaks downstream along the true air-relative velocity, embers, and windward blocks glowing (Highlight, High only).
  - Plumes by engine type and air pressure. Liquid engines get shock diamonds; solid boosters get a dense orange flame with smoke.
  - Explosions: a core and outer fireball, smoke, sparks and debris.
  - Separation flash, trail, dust and vapour.
  - Only `fire_main` / `smoke_main` / `sparkles_main` textures are used.
- **Budgets:** per-tier budgets live in `EffectsMath.BUDGETS`, including plumes 6/12/24 and burst events per frame.
  - PointLights and Highlights are High only.
  - Engines over the plume budget get a cheap core-and-glow plume.

### D44. Phase 6: EVA, bubbles, boarding
- **Model:** the astronaut is a point with a true position and velocity under the body's real gravity, with light air drag and ground contact.
  - The client sets the HumanoidRootPart every frame (PlatformStand, local Gravity 0).
  - Forward hitches are integrated: up to 30 s in steps, beyond that by Kepler with no thrust or air.
- **Jetpack:** 3 m/s², 60 s of fuel. Fuel is client-side and refills in 4 s while seated.
- **Walking:** only in a pocket that stands still on the ground, with gravity scaled to the body. "Level" is judged against the radial up, not the terrain triangle (D45).
- **Bubbles (BubbleService, 4 Hz, `Sim/Bubbles` is pure):**
  - Merge at 250 m, split at 400 m.
  - Solo pockets are INERTIAL in space or SURFACE_ALIGNED on the ground, with axes from the radial up. They rebase at 300 m.
  - Uncrewed boardable crafts get a real model in a nearby occupied pocket.
  - Nothing merges within 800 m of the base. An astronaut below 150 m and within 600 m of the base goes to the base pocket.
- **Deviations from the spec:**
  1. Absolute state, not an offset.
  2. The root is set directly, not through AlignPosition.
  3. INERTIAL pockets use the D31 horizon/sun axes.
  4. The server decides rebases (no EVARebase remote).
  5. There is no Crew Cabin (D34), so boarding is through seat prompts plus `EvaBoard`, and `crewOf` only counts seated players.
  6. A crewed craft is preferred as a pocket's primary.
  7. End Flight sends home the seated crew plus astronauts whose last craft is this one.
  8. A destroyed pod kills only that craft's seated crew.
  9. Return-to-pad also needs the craft within 600 m of the base.
  10. No fall damage on EVA.
- **Trust:** EVA motion is client-owned. The server only trusts samples that `Eva.plausibleMove` accepts (speed, position and velocity bounds).
- **Not done:**
  - Docking: crafts pass through each other.
  - Walking on a moving craft.
  - Jetpacks on puppets.
  - Landing crafts near the base do not join the base pocket.
  - Touch buttons (named actions are ready).

### D45. Phase 8: surface terrain
- **`Sim/Relief` (shared, deterministic):** heights come from Biome's own fields.
  - Earth: flat oceans at sea level, hills (about ±55 m), ridged mountains up to about 1.4 km.
  - Mun: maria lower, highland roll, crater bowls with rims. Heights clamp to -600..+320 m, under the 500 m rails floor.
  - The site is exactly the base plane within 900 m and blends out by 2.6 km.
- **`SurfaceHeight`:** a fixed ~23 m triangle lattice on the cube-sphere with cached node heights. `height()` returns the height above the triangle under the point and that triangle's normal, so crafts rest on slopes. It is about 2x faster than the old tile version.
- **Client:**
  - `TerrainMath` is a cube-sphere quadtree of 8x8-quad chunks with skirts.
  - `TerrainMesh` makes one EditableMesh per detail band, at most 6 plus 1 being built (S12: about 8 meshes in total, ScaledSpace keeps 1). Bands are built in the background with a per-frame budget and placed uniformly scaled about the camera when needed.
  - `TerrainCollision` builds wedge pairs near the local character.
  - Part plates are the fallback.
- **Budgets:** per tier, Low 180 / Medium 240 / High 320 leaves (about 33k / 45k / 58k triangles).

### D46. Night review (2026-10-02)
- **Reviews:** 5 independent read-only reviews of everything merged in the last day, run in Lune where possible: EVA and bubbles, terrain, effects and phone performance, multiplayer integration, and a full single-player walkthrough. Each finding was verified by the fixer before it was fixed.
- **EVA and multiplayer fixes:**
  - hitch drift (411 m behind after a 0.6 s hitch);
  - slopes and tilted solo pockets now use the radial up;
  - ground friction scales with load, so the jetpack can move you on Earth's ground;
  - an uncrewed craft near the base can be boarded again (it gets a pocket and a real model on demand);
  - End Flight uses each player's last craft;
  - `sendHome` places the character with an absolute destination, so it no longer depends on the lagging server root;
  - only seated players ride along at launch;
  - no double Notifies;
  - EVA plausibility checks;
  - stock-camera zoom capped outside the base;
  - EVA keybind conflicts are prevented, with E reserved on EVA;
  - the chase zoom cap measures from the camera's orbit centre;
  - `/base` uses `sendHome`.
- **Effects and phone fixes:**
  - dust works on hills;
  - plumes are budgeted;
  - the launch-site copy is one welded assembly moved by its root (1004 to 1 writes per frame), with Plots and Decor dropped below High;
  - props are cheaper while flying;
  - site lights only on High (`Render/SiteLights`);
  - prop shadows, menu Bloom/SunRays and ground puppets follow the tier;
  - consoles max Medium;
  - mobile draw distance on Automatic is 1400.
- **Terrain fixes:**
  - `TerrainMath.planStep` never exceeds the mesh budget on camera jumps, and a refused band is probed back every 30 s.
  - The menu view forces scaled mode, so quality 1 no longer thrashes.
  - Band 0 is now a true-scale near band: leaves in a ±760 m square, split to 400 m, as one part.
  - Each band uses the tightest of five frames.
  - The launch-site copy is drawn scaled about the camera like the ground under it, so it shows up to 25 km.
  - Props only go on true-scale ground.
  - Meshes are centred on their exact vertex box.
  - Collision wedges update per cell.
  - Stale meshes stay visible while a plan catches up.
  - The map predicts impacts on the heightmap (opt-in `Rails.predict` terrain).
- **Still open:** objects more than about 1 km away over scaled ground can still be hidden by it, mostly on High. The proper fix is to draw remote crafts, puppets and effects scaled like the ground under them (`TerrainMesh.scaleAt`).

### D47. EVA shake (2026-10-02)
- **Bug (Steamy):** "my character is starting to shake during eva".
- **Cause:** the floating astronaut was placed at RenderStep Camera + 11, after the stock camera (Camera priority). Each frame the camera framed the HumanoidRootPart where the previous physics step had left it (last placement + velocity × physics step, plus contact pushes from limbs touching a hull or terrain wedges), and only then was the root placed and drawn. The camera was off by (relative speed × (the frame's UT step − the physics step)), which grows with speed (jetpack, a craft burning away), plus a jolt per contact.
- **Fix:**
  - `EvaController` runs at Camera − 1, before the camera, and refreshes the pocket frame first. `PocketController.update` now computes the frame once per render frame (marked stale at `RenderPriority.First`, on pocket changes and transfers), so `UniverseRenderer` reuses the same frame.
  - While floating, physics never moves the root: PreSimulation zeroes its velocity, PostSimulation restores the drawn CFrame and the velocity relative to the pocket. That velocity still replicates, so `BubbleService` and `Eva.plausibleMove` read the same position and velocity as before. A transfer in between (pocket or frame epoch changed) cancels the restore.
  - `Eva.turnToward` keeps the facing in [−π, π); `workspace.Gravity` is only written when it really changes.
- **Walking is unchanged:** Roblox physics moves him and the camera follows the root as usual.

### D48. Rocket shudder and orbit shadows (2026-10-02)
- **Bug (Steamy):** "my rocket keeps moving back aswell like shuddering" (mid-air, mostly in the atmosphere, sometimes in space).
- **Cause 1 (main):** the pilot's craft is simulated at a fixed 60 Hz (accumulator, PreSimulation), but the pocket frame followed the LAST step's state, and the terrain, scaled space, sky, sun, other crafts and the effects' air drift are all drawn from that frame. A Lune frame-timing simulation (300 m/s): at 60 FPS with 3% frame-time noise the accumulator sits on the step boundary and 47% of frames ran 0 or 2 steps (ground moved 0, 10, 0, 10 m per frame against the engine-simulated smoke's steady 5 m); at 144 Hz 58% of frames repeated the previous one (5, 0, 0, 5, 0 m), at 240 Hz 75%. The rocket jerked back and forth against the world.
- **Cause 2:** ChaseCamera (Camera + 1) read the craft pose and the frame before UniverseRenderer (Camera + 10) computed them: the previous frame's pose.
- **Cause 3 (contributing):** the camera shake (up to 0.007 rad mid-air, 0.012 rad off the pad, at 9 / 14.5 Hz) read as a shudder in thick air.
- **Fix:** `Shared/Sim/SimInterp` blends the state before the latest step with the current one at alpha = accumulator / STEP (doubles; rotation slerped; no blend across an SOI change, a UT resync or a replaced state). FlightController's primary provider and its Effects report return that render state, so the frame, every pose, the world and the effects use one render UT that advances by the frame's dt (one step of constant latency, no overshoot). PocketController computes the frame at Camera − 2, before every camera (EvaController's and UniverseRenderer's calls reuse it; D47 unchanged). Shake: 0.0015 rad thrust, ×2 at the ground, 0.001 rad q, at 3.5 / 6 Hz with a 4/s response. Streamed (passenger) frames and the server are unchanged.
- **Bug (Steamy, orbit):** "still a shaddow forming": five rocket-shaped shadows on the planet. Above the handover the ground is a ScaledSpace proxy with up to four nested translucent atmosphere shells a few hundred studs away; the true-scale craft's sun shadow landed on the ground proxy and on every shell (one copy per layer, offset along the sun ray). **Fix:** `Render/ShadowGate` owns CastShadow with per-reason suppression; while not in surface mode, UniverseRenderer gates the pocket's folder, RemoteCrafts, the Effects folder and every character (parts touched only on the mode change and when added), and restores every original on the way back down. PocketController's hiding uses the same gate (its own reason), so neither restores the other's stale value.

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
