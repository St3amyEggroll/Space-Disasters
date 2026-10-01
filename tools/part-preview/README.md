# Part preview

A 3D viewer of every part, built from the game's own `PartVisuals` code (offline, via Lune).

```
.tools/bin/rojo sourcemap default.project.json -o .tools/out/sourcemap.json
.tools/bin/lune run tools/export-parts .tools/out/sourcemap.json new.json
python3 tools/part-preview/build.py tools/part-preview/current.json new.json out.html cdn   # or "local"
```

- `current.json`: the part looks before the remodel (for side-by-side comparison).
- `remodel-wip.patch`: the unfinished part remodel. It's parked here so the game is untouched until the new look is approved. Apply it with `git apply tools/part-preview/remodel-wip.patch`.
- `shot.mjs`: headless screenshots (`local` builds need `npm install three@0.160.0` next to the page).
