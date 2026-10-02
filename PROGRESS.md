# PROGRESS

| Phase | Status |
|---|---|
| 0: Project setup and engine spikes | **Done. All spikes S1–S12 recorded in DECISIONS.md; Q1 answered (A)** |
| 1: Base and builder | **Built (Plane Crazy rework). Waiting for Steamy's playtest** |
| 2a: Flight in the pocket (fly, stage, crash) | **Done** (played and tuned with Steamy; part remodel D34) |
| 2b: Chutes, legs, landing rebase, recovery | Skipped for now (Steamy) |
| 3: Multiplayer crafts | **Built. Waiting for Steamy's playtest** (D35) |
| 4: Scaled space and visuals | Started early: scaled-space bodies, sky and lighting came with 2a (D26) |
| 5: Orbits, rails, map, navball | **Built. Waiting for Steamy's playtest** (D36) |
| 6: EVA, bubbles, boarding | **Built. Waiting for Steamy's playtest** (D44) |
| 7: Time warp | Not started (Steamy: wait) |
| 7b: Solar system: Mars (Steamy) | Not started (Steamy: wait, decide tomorrow). Earth (with the Mun) and Mars both orbit Sol; fly Earth to Mars with transfer orbits. Comes after time warp, because the trip is long |
| 8: Surface terrain | **Built. Waiting for Steamy's playtest** (D45) |
| 9: Polish and backlog | Not started |
| 10: Effects (Steamy) | **Built, then reworked (Effects v2, D43). Waiting for Steamy's playtest** |
| 11: UI renovation (Steamy) | **Built. Waiting for Steamy's playtest** (D40). Also the physics feel change (D41) and multiplayer fixes (D42) |

Phase 2 is split into 2a/2b so you can playtest halfway through (agreed with Steamy).

---

## Night of 2026-10-02: what was built (see D43-D46)
- **Effects v2 (D43):**
  - Re-entry plasma: a glowing shell, flame tongues, embers and hot parts.
  - Engine plumes: liquid engines get shock diamonds, boosters a thick orange flame.
  - Better explosions, smoke, dust and vapour.
  - Everything follows one graphics tier (`Render/Quality`: Low / Medium / High; phones max Medium).
- **Phase 6, EVA (D44):**
  - F gets you out of your seat in flight.
  - Float with a jetpack: WASD, Space and Ctrl move you, R brakes against the nearest craft, L is the helmet light. The jetpack has its own fuel bar, which refills when you sit.
  - Walk and hop on the ground, including the Mun.
  - Board any free seat, including empty rockets.
  - Rockets and astronauts within 250 m share a pocket (they split again past 400 m).
  - "Return to plot" button.
- **Phase 8, terrain (D45):**
  - Earth: real hills, mountains and valleys, matching the map colours. Oceans are flat.
  - Mun: craters and seas.
  - The launch site stays flat and blends into the hills.
  - Rockets settle on slopes.
  - Detail follows the graphics tier. Part plates are the fallback if EditableMesh is off.
- **Night review (D46):** 5 independent reviews (EVA, terrain, effects and phone performance, multiplayer, full play-through) found about 40 problems. Each was checked, then fixed. Details in D46.

## Night of 2026-10-02: how to test
1. **Effects:**
   - Launch at graphics quality 10. Look for the bright flame, shock diamonds near the ground and a pale plume in space.
   - Get into orbit (`/orbit 15`), burn backwards until the periapsis is below 4 km, and watch the plasma from about 8 km down.
   - Do it again at quality 1: it should be a simpler version.
2. **EVA:**
   - In orbit, press F. You float above the pod.
   - Fly with WASD, Space and Ctrl. R stops you, L is the light.
   - Fly over 1 km away and back.
   - Press E on the pod's Pilot prompt to get back in.
   - Try "Return to plot".
