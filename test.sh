#!/bin/bash
set -euo pipefail

mkdir -p .build
xcrun swiftc Sources/Models.swift Tests/SyncDataTests.swift -o .build/InputStatsModelTests
.build/InputStatsModelTests
