# Space Disasters Inc. — notes for Claude

A KSP-style multiplayer Roblox rocket game. It's built with Rojo and strict Luau.

The owner is **Steamy** (GitHub St3amyEggroll), a young player:
- He writes short, simple English and tests everything himself in Roblox Studio on Windows.
- Answer him the same way: short, simple words, no jargon, plain step lists.

The working branch is `claude/fervent-bardeen-6a86j6`. It is the only branch; there is no `main` yet.

Read these first:
- **`DECISIONS.md`** (D1–D53): how everything works and why. The newest work is D45–D53 (terrain, solar system, map, far-ground backdrop).
- **`PROGRESS.md`**: the phase table and "how to test" lists.

## Conventions (keep them)
- **File format:**
  - `--!strict` in every file.
  - A `Tunables` block at the top of each file.
  - Mark edits with `-- CHANGED (<tag>): <reason>`.
  - Match the surrounding comment density.
  - Complete code: no stubs and no TODOs.
- **The 200-locals limit:** Roblox refuses any function or chunk with more than 200 locals. That once broke 9 controllers in Studio ("Out of local registers").
  - `TerrainMesh.luau` is at that limit, so put new tunables in a table there.
  - `tools/compile-check.luau` catches this offline.
- **Controllers** use `Init` / `Start`.
- **Before every commit:** run `bash tools/check.sh`. It must **exit 0** and print "All checks passed."
  - Don't pipe away its exit code.
  - It runs stylua, rojo build, strict luau-lsp, the compile check and about 410 Lune specs.
  - Pure logic gets a Lune spec in `src/server/Tests/*.spec.luau`.
- **Docs:** keep `DECISIONS.md` and `PROGRESS.md` updated.
- **Commits:**
  - Commit and push only finished, checked work. Never commit half-done work.
  - No model names in code, docs or commit messages.
- **Studio tests:** `GameConfig.RUN_TESTS` is false, so specs don't run when you press Play in Studio. They yield between tests when it's turned on.
- **Windows tooling:** `tools/setup.sh` downloads Linux builds of stylua, rojo, luau-lsp and lune into `.tools/bin`. On Windows, use Git Bash and Windows builds of those four tools (for example through rokit or aftman), placed in `.tools/bin`. Or skip the script and run the same steps by hand.

## How Steamy tests
He gets new code with this in PowerShell:
```
cd C:\Users\pkend\Space-Disasters
git pull
rojo serve
```
Then he connects Rojo in Studio and presses Play. If `git pull` asks "Unlink of file … (y/n)", answer **n**.

He sends screenshots and Output logs. Ask him for the **F3** overlay and for `[Terrain]` / `[FarLayer]` Output lines.

**Lesson learned:** offline audits and mocks said things were fixed several times when they weren't in Studio. **Verify in Studio**, now with the Roblox Studio MCP, before telling him something is fixed.

## Debug commands and keys
- **Chat commands** (Studio, or `GameConfig.DEBUG_USER_IDS`):
  - `/orbit <km> [earth|mun|mars|sol]`
  - `/hover <m> [body]`
  - `/fuel`, `/base`
  - `/time <hour>`
  - `/bands`: tints the terrain bands. Band 1 is blue, 2 red, 3 yellow, further bands magenta; plates are white and the site copy is cyan.
  - `/farground`: switches between the backdrop layer and the old "mesh" drawing.
  - `/farground test`: reference objects plus labelled panels, and it prints panel state.
  - `/farground tex`: turns the backdrop copies' white texture on or off.
  - `/farground probe`: test objects that show which kinds of GUI and ViewportFrame Roblox draws (`Render/LayerProbe`).
- **Keys:**
  - **F3**: debug overlay, including the Terrain and Far layer lines, timings and the longest frame.
  - **F7** or the green ADMIN button: admin panel. It spawns your ship in orbit or landed on Sol, Earth, the Mun or Mars.
  - **M**: map.
  - **F2**: hide the HUD.
  - **F** in flight: EVA.

## Steamy's decisions (standing)
- **Physics:** Earth is 60 km across, with thin "visual scale" air and engines ×1.5 (D41).
- **Clouds:** the 3D clouds were removed ("look bad").
- **Mobile and graphics quality:** everything must work on phones, not be too heavy, and follow graphics quality (`Render/Quality`: Low, Medium or High; phones and consoles max out at Medium).
- **Solar system:** **Sol, Earth, the Mun and Mars only** (D51). No axial tilt: every equator lies in the orbit plane (D51b).
- **Time warp:** on hold until Steamy says otherwise. The admin panel spawns ships in orbit or landed on any body instead.
- **Map planets** (D52): real surfaces, a night side lit from Sol, an atmosphere rim, and dots with names when zoomed out.
- **Heat effects** (not built yet): parts get **redder the hotter they get**, NASA-style plasma, and **no lingering scorch** after re-entry.
- **Cars:** waiting on Steamy's pick. Options were rover wheel parts (recommended), ready-made cars at the base, a base shuttle, or both.
- **Parachutes:** "later". Pods currently crash on every landing.
- **Sounds:** need sound IDs from Steamy.

## The far-ground problem (current focus, D45–D53)
**Symptom:** far terrain showed through nearer terrain (grey or dark "slabs", "seeing through the earth"), mostly at medium distance, around mountains and craters.

**Cause:** far terrain bands are drawn shrunk toward the camera (Roblox's draw distance and part-size limits), while the near band is true scale. So ground hidden behind a nearer ridge gets drawn *in front* of it. Four rounds of geometry fixes (D49–D51a, depth maps, culling) reduced it but can't remove it.

**Real fix: the KSP-style backdrop layer** (`Render/FarLayer.luau`, `FarLayerMath.luau`, D53).
- Far ground is drawn inside ViewportFrames on 6 camera-centred panels at about 1020 studs, so all real 3D geometry is in front of it.
- **Key Studio finding:**
  - A SurfaceGui parented to its part draws Frames and labels but **never draws its ViewportFrame**.
  - Parented to the **PlayerGui with Adornee = the part**, it does, at any distance.
  - Found with `/farground probe`.
- **Smooth version** (commit 1c13069):
  - The backdrop scene stays still and only the face cameras move.
  - Redraws happen only past a 0.5 px change.
  - Seam light matching (`SEAM_GAIN`).
  - Build slicing yields before going over budget.
  - F3 shows ms, writes per frame and peaks.
  - **Default: layer on Medium and High, mesh on Low.**
- **Still to verify in Studio:**
  - no jitter;
  - no far ground swimming against the near band;
  - the seam colour matches by day, dusk and night;
  - no magenta horizon line;
  - no gaps after band rebuilds;
  - Earth stays behind the Mun's hills (D51a / `ScaledSpace.setGroundReach`);
  - the Mun's sky is black with stars.
- **Mesh mode on Low** still has a little horizon jitter (depth-map drift and snap).

## Other things to check in Studio
- **Map dark side and rim** (D52 fix: limb disc, night image on a camera-facing SurfaceGui).
- **Flight clouds:** they use the same see-through MeshPart texture trick that failed for the old map shell, so they may be invisible.
- **Mars, the admin panel and Sol** (D51): sky colour on Mars, landings at the Big Volcano, Big Canyon and North Ice Cap, End Flight from Mars.

## Backlog
1. Parachutes (Phase 2b).
2. Heat system (see Steamy's decisions above).
3. Cars or rovers.
4. Touch buttons for phones.
5. Sounds.
6. Time warp (on hold).
7. Docking.
8. Walking on moving rockets.
