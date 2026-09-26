#!/bin/bash
# Exercises a test window and a fake login service; never captures audio or registers login items.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -swift-version 6 -parse-as-library \
    Sources/OpenBlue/DesktopLifecycle.swift Tests/DesktopLifecycleTests.swift \
    -o .build/tests/desktop-lifecycle
.build/tests/desktop-lifecycle
