#!/bin/bash
# Uses synthetic signals and a compiled local model; never opens audio devices.
set -euo pipefail
cd "$(dirname "$0")/.."
model="${1:-.build/products/release/OpenBlue.app/Contents/Resources/DPDFNet8.mlmodelc}"
state="Resources/Models/DPDFNet/initial-state.f32"
if [ ! -d "$model" ]; then
    echo 'Build Release first or pass the path to DPDFNet8.mlmodelc.' >&2
    exit 2
fi
mkdir -p .build/tests
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -mmacosx-version-min=15.0 \
    -I Sources/NeuralNoiseReduction/include Sources/NeuralNoiseReduction/OBNeural.m \
    Tests/NeuralTests.c -framework Foundation -framework CoreML -framework Accelerate \
    -o .build/tests/neural
.build/tests/neural "$model" "$state"
