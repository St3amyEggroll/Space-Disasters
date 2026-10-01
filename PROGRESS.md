# PROGRESS

| Phase | Status |
|---|---|
| 0: Project setup and engine spikes | **Done. All spikes S1–S12 recorded in DECISIONS.md; Q1 answered (A)** |
| 1: Base and builder | **Built (Plane Crazy rework). Waiting for Steamy's playtest** |
| 2a: Flight in the pocket (fly, stage, crash) | **Built. Waiting for Steamy's playtest** |
| 2b: Chutes, legs, landing rebase, recovery | Not started |
| 3: Multiplayer crafts | Not started |
| 4: Scaled space and visuals | Started early: scaled-space bodies, sky and lighting came with 2a (D26) |
| 5: Orbits, rails, map, navball | Not started |
| 6: EVA, bubbles, boarding | Not started |
| 7: Time warp | Not started |
| 8: Surface terrain | Not started |
| 9: Polish and backlog | Not started |

Phase 2 is split into 2a/2b so you can playtest halfway through (agreed with Steamy).

---

## Phase 2a: what was built

- **Launch** (reworked after Steamy's feedback, see D28):
  - **ROLL OUT** puts your rocket on a pad and puts you straight into its Command Pod. With no pod, it tells you to add one.
  - The rocket is live on the pad, with real physics. Throttle, SAS and steering work, and a wobbly rocket can tip over.
  - Press **Space** to light the engines. **F** before ignition puts you back beside the pad, so friends can board, and sitting down again restarts.
  - The rocket flies in its own **flight pocket** (a separate area of the server map that follows the craft). Everyone seated rides along.
- **Spawning:** you spawn on your own plot.
- **Flight model (KSP-style, `Shared/Sim/FlightModel`):**
  - Gravity from Kablamo and Dent.
  - Thrust with engine gimbal, and a per-tank fuel map (fuel flows within a stage segment).
  - Drag from the atmosphere (`Shared/Sim/Atmosphere`), with nose cones helping. Fins give lift and stability.
  - Ground contact, and crashes: any block that hits harder than its crash tolerance breaks off.
  - SAS holds your heading.
- **The world while flying** (planets are now half size, D27, and much prettier, D30):
  - Big Toasty, Kablamo and Dent are drawn as textured spheres in the sky. Kablamo has oceans, continents, deserts, forests, mountains, ice caps, clouds and an atmosphere glow. Dent has craters and dark seas.
  - Near the ground: matching textured terrain colours, plus trees, pines, cacti, bushes and rocks (boulders and crater rims on Dent), and a copy of Oopsie Point, so you can see the base as you leave.
  - The sun moves with the day cycle. When it's below the horizon you get the "shadow side" look (Q1 = A). The sky darkens as you climb out of the air.
- **Staging:**
  - Space fires the next stage (the stage list is fixed at launch).
  - Decoupled parts become **debris** that keeps falling (the server simulates it) until it crashes.
- **Flight HUD:** altitude, speed, vertical speed, throttle, SAS, fuel, current stage with Δv/TWR, and key hints.
- **Camera (D29):** like the normal Roblox camera (right-drag orbits, the wheel zooms), but it never turns with the rocket.
  - In the air, "up" is away from the planet. In space, "up" is square to the solar plane, and it blends smoothly between the two.
  - **V** switches to the stock camera.
- **Plumes:** engine flames when burning.
- **Multiplayer basics:** other players' rockets and debris are shown in your pocket, smoothed over the network.
- **Debug commands** (Studio only):
  - `/orbit 20` puts your rocket in a circular 20 km orbit. `/orbit 10 dent` orbits Dent.
  - `/fuel` refills the tanks.
  - `/base` takes you back to base.
- **F3 overlay:** new lines for your pocket, flight and universe, plus per-layer timings.
- **Tests:** 79 offline tests (new: Universe, FlightModel, Protocol, Biome, launch-site platforms).

## Phase 2a: how to test

**Rebuild the place first** (new settings and scripts). In PowerShell in the repo folder:
```
git pull
rojo build -o SpaceDisasters.rbxl
rojo serve
```
Open the new `SpaceDisasters.rbxl`, click **Connect** in the Rojo plugin, then **Play**.

> If the Output warns about `EditableMesh` / "Allow Mesh / Image APIs": turn on **Game Settings > Security > Allow Mesh / Image APIs** (it needs a published place). Until then the planets are drawn as plain balls, which is fine for testing.

**Flight keys:**

| Key | Does |
|---|---|
| Space | light the engines, then fire the next stage |
| Shift / Ctrl | throttle up / down |
| Z / X | full / zero throttle |
| W / S | pitch |
| A / D | yaw |
| Q / E | roll |
| T | SAS on/off |
| V | camera: level orbit / stock Roblox |
| F | leave the seat (before ignition: step off back to the pad) |

1. **Spawn:** you should appear on your own plot.
2. **Build the sanity rocket:** Small Engine, Small Tank Long, Small Decoupler, Command Pod, Parachute. Press **ROLL OUT**. You land straight in the pod on a pad.
3. **No pod:** build something without a pod and press ROLL OUT. It should say you need a Command Pod.
4. **On the pad:** press X then Shift (the throttle moves on the HUD), T for SAS, and wiggle W/A/S/D. The rocket stays put. Press **F**: you're beside the pad, and the rocket is back to normal. Sit in the pod again (E).
5. **Launch:** press **Space**. It lifts off, and the camera stays level with the horizon as the rocket tilts.
6. **Steer:** tap **D** to lean over a little, then **T** to hold it with SAS.
7. **Stage:** when the tank runs dry, press **Space**. The empty tank and engine fall away as debris.
8. **Look around:** high up, Kablamo should have oceans, continents and clouds. The textures paint in over about 15 seconds, so it starts out a plain colour. Near the ground you should see trees and rocks.
9. **Crash:** let the pod hit the ground. It breaks, and you respawn on your plot.
10. **Orbit:** launch again, and once you're flying type `/orbit 15` in chat. The camera's "up" turns to the solar plane. Look for Dent.
11. **Fuel and base:** try `/fuel` and `/base`.
12. **F3:** check the pocket, flight and universe lines, and that FPS is OK.

Please paste back anything red in the Output, plus anything that looks or feels wrong.

## Phase 1: what was built (Plane Crazy-style rework, see DECISIONS D20)

- **Base (Oopsie Point Launch Complex):**
  - 12 open plots, each a raised 80×80-stud baseplate: 20×20 blocks with a 4-stud grid drawn on it, and room to build 50 blocks tall.
  - The plots sit either side of the street, with a shared **launch area** of 8 pads to the north (follow the road through the gap in the north row).
  - The site is 948 parts.
- **Plots:** assigned on join (your name is on the plot sign) and freed on leave.
- **Builder (on your own plot):**
  - Tools: **Build (B)**, **Paint (P)**, **Delete (X)**.
  - **R/T** rotate. **1/2/4** give radial symmetry off/2/4. **M** cycles mirror X → Z → X+Z → off. **Ctrl+Z** undoes.
  - The part panel has category tabs and 3D previews. There's a 16-colour paint palette.
  - The live stats card shows mass, parts, per-stage Δv/TWR and warnings.
- **Server validation:** plot owner only, inside the build volume, no overlap, ≤ 250 blocks, ≤ 20 ops/s, and every new block must touch the craft. Only the first block sits on the baseplate by itself. Paint is validated too.
- **All 23 parts** are sized in blocks. The Crew Cabin (2×2×2 blocks) has a walkable interior and a hatch.
- **Save/load:** 10 slots, plus your plot is restored when you rejoin.
- **Roll Out:** puts your rocket on a free launch pad, replacing your previous rocket. If every pad is taken, it says so.
- **Seats and hatches:** Pilot/Sit prompts on seats, Enter/Exit on the cabin hatch, and the Boarding toggle (Public/Friends/Private).
- **Tests:** 53 offline tests.

## Phase 1: how to test

**Rebuild the place** (the base layout changed). In PowerShell in the repo folder:
```
git pull
rojo build -o SpaceDisasters.rbxl
rojo serve
```
Open the new `SpaceDisasters.rbxl`, click **Connect**, then **Play**.

1. **Find your plot:** your name is on one plot's sign. Walk up the little ramp onto your baseplate, and the builder UI appears.
2. **Build the sanity rocket**, bottom to top: **Small Engine** on the baseplate, then **Small Tank Long**, **Small Decoupler**, **Command Pod**, **Parachute**. Stats should read about **4.15 t**, stage 1 about **2,100 m/s**, **TWR ≈ 1.9**.
3. **Paint:** press **P**, pick a colour, and click blocks. Ctrl+Z undoes the paint.
4. **Mirror and radial:** press **M** and place fins on the tank's side; the mirrored copies appear on the other side. Try **2**/**4** too.
5. **Invalid spots** show a red ghost and an error message.
6. **Save/Load:** name it, Save, Clear (click twice), then Load.
7. **ROLL OUT:** follow the road north to the launch area. Your rocket is on one of the numbered pads.
8. **Cabin:** build a **Crew Cabin**, roll out, press **E** on the door to go in, sit, press Space, then Exit.
9. **Two players:** you see each other's building live, and Boarding: Private blocks the other player.

## Phase 0: what was built

- Rojo project (`default.project.json`) with the Section 4 layout, plus these project settings:
  - `StreamingEnabled = false`
  - `FallenPartsDestroyHeight = -20000`
  - `Lighting.Technology = Future` (baked in by `rojo build`; `rojo serve` cannot set it)
  - A server-side ground plate (`BaseGround`) and a spawn (`BaseSpawn`) at slot 0
- `Shared/Config`:
  - `GameConfig`: every global tunable from Appendix B, plus Section 8 limits
  - `Bodies`: Big Toasty (Sun), Kablamo (Homeworld), Dent (Moon), with the Section 6.1 values. The Moon's SOI (~72,200 m) and period (~10,090 s) are derived from the other values.
  - `Parts`: all 23 parts from Section 6.2, with Isp/thrust helpers
- `Shared/Math`:
  - `Vec3d`: doubles, with both allocating and out-param APIs, and rotation done in doubles
  - `Frames`: universe ↔ pocket transforms, rebase transforms, surface frames. Both are complete.
- `Shared/Sim/UniverseTime`: the UT clock, following the server's anchors.
- `Shared/Util/Loader`: runs `Init` then `Start` on every module in a fixed boot order, and warns loudly about unlisted or broken modules.
- Server:
  - `Bootstrap.server.luau`
  - `TimeService`: creates `ReplicatedStorage.Globals` and the UT anchors, with `SetWarpRate` and re-anchoring
  - `Tests/`: `TestKit`, the `RunTests` runner, and 4 spec files
- Client:
  - `Bootstrap.client.luau`
  - `DebugOverlay` (F3): UT, warp, FPS, net in/out, ping, memory, part counts, character position. Later systems add their own lines and timings.
- `spikes/`: the separate spike place for S1–S10 (see below).
- `tools/` + GitHub Actions CI: stylua, rojo build, strict `luau-lsp` type check, and the tests running offline under Lune.

## Phase 0: how to test

### Place setup (once)

In PowerShell, in the repo folder:
```
rojo build -o SpaceDisasters.rbxl
rojo build spikes.project.json -o Spikes.rbxl
```
These place files already have `Lighting.Technology = Future`, `StreamingEnabled = false`, and the ground and spawn. Nothing needs setting by hand.

### Game place

1. Open `SpaceDisasters.rbxl`, run `rojo serve`, click **Connect** in the Rojo plugin, then **Play** (Play Solo).
2. The Output should show, with **no red errors**:
   - `[Server] booted 1 module(s) in ... ms`
   - `[Client] booted 1 module(s) in ... ms`
   - `[Tests] ... 24 passed, 0 failed` (about 1 s after start)
3. You spawn on the orange pad on a big grey plate.
4. Press **F3**. The debug overlay appears top-left. UT counts up (`T+ 00:00:05.0`), warp is 1x, and FPS, net, memory and part counts all update.
5. Stop. **Test > Clients and Servers**, 2 players, **Start**. Check both client windows and the server window for zero errors. F3 works in each client, and both clients show nearly the same UT (within a few hundredths of a second).

### Spike place (results go in `DECISIONS.md`)

1. Open `Spikes.rbxl`, run `rojo serve spikes.project.json --port 34873`, set the Rojo plugin's port to 34873, and click **Connect**.
2. Press **Play**. Click **Spike menu** (top right). Hover a spike to read its instructions, then click it to run it.
3. Some spikes need **2 players**: **S3**, **S9**. For those, use Test > Clients and Servers with 2 players and start the spike from either client window.
4. Answer the on-screen questions as they appear.
5. When you're done, copy every line that starts with `[SPIKE` from the **Server** Output window (in Play Solo there's just one Output) and paste it all back to Claude. Also copy any warnings or errors you see, especially for S6 (EditableMesh) and S7 (payload limits).

