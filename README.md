# Space Disasters Inc.

A multiplayer rocket game for Roblox. You build rockets Plane Crazy–style and fly them KSP-style: staging, fuel, orbits, the Moon. Along the way you walk around inside crafts, go on EVA with a jetpack, and board other players' ships.

The build spec lives in the project brief. Progress and test steps are in [`PROGRESS.md`](PROGRESS.md). Engine findings and deviations from the spec are in [`DECISIONS.md`](DECISIONS.md).

## Bodies

| Code name | In-game name | What it is |
|---|---|---|
| Sun | **Sol** | The sun. It's for lighting and looks only. |
| Homeworld | **Earth** | The home planet. The launch site, **Space Disasters Inc.**, is on its equator. |
| Moon | **Mun** | A crater-covered moon, about 37 minutes away by transfer burn. |

Display names live in `src/shared/Config/Bodies.luau` and `GameConfig.BASE_SITE_NAME`. Rename them there any time; code uses the ids.

## Setup (Windows, Studio + Rojo 7.4)

Run these in a terminal (PowerShell) opened in the repo folder.

**Game place**
```
rojo build -o SpaceDisasters.rbxl      # once: makes a place file with every project setting applied
rojo serve                             # every session: live-syncs code into Studio
```
1. Open `SpaceDisasters.rbxl` in Studio. It's git-ignored.
2. In Studio, open the Rojo plugin and click **Connect**.
3. Press **Play**. See `PROGRESS.md` for what to expect.

`rojo build` applies `Lighting.Technology = Future` and `StreamingEnabled = false`. `rojo serve` can't set Technology, which is why the build step comes first. Re-run `rojo build` only when you want a fresh place.

**Spike place (Phase 0 only)**

This is a separate throwaway place, so it never touches the game.
```
rojo build spikes.project.json -o Spikes.rbxl
rojo serve spikes.project.json --port 34873
```
1. Open `Spikes.rbxl`.
2. In the Rojo plugin, set the port to **34873** and click **Connect**.
3. Press Play and use the **Spike menu** button (top right).

The different port lets both `rojo serve` commands run at the same time. Otherwise, stop one with Ctrl+C before starting the other.

## Layout

```
src/shared  -> ReplicatedStorage.Shared                         config, math, sim (runs on both sides)
src/server  -> ServerScriptService.Server                       services, tests
src/client  -> StarterPlayer.StarterPlayerScripts.Client        controllers
spikes/     -> separate place via spikes.project.json           Phase 0 engine experiments
tools/      -> offline checks (Linux/CI): format, build, strict type check, Lune tests
```

Server **services** and client **controllers** are ModuleScripts with `Init()` and `Start()`. Each side has one bootstrap (`Bootstrap.server.luau` / `Bootstrap.client.luau`) with a `BOOT_ORDER` list. Add every new module to that list.

## Offline checks

CI runs these on every push:

```
tools/setup.sh   # downloads rojo, luau-lsp, lune, stylua into .tools/
tools/check.sh   # stylua --check, rojo build (game + spikes), luau-lsp strict analyze, Lune test run
```

The same `*.spec.luau` tests run in Studio (Play Solo prints `[Tests] ...`) and offline under Lune.
