#!/usr/bin/env python3
"""build.py CURRENT.json [NEW.json|-] OUT.html [local|cdn] -- inline part data into the hangar page."""
import sys, json
cur, new, out = sys.argv[1], sys.argv[2], sys.argv[3]
mode = sys.argv[4] if len(sys.argv) > 4 else 'local'
here = __file__.rsplit('/', 1)[0]
t = open(here + '/template.html').read()
c = open(cur).read().replace('</', '<\\/')
n = 'null' if new == '-' else open(new).read().replace('</', '<\\/')
three = 'node_modules/three/build/three.min.js' if mode == 'local' else 'https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js'
t = t.replace('__CURRENT__', c).replace('__NEW__', n).replace('__THREE__', three)
if mode == 'local':
    t = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}</style></head><body>' + t + '</body></html>'
open(out, 'w').write(t)
print('wrote', out, len(t), 'bytes')