3. **EVA on the Mun:** land on the Mun (`/orbit 10 mun`, then descend, or `/hover 100 mun`), press F, walk, and hold Space to hop.
4. **Terrain:**
   - From the base, hills start about 1 km out.
   - Fly low over Earth and land on a hill (`/hover 50`): the rocket should rest tilted, not slide.
   - Land in a Mun crater.
   - F3 shows a "Terrain:" line.
5. **Two players:**
   - Launch separately and meet within 250 m: both rockets become solid for each other.
   - Float across and board a free seat.
   - A player who lands near the base, gets out and walks away can still board the rocket again.

## Phase 11: what was built (see D40, D41, D42)
- **Main menu:** your avatar floats in space with junk, a satellite, the Mun, shooting stars and sun glare. The buttons are Play (Enter), Settings, and Credits / Updates.
- **Settings:** all saved to your account.
  - Controls & Camera: mouse sensitivity, invert Y, camera smoothing, camera shake, rebind every key.
  - Interface: UI size, Show HUD (F2), units, hints.
  - Audio: music and effects volume.
- **Flight HUD (KSP layout):**
  - Top centre: the altimeter wheels and the ATMOSPHERE bar.
  - Bottom centre: the navball with the speed plate, the SAS button, the throttle arc and HDG.
  - Right: the stage stack.
  - Bottom left: THR / FUEL and the lamps.
  - Top right: End Flight (Leave Flight for passengers) with a confirmation.
- **Builder:**
  - Left: the parts catalog.
  - Top: the toolbar, including Menu and Settings.
  - Right: the KSP staging list, the stats card and ROLL OUT.
- **Physics feel:**
  - lighter air drag and engines x1.5;
  - Earth back to 60 km (orbit about 710 m/s);
  - trees by the pads, the vapour cone, camera fit and shake, a taller tower.
- **Multiplayer:**
  - Dropped stages no longer jump backwards.
  - Players on the ground can board your rocket after you sit (you need a free seat, e.g. an External Seat).
  - Players on foot show up while you fly.

## Phase 11: how to test
1. **Menu:** join. It fades in from black and you see your avatar floating, Earth below, the sun top-right, junk and shooting stars. WASD should not move you.
2. **Settings:**
   - Move the sliders and rebind a key (click it, press the new key; Escape cancels).
   - Switch Units to Imperial.
   - Rejoin: the settings should still be there.
3. **Play:** a quick fade, then you're on your plot with the builder.
   - Click buttons over the baseplate: no blocks should be placed.
   - The Menu button goes back to space.
4. **Builder:**
   - Build the sanity rocket. The staging list shows STAGE 1 (launch) at the bottom with TWR about 2.9.
   - Clear asks first.
   - Save and Load work.
5. **Flight:**
   - Roll Out and press Space. It should leave the pad fast (100 m/s in about 5 s), with the camera rumbling.
   - The altimeter wheels roll. The vapour cone shows near the speed of sound.
   - Orbit is about 710 m/s at 10 km.
6. **HUD:**
   - F2 hides it.
   - Clicking SAS lights it green.
   - End Flight, then Cancel does nothing. End Flight, then End Flight sends you to your plot with the rocket gone.
7. **Two players (Test > Clients and Servers):**
   - Player 1 builds a pod plus an External Seat and rolls out.
   - Player 2 walks up and presses Sit, and boards.
   - Launch: player 2 can Leave Flight.
   - Fly alone and look down: the other player walks around at the base.
8. **Deploy:** in orbit, stage off a payload in front of you. It should drift away smoothly, with no jump backwards.

## Phase 10: what was built (see D38)

- **Engine flames:**
  - Near the ground they are short, tight and bright. As you climb they stretch into a long, faint cone that keeps opening up in space.
  - Solid boosters have fatter, yellower, smokier flames.
  - When an engine lights it flashes, with a few sparks. When it cuts out it leaves a puff of smoke.
