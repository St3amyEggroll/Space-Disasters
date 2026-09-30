# PROGRESS

| Phase | Status |
|---|---|
| 0: Project setup and engine spikes | **Spikes S1–S10 done (see DECISIONS.md). Q1 answered (A). Waiting on follow-up spikes S11/S12** |
| 1: Base and builder | Not started |
| 2a: Flight in the pocket (fly, stage, crash) | Not started |
| 2b: Chutes, legs, landing rebase, recovery | Not started |
| 3: Multiplayer crafts | Not started |
| 4: Scaled space and visuals | Not started |
| 5: Orbits, rails, map, navball | Not started |
| 6: EVA, bubbles, boarding | Not started |
| 7: Time warp | Not started |
| 8: Surface terrain | Not started |
| 9: Polish and backlog | Not started |

Phase 2 is split into 2a/2b so you can playtest halfway through (agreed with Steamy).

---

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

## Known issues

- None yet. Spikes may turn up engine limits. Those will be recorded in `DECISIONS.md` before Phase 1 starts.
