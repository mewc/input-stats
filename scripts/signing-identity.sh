#!/bin/bash
# Print the best available code-signing identity, or "-" for ad-hoc.
#
# Order matters, and not for the usual reasons. An Apple-issued certificate
# carries a Team ID, and macOS partitions Keychain items by `teamid:` whenever it
# has one — stable for the life of the certificate. Self-signed certificates have
# no team, so items get pinned to `cdhash:` instead, which changes on every build
# and re-prompts for every item. See scripts/keychain-partitions.sh.
#
# Respects an explicit $SIGNING_IDENTITY, so CI and one-off builds still win.
set -euo pipefail

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    printf '%s' "$SIGNING_IDENTITY"
    exit 0
fi

identities=$(security find-identity -p codesigning 2>/dev/null || true)

# Distribution-grade: notarisable, and what release builds should carry.
match=$(printf '%s' "$identities" | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)

# A free Apple ID issues these. Not valid for distribution, but it has a team,
# which is all the Keychain cares about.
[ -z "$match" ] && match=$(printf '%s' "$identities" | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)

# Self-signed fallbacks: stable signature (so the Accessibility grant survives
# rebuilds) but no team, so Keychain prompts persist.
if [ -z "$match" ]; then
    for fallback in "${SELF_SIGNED_FALLBACK:-}" InputStats-Dev InputStats-Release; do
        [ -z "$fallback" ] && continue
        if printf '%s' "$identities" | grep -q "$fallback"; then
            match="$fallback"
            break
        fi
    done
fi

printf '%s' "${match:--}"
