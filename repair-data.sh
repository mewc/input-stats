#!/bin/bash
set -euo pipefail

mkdir -p .build
xcrun swiftc Sources/Models.swift Tools/RepairSyncData.swift -o .build/RepairSyncData
.build/RepairSyncData "$@"
