#!/bin/bash
# Tests run against repository binaries and temporary fixtures, never installed devices.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/slice1-tests
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I Sources/AudioCore/include -I Driver Sources/AudioCore/OBSignal.c Tests/SignalTests.c \
    -o .build/slice1-tests/signal
.build/slice1-tests/signal
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    Tests/DriverTests.c -framework CoreAudio -framework CoreFoundation -o .build/slice1-tests/driver
.build/slice1-tests/driver
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I Sources/AudioCore/include Tests/EngineDiagnosticsTests.c Sources/AudioCore/OBSignal.c \
    -framework AudioToolbox -framework CoreAudio -o .build/slice1-tests/engine-diagnostics
.build/slice1-tests/engine-diagnostics
swift test --scratch-path .build/slice1
