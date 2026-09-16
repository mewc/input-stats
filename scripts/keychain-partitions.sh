#!/bin/bash
# Inspect (and repair) the partition lists on the app's Keychain items.
#
#   ./scripts/keychain-partitions.sh           # show what's there now
#   ./scripts/keychain-partitions.sh --apply   # repin them to the signing Team ID
#
# Why this exists: every Keychain item carries an ACL "partition list" naming the
# code allowed to read it without prompting. Code signed by an Apple-issued
# certificate partitions as `teamid:<TEAM>`, which is stable for the life of the
# certificate. Self-signed and ad-hoc code has no team, so macOS falls back to
# `cdhash:<hash>` — which changes on *every build*. That is why a rebuilt app
# re-prompts for each of its items, and why clicking "Always Allow" never sticks:
# it appends one more dead cdhash instead of generalising.
#
# So the fix is not this script, it's signing with a Developer ID certificate.
# This script just migrates the existing items over afterwards, so you don't have
# to click through one last round of prompts to get there.
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICES=("com.mewc.input-stats.cloud" "com.mewc.input-stats.cloud.dev")
# `cloudCredentials` is the consolidated item (v0.3.3+); the rest are the legacy
# per-value items, still listed so a machine that has not migrated yet reports.
ACCOUNTS=("cloudCredentials" "deviceToken" "signingSecret" "serverDeviceID" "pendingPairingVerifier")

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

# Prefer a real Apple-issued identity; a team is the whole point of the exercise.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
        | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)
fi

# The Team ID is the parenthesised suffix of the identity name.
TEAM_ID=""
if [ -n "$IDENTITY" ]; then
    TEAM_ID=$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
fi

echo "Signing identity: ${IDENTITY:-<none Apple-issued; still self-signed>}"
echo "Team ID:          ${TEAM_ID:-<none — partitions will stay cdhash-pinned>}"
echo

show_partitions() {
    xcrun swift - "$@" <<'SWIFT' 2>/dev/null
import Foundation
import Security

let services = ["com.mewc.input-stats.cloud", "com.mewc.input-stats.cloud.dev"]
let accounts = ["cloudCredentials", "deviceToken", "signingSecret", "serverDeviceID", "pendingPairingVerifier"]

func hexToString(_ hex: String) -> String? {
    var data = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        guard let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex),
              let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
        data.append(byte)
        i = j
    }
    return String(data: data, encoding: .utf8)
}

for service in services {
    print("\(service):")
    var found = false
    for account in accounts {
        var item: SecKeychainItem?
        guard SecKeychainFindGenericPassword(nil,
                UInt32(service.utf8.count), service,
                UInt32(account.utf8.count), account,
                nil, nil, &item) == errSecSuccess,
              let item else { continue }
        found = true
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              case var aclsCF = Optional<CFArray>.none,
              SecAccessCopyACLList(access, &aclsCF) == errSecSuccess,
              let acls = aclsCF as? [SecACL] else { continue }
        var partitions: [String] = []
        for acl in acls {
            let tags = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard tags.contains("ACLAuthorizationPartitionID") else { continue }
            var appsCF: CFArray?
            var desc: CFString?
            var sel = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &appsCF, &desc, &sel) == errSecSuccess,
                  let hex = desc as String?, let plist = hexToString(hex) else { continue }
            for line in plist.split(separator: "\n") where line.contains("<string>") {
                partitions.append(line
                    .replacingOccurrences(of: "<string>", with: "")
                    .replacingOccurrences(of: "</string>", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        print("  \(account): \(partitions.isEmpty ? "<no partition list>" : partitions.joined(separator: ", "))")
    }
    if !found { print("  (no items — this environment has never signed in)") }
}
SWIFT
}

if [ "$APPLY" != true ]; then
    show_partitions
    echo
    echo "Run with --apply to repin these to the Team ID."
    exit 0
fi

if [ -z "$TEAM_ID" ]; then
    echo "Nothing to repin to: no Apple-issued signing identity is installed." >&2
    echo "Install a Developer ID Application certificate first, then re-run." >&2
    exit 1
fi

# `apple:` keeps first-party tooling (Keychain Access, security) working on these
# items; without it you lock yourself out of inspecting them by hand.
PARTITIONS="teamid:$TEAM_ID,apple:"
echo "Repinning to: $PARTITIONS"
echo "macOS will ask for your login password once to authorise the ACL change."
echo

for service in "${SERVICES[@]}"; do
    for account in "${ACCOUNTS[@]}"; do
        if ! security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
            continue
        fi
        security set-generic-password-partition-list \
            -S "$PARTITIONS" -s "$service" -a "$account" >/dev/null
        echo "  repinned $service / $account"
    done
done

echo
show_partitions
