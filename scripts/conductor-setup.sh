#!/bin/zsh
set -euo pipefail

if [[ "${CONDUCTOR_IS_LOCAL:-0}" != "1" ]]; then
    echo "Input Stats cloud checkout is local-only; skipping in a cloud workspace."
    exit 0
fi

cloud_dir=".context/input-stats-cloud"
mkdir -p .context

if [[ -d "$cloud_dir/.git" ]]; then
    echo "Refreshing existing input-stats-cloud checkout..."
    git -C "$cloud_dir" fetch origin --prune
else
    if ! command -v gh >/dev/null 2>&1; then
        echo "GitHub CLI is required to clone the private input-stats-cloud repository."
        exit 1
    fi
    echo "Cloning private input-stats-cloud checkout..."
    gh repo clone mewc/input-stats-cloud "$cloud_dir"
fi

echo "Installing locked cloud dependencies..."
npm --prefix "$cloud_dir" ci

echo "Input Stats workspace is ready."