- **Smoke trail:** burning engines leave a trail of smoke in the air. It is thick for boosters, thin for liquid engines, and fades out as you climb (gone above about 5.5 km).
- **Launch and landing dust:** below about 40 m, the engines blow a ring of dust across the ground. It takes the ground's colour, and is white spray over the sea. It gets stronger the lower and harder you burn.
- **Staging:** every decoupler that fires gives a white puff, sparks and a quick flash.
- **Crashes:** every part that breaks explodes, with a fireball, fire and smoke, glowing bits flying off, a flash of light, and the classic Roblox explosion.
- **Re-entry:** coming back fast from orbit, the front of the rocket glows orange and pink, with flame streaks running back along it. A normal launch doesn't glow.
- **Breaking the sound barrier:** a quick white vapour cone around the rocket, low down only.
- **Everyone sees the same effects** on every rocket and piece of debris. Passengers now also see their own rocket's flames.
- **Performance:** everything is reused and capped, and there are fewer particles at low graphics quality. F3 shows a new "Effects:" line and an "Effects" timing.
- **No sounds yet:** they need uploaded sound ids (a follow-up).

## Phase 10: how to test

Rebuild and connect as usual (`git pull`, `rojo build -o SpaceDisasters.rbxl`, `rojo serve`).

1. **Launch:** build a rocket with a Solid Booster stage under a liquid stage. Sit, press Space.
   - Flash and sparks at ignition, then a thick smoke column and a ring of dust on the pad.
   - The dust fades as you climb past about 40 m.
2. **Climb:** the smoke trail streams away below you and fades out around 4–5 km. The flame gets longer and wider as the air thins, and becomes a wide faint cone in space.
3. **Throttle:** press X. The liquid flame goes out with a puff of smoke; Z relights it with a flash. Boosters can't be throttled.
4. **Staging:** press Space when the booster burns out. A white puff and sparks at the decoupler, and the booster falls away.
5. **Re-entry:** `/orbit 15`, then burn retrograde (backwards) until the orbit dips into the air. Coming down through about 6 km, the rocket's front glows orange-pink with streaks. It fades as you slow down.
6. **Crash:** fly into the ground. Every broken part explodes (fireball, smoke, glowing bits, flash).
7. **Two players (Test > Clients and Servers):** each sees the other's flames, trail, dust, staging puffs and explosions. A passenger on an External Seat sees the flames too.
8. **Map (M) and far away:** effects hide with the rocket, and come back without a flash.
9. **Low graphics quality:** fewer particles, but everything still shows. F3 shows the "Effects:" line, and the "Effects" timing stays well under 1 ms.

Please tell us what looks too strong, too weak, or wrong. Every number is a tunable at the top of `Render/Effects.luau` and `Render/EffectsMath.luau`.

## Phase 3: what was built (see D35)

- **Bandwidth:** each player hears about nearby rockets 20 times a second, rockets around the same planet 2 times a second, and everything else every 2 seconds. It's capped at 20 KB/s per player, and F3 shows your share.
- **Remote rockets** move smoothly. If updates stop coming, they keep coasting briefly, then freeze.
- **Markers** show the rocket's name (owner) and distance when it's too far to draw. They hide behind planets.
- **Puppets:** you can see other players sitting in their rockets, even when the rockets are in a different flight area from yours.
- **Leaving the seat after launch:** the server keeps flying the rocket, with the throttle cut. Sitting back in the pod takes control again.
- **Passengers:** they ride along on External Seats.
- **Late joiners** see every rocket, including rockets sitting on pads.

## Phase 3: how to test (Test > Clients and Servers, 4 players)

1. **A flies with B aboard:**
   - A rolls out (auto-seated), then presses F (the rocket goes back to the pad).
   - B sits on an External Seat. A sits in the pod again.
   - Both should launch together, and B gets the passenger HUD. Space ignites.
