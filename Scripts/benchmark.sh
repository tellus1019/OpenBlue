#!/bin/bash
# Offline kernel timing only; no microphone, app launch, installation or service changes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/benchmark
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
    -I Sources/AudioCore/include Tests/DSPBenchmark.c -framework Accelerate \
    -o .build/benchmark/normal
.build/benchmark/normal
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -DOB_DSP_PROFILE \
    -I Sources/AudioCore/include Tests/DSPBenchmark.c -framework Accelerate \
    -o .build/benchmark/instrumented
.build/benchmark/instrumented
