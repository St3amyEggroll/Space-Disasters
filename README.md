# Space Disasters

A multiplayer rocket game for Roblox. You build rockets Plane Crazy–style and fly them KSP-style: staging, fuel, orbits, the Moon. Along the way you walk around inside crafts, go on EVA with a jetpack, and board other players' ships.

The build spec lives in the project brief. Progress and test steps are in [`PROGRESS.md`](PROGRESS.md). Engine findings and deviations from the spec are in [`DECISIONS.md`](DECISIONS.md).

## Bodies

| Code name | In-game name | What it is |
|---|---|---|
| Sun | **Big Toasty** | The sun. It's for lighting and looks only. |
| Homeworld | **Kablamo** | The home planet. The launch site, **Oopsie Point Launch Complex**, is on its equator. |
| Moon | **Dent** | A crater-covered moon, about 37 minutes away by transfer burn. |

Display names live in `src/shared/Config/Bodies.luau` and `GameConfig.BASE_SITE_NAME`. Rename them there any time; code uses the ids.

## Setup (Windows, Studio + Rojo 7.4)

1. Install the Rojo 7.4 Studio plugin and CLI.
2. In Studio, make a new **Baseplate** place.
3. Delete `Workspace.Baseplate` and `Workspace.SpawnLocation`. The project supplies its own ground and spawn.
4. Set `Lighting.Technology = Future` by hand. `rojo serve` can't set it, because scripts can't write that property.
5. Save the place as `SpaceDisasters.rbxl`. Anywhere works; if you keep it in the repo folder, git ignores `*.rbxl`.
6. In the repo folder, run `rojo serve`. In Studio, open the Rojo plugin and click **Connect**.
7. Press **Play**. See `PROGRESS.md` for what to expect.

### Engine spikes (Phase 0 only)

The spikes run in a separate throwaway place, so they never touch the game.

1. Make another new **Baseplate** place and set `Lighting.Technology = Future`.
2. Run `rojo serve spikes.project.json`. Stop the game's `rojo serve` first, or add `--port 34873` and point the plugin at that port.
3. Connect, press Play, and use the **Spike menu** button (top right).

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