2. **C at the base**, near the pad: C is not pulled into the rocket. The launch looks smooth, and B's puppet is visible in the seat.
3. **Far away:** past about 3–30 km, the rocket becomes a marker with name and distance. It hides behind the planet.
4. **C launches separately:** A and C see each other's rockets.
5. **Hand-over:**
   - After ignition, A presses F. The rocket coasts with the flames out.
   - A sits back in the pod and gets control again, with the right stage and fuel.
   - Also try A dying, and A leaving the game.
6. **Late joiner D:** joins mid-flight and sees every rocket, marker and puppet.
7. **F3 on every client:** "Streams in: CraftStates … KB/s" stays at or below 20.

## Phase 5: what was built (see D36)

- **Orbit maths** (Kepler) and **"on rails" coasting:**
  - When you're out of the air, not burning and not steering for 0.5 s, the rocket follows its exact orbit. No network updates are sent and there's no drift.
  - Any key or thrust puts you back in normal flight.
- **Gravity zones:** moving into and out of Mun's zone works in both directions while coasting.
- **Debris:** orbiting debris stays. Falling debris far from everyone is cleaned up.
- **HUD:** apoapsis and periapsis with the time to each, plus a **navball** with prograde and retrograde markers and heading and pitch.
- **Map view (M):**
  - Shows Earth, Mun, your orbit, other rockets' orbits, Ap/Pe markers, and the predicted path into and out of Mun's zone.
  - Drag to turn, the wheel zooms, click to focus. M or Esc closes it.

## Phase 5: how to test

1. Sit in your rocket on the pad and type `/orbit 15`. In about half a second the navball shows **ON RAILS**.
   - Ap and Pe both read about 15 km, and their timers count down.
   - F3: network traffic drops.
2. Press W: rails end right away. Let go: rails resume after about 0.5 s. With SAS on, it holds its attitude on rails.
3. Press **M** in orbit: you should see your orbit as a cyan circle, Mun with its zone and orbit, and Ap/Pe markers.
   - Drag, scroll and click all work, and you can still steer.
   - M closes the map.
4. **Navball:** pitch and yaw. Heading and pitch read sensibly, and prograde follows your velocity.
5. **Mun:**
   - Burn prograde until the map shows an orange path into Mun's zone. Coast, and the HUD body pill switches to Mun.
   - `/orbit 10 mun`, then burn to escape and watch it switch back to Earth.
6. **Debris:** stage a booster in orbit; it stays, and a second player sees it.
7. **Late join:** coasting rockets show up right away for new players.

## Phase 2a: what was built

