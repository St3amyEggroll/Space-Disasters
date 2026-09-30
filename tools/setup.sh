#!/usr/bin/env bash
# Downloads the Linux command-line toolchain used by tools/check.sh and CI into .tools/.
# Not needed for normal Studio + Rojo development on Windows.
set -euo pipefail

# ---- Tunables -------------------------------------------------------------
ROJO_VERSION="7.4.4"
LUAU_LSP_VERSION="1.70.1"
LUNE_VERSION="0.10.4"
STYLUA_VERSION="2.5.2"
# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.tools/bin"
mkdir -p "$BIN"

fetch_zip() {
	local url="$1" name="$2"
	if [ -x "$BIN/$name" ]; then
		return
	fi
	local tmp
	tmp="$(mktemp -d)"
	curl -sSfL -o "$tmp/pkg.zip" "$url"
	unzip -o -q "$tmp/pkg.zip" -d "$tmp"
	find "$tmp" -type f -name "$name" -exec mv {} "$BIN/$name" \;
	chmod +x "$BIN/$name"
	rm -rf "$tmp"
}

fetch_zip "https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_VERSION}/rojo-${ROJO_VERSION}-linux-x86_64.zip" rojo
fetch_zip "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${LUAU_LSP_VERSION}/luau-lsp-linux-x86_64.zip" luau-lsp
fetch_zip "https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-linux-x86_64.zip" lune
fetch_zip "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-linux-x86_64.zip" stylua

if [ ! -f "$ROOT/.tools/globalTypes.d.luau" ]; then
	curl -sSfL -o "$ROOT/.tools/globalTypes.d.luau" \
		"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LUAU_LSP_VERSION}/scripts/globalTypes.None.d.luau"
fi

echo "Toolchain ready in $BIN"