| Spike | Players | Needs your eyes? |
|---|---|---|
| S1 render distance | 1 | Yes. Run it at graphics quality 1, 5 and 10. |
| S2 LocalTransparencyModifier | 1 | Yes |
| S3 client gravity | 2 | No, it's automatic |
| S4 SkyboxOrientation | 1 | Yes |
| S5 sun direction solve | 1 | 3 questions at the end |
| S6 EditableMesh | 1 | A few questions |
| S7 unreliable payload limit | 1 | No, it's automatic |
| S8 replication ordering | 1 | No, it's automatic |
| S9 seated character + PivotTo | 2 | 2 questions |
| S10 jitter at 12,000 studs | 1 | Yes. Walk around. |
| S11 cull distance (follow-up) | 1 | Pick each quality level; the rest is automatic |
| S12 EditableMesh budget + sharing (follow-up) | 1 | 1 question |

## Playtest log

- 2026-09-30, Play Solo (Steamy): both bootstraps booted and Studio printed `[Tests] 24 passed, 0 failed` with no errors.
- 2026-09-30, spikes S1–S10 (Steamy): all ran to completion, including the 2-player S3 and S9. Results are in `DECISIONS.md`. Two harness issues were fixed: S5 started twice on a double click, and the spike lock now waits for every client to finish.
- 2026-09-30, follow-up spikes S11 (cull distance) and S12 (EditableMesh budget/sharing) (Steamy): results and decisions D10/D11 are in `DECISIONS.md`.
- 2026-10-01, first Phase 2a flights (Steamy): spawn on your plot; Roll Out should seat you in the pod (or say you need one); live controls and physics on the pad; a camera that doesn't turn with the rocket (gravity up in the air, the solar plane in space); a smaller planet that looks much better. All done; see D27–D30.

## Known issues

- **The Phase 2a feedback changes (launch flow, camera, smaller and prettier planets) have not been played in Studio yet.** Everything passes the offline checks (formatting, strict types, 79 tests).
- **Planet textures take a moment:** about 15 s (Kablamo) and 18 s (Dent) of background painting after joining. If they look mirrored inside each square, flip `UV_FLIP_V` in `Biome.luau` (D30).
- **Water is solid** for now. Landing in the sea counts as landing on ground.
- **Low graphics quality:** between about 8 km altitude and the scaled-space handover, the ground can look thin or empty at the lowest quality levels (the engine culls far parts, S11). To be tuned after the playtest.
- **No parachutes, legs, landing or recovery yet.** That's Phase 2b, so every flight ends in a crash or `/base`.
