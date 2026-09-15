#!/bin/bash
set -euo pipefail

mkdir -p .build
xcrun swiftc Sources/Models.swift Tests/SyncDataTests.swift -o .build/InputStatsModelTests
.build/InputStatsModelTests

xcrun swiftc Sources/EventStore.swift Tests/EventStoreTests.swift -lsqlite3 -o .build/InputStatsEventStoreTests
.build/InputStatsEventStoreTests

xcrun swiftc Sources/Models.swift Tools/RepairSyncData.swift -o .build/RepairSyncData
repair_tmp=$(mktemp -d /tmp/input-stats-repair-tests.XXXXXX)
trap 'rm -rf "$repair_tmp"' EXIT
cp Tests/Fixtures/carried-sync.json "$repair_tmp/input.json"

before_hash=$(shasum -a 256 "$repair_tmp/input.json" | awk '{print $1}')
.build/RepairSyncData --file "$repair_tmp/input.json" > "$repair_tmp/dry-run.txt"
after_hash=$(shasum -a 256 "$repair_tmp/input.json" | awk '{print $1}')
test "$before_hash" = "$after_hash"
grep -q '2026-09-09: 140 -> 40' "$repair_tmp/dry-run.txt"
grep -q 'Dry run only' "$repair_tmp/dry-run.txt"

.build/RepairSyncData --file "$repair_tmp/input.json" --apply > "$repair_tmp/apply.txt"
test "$(find "$repair_tmp" -maxdepth 1 -name 'typing-stats.backup-*.json' | wc -l | tr -d ' ')" = "1"
grep -q 'Repaired 2 day(s)' "$repair_tmp/apply.txt"
grep -q '"count" : 40' "$repair_tmp/input.json"
grep -q '"count" : 25' "$repair_tmp/input.json"

.build/RepairSyncData --file "$repair_tmp/input.json" > "$repair_tmp/second-run.txt"
grep -q 'No carried daily totals found' "$repair_tmp/second-run.txt"
echo 'InputStats repair CLI tests: passed'
