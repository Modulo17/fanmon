#!/bin/bash
# Local build + smoke test — run manually:  ./check.sh
#
# Compiles into a temp dir and exercises the CLI paths, so it does NOT touch
# build/ or disturb a running menu bar instance. No network, no signing, no CI.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/fanmon"
fail=0
step() { printf '▸ %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

step "Compile (warnings treated as errors)"
if swiftc -O -warnings-as-errors \
     -import-objc-header bridge/fanmon-bridge.h \
     -framework Cocoa -framework IOKit \
     Sources/main.swift -o "$bin" 2>"$tmp/build.log"; then
  ok "compiles clean"
else
  bad "compile failed:"; cat "$tmp/build.log"; exit 1
fi

step "Smoke: --dump reads sensors"
if out=$("$bin" --dump 2>&1) && grep -q '^FANS' <<<"$out" && grep -q 'SENSORS' <<<"$out"; then
  ok "sensor readout produced"
else
  bad "--dump did not produce expected output:"; printf '%s\n' "$out"
fi

step "Smoke: --render draws the panel"
if "$bin" --render "$tmp/panel.png" >/dev/null 2>&1 && [ -s "$tmp/panel.png" ]; then
  ok "panel PNG rendered ($(wc -c <"$tmp/panel.png" | tr -d ' ') bytes)"
else
  bad "panel render failed"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m✅ All checks passed.\033[0m\n'
else
  printf '\033[31m❌ Some checks failed.\033[0m\n'; exit 1
fi
