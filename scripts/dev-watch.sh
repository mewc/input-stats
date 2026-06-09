#!/bin/bash
# `bun dev` entry point: build + install + relaunch the Dev app, then rebuild and
# relaunch on every Swift source change. Ctrl-C to stop.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v fswatch >/dev/null 2>&1; then
    echo "❌ fswatch not found. Install it once with:  brew install fswatch"
    echo "   (or run a one-off build with: bun run build)"
    exit 1
fi

echo "▶  initial build…"
./dev.sh

echo ""
echo "👀 watching Sources/ Package.swift Info.plist — save to rebuild. Ctrl-C to stop."
echo "------------------------------------------------------------------"

# -o batches rapid saves into a single event so we don't rebuild N times per save.
fswatch -o Sources Package.swift Info.plist | while read -r _; do
    echo ""
    echo "🔁 change detected — rebuilding…"
    if ./dev.sh; then
        echo "✅ relaunched. Still watching…"
    else
        echo "❌ build failed — fix it and save again."
    fi
done
