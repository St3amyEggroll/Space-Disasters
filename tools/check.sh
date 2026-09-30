#!/usr/bin/env bash
# Runs every offline check: formatting, Rojo builds, strict type checking, and the pure-Luau test suite.
# Usage: tools/check.sh            (run tools/setup.sh first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.tools/bin"
OUT="$ROOT/.tools/out"
mkdir -p "$OUT"
cd "$ROOT"

echo "== stylua =="
"$BIN/stylua" --check src spikes tools

echo "== rojo build =="
"$BIN/rojo" build default.project.json -o "$OUT/SpaceDisasters.rbxl"
"$BIN/rojo" build spikes.project.json -o "$OUT/Spikes.rbxl"

echo "== luau-lsp analyze (game) =="
"$BIN/rojo" sourcemap default.project.json -o "$OUT/sourcemap.json"
"$BIN/luau-lsp" analyze \
	--definitions="$ROOT/.tools/globalTypes.d.luau" \
	--sourcemap="$OUT/sourcemap.json" \
	--no-strict-dm-types \
	src

echo "== luau-lsp analyze (spikes) =="
"$BIN/rojo" sourcemap spikes.project.json -o "$OUT/spikes.sourcemap.json"
"$BIN/luau-lsp" analyze \
	--definitions="$ROOT/.tools/globalTypes.d.luau" \
	--sourcemap="$OUT/spikes.sourcemap.json" \
	--no-strict-dm-types \
	spikes

echo "== lune tests =="
"$BIN/lune" run tools/run-tests "$OUT/sourcemap.json"

echo "All checks passed."
