# Part preview

A 3D viewer of every part, built from the game's own `PartVisuals` code (offline, via Lune).

```
.tools/bin/rojo sourcemap default.project.json -o .tools/out/sourcemap.json
.tools/bin/lune run tools/export-parts .tools/out/sourcemap.json new.json
python3 tools/part-preview/build.py tools/part-preview/current.json new.json out.html cdn   # or "local"
```

- `current.json`: the part looks before the Phase 2a remodel (for side-by-side comparison).
- Landing legs are also exported in their stowed pose (`leg_stowed`).
- `shot.mjs`: headless screenshots (`local` builds need `npm install three@0.160.0` next to the page).