- **Launch** (reworked after Steamy's feedback, see D28):
  - **ROLL OUT** puts your rocket on a pad and puts you straight into its Command Pod. With no pod, it tells you to add one.
  - The rocket is live on the pad, with real physics. Throttle, SAS and steering work, and a wobbly rocket can tip over.
  - Press **Space** to light the engines. **F** before ignition puts you back beside the pad, so friends can board, and sitting down again restarts.
  - The rocket flies in its own **flight pocket** (a separate area of the server map that follows the craft). Everyone seated rides along.
- **Spawning:** you spawn on your own plot.
- **Flight model (KSP-style, `Shared/Sim/FlightModel`):**
  - Gravity from Earth and Mun.
  - Thrust with engine gimbal, and a per-tank fuel map (fuel flows within a stage segment).
  - Drag from the atmosphere (`Shared/Sim/Atmosphere`), with nose cones helping. Fins give lift and stability.
  - Ground contact, and crashes: any block that hits harder than its crash tolerance breaks off.
  - SAS holds your heading.
- **The world while flying** (Earth is 60 km again, D41, and much prettier, D30):
  - Sol, Earth and Mun are drawn as textured spheres in the sky. Earth has oceans, continents, deserts, forests, mountains, ice caps, clouds and an atmosphere glow. Mun has craters and dark seas.
  - Near the ground: matching textured terrain colours, plus trees, pines, cacti, bushes and rocks (boulders and crater rims on Mun), and a copy of Space Disasters Inc., so you can see the base as you leave.
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
  - `/orbit 20` puts your rocket in a circular 20 km orbit. `/orbit 10 mun` orbits Mun.
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
8. **Look around:** high up, Earth should have oceans, continents and clouds. The textures paint in over about 15 seconds, so it starts out a plain colour. Near the ground you should see trees and rocks.
9. **Crash:** let the pod hit the ground. It breaks, and you respawn on your plot.
10. **Orbit:** launch again, and once you're flying type `/orbit 15` in chat. The camera's "up" turns to the solar plane. Look for Mun.
11. **Fuel, base and time:** try `/fuel`, `/base`, and `/time 0` (midnight), `/time 6`, `/time 12` (noon).
12. **F3:** check the pocket, flight and universe lines, and that FPS is OK.

Please paste back anything red in the Output, plus anything that looks or feels wrong.

## Phase 1: what was built (Plane Crazy-style rework, see DECISIONS D20)

- **Base (Space Disasters Inc.):**
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
  - `Bodies`: Sol (Sun), Earth (Homeworld), Mun (Moon), with the Section 6.1 values. The Moon's SOI (~72,200 m) and period (~10,090 s) are derived from the other values.
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
- 2026-10-01 (Steamy): space looks good. Skip 2b. Delete the Crew Cabin and Ladder; remodel the pod (keep it simple), engines, booster (flat top), adapter, decouplers and nose cones; add an animated landing leg. Done in D34.
- 2026-10-01, fifth Phase 2a check (Steamy, at 13.7 km): space is black with stars, the sun and Mun. The blue sky showed through wedge-shaped gaps between the sky panels: they were aimed at the camera instead of lying flat in the cube faces. Fixed.
- 2026-10-01, fourth Phase 2a check (Steamy): the sky was Roblox's default cloud sky turned on its side, and space still wasn't black. Fixed in D33 (Roblox's sky kept upright for the ground; SkyCube draws black starry space; `/time` debug command).
- 2026-10-01, third Phase 2a flight (Steamy): the sky no longer followed the rocket, but space stayed blue and the ground showed a blue/grey split sky. The rocket was invisible, with only a "Sit" prompt showing. Fixed in D32 (we paint the whole sky; models arriving in your pocket are un-hidden).
- 2026-10-01, second Phase 2a flight (Steamy): all 79 tests passed in Studio. Problems: the sky split into two halves and followed the rocket; no black space; the engine flame stayed lit at 0% throttle. Fixed in D31.
- 2026-10-01, first Phase 2a flights (Steamy): spawn on your plot; Roll Out should seat you in the pod (or say you need one); live controls and physics on the pad; a camera that doesn't turn with the rocket (gravity up in the air, the solar plane in space); a smaller planet that looks much better. All done; see D27–D30.

## Known issues

- **Second round of feedback (sky, flames):** fixed in D31. The flight area now follows the planet's horizon, so the sky no longer tilts with the rocket, space turns black and starry, and flames go out at zero throttle. Not yet played in Studio.
- **Clouds are off:** Roblox doesn't let game scripts paint them (Studio warning), so Earth has no cloud layer for now.
- **The Phase 2a feedback changes (launch flow, camera, smaller and prettier planets) have not been played in Studio yet.** Everything passes the offline checks (formatting, strict types, 79 tests).
- **Planet textures take a moment:** about 15 s (Earth) and 18 s (Mun) of background painting after joining. If they look mirrored inside each square, flip `UV_FLIP_V` in `Biome.luau` (D30).
- **Water is solid** for now. Landing in the sea counts as landing on ground.
- **Low graphics quality:** between about 8 km altitude and the scaled-space handover, the ground can look thin or empty at the lowest quality levels (the engine culls far parts, S11). To be tuned after the playtest.
- **No parachutes, legs, landing or recovery yet.** That's Phase 2b, so every flight ends in a crash or `/base`.
