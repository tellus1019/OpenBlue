#!/bin/bash
# Tests run against repository binaries and temporary fixtures, never installed devices.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Sources/AudioCore/OBDSP.c Tests/DSPTests.c \
    -framework Accelerate -o .build/tests/dsp
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Sources/AudioCore/OBDSP.c Tests/DSPLatencyTests.c \
    -framework Accelerate -o .build/tests/dsp-latency
.build/tests/dsp-latency
.build/tests/dsp
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Sources/AudioCore/OBDSP.c Tests/DSPNoiseTests.c \
    -framework Accelerate -o .build/tests/dsp-noise
.build/tests/dsp-noise
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Tests/DSPFFTTests.c \
    -framework Accelerate -o .build/tests/dsp-fft
.build/tests/dsp-fft
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Tests/DSPActivityTests.c \
    -framework Accelerate -o .build/tests/dsp-activity
.build/tests/dsp-activity
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Sources/AudioCore/OBDSP.c Sources/AudioCore/OBWorker.c \
    Tests/DSPAdvancedTests.c -framework Accelerate -framework AudioToolbox -o .build/tests/dsp-advanced
.build/tests/dsp-advanced
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I Sources/AudioCore/include -I Driver Sources/AudioCore/OBSignal.c Sources/AudioCore/OBWorker.c Sources/AudioCore/OBDSP.c -framework Accelerate Tests/SignalTests.c \
    -framework AudioToolbox -o .build/tests/signal
.build/tests/signal
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Tests/SignalClockTests.c \
    Sources/AudioCore/OBWorker.c Sources/AudioCore/OBDSP.c \
    -framework Accelerate -framework AudioToolbox -o .build/tests/signal-clock
.build/tests/signal-clock
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Sources/AudioCore/OBSignal.c Sources/AudioCore/OBWorker.c \
    Sources/AudioCore/OBDSP.c Tests/SignalAdvancedTests.c -framework Accelerate \
    -framework AudioToolbox -o .build/tests/signal-advanced
.build/tests/signal-advanced
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    Tests/DriverTests.c -framework CoreAudio -framework CoreFoundation -o .build/tests/driver
.build/tests/driver
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I Sources/AudioCore/include Tests/EngineDiagnosticsTests.c Sources/AudioCore/OBSignal.c Sources/AudioCore/OBWorker.c Sources/AudioCore/OBDSP.c -framework Accelerate \
    -framework AudioToolbox -framework CoreAudio -o .build/tests/engine-diagnostics
.build/tests/engine-diagnostics
swift test --scratch-path .build/openblue
