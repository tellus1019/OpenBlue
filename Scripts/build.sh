#!/bin/bash
# Build repository artifacts only. This script never changes the host environment.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2;; esac
test "$(uname -m)" = arm64
swift build --scratch-path .build/slice1 --configuration "$configuration"
binary_dir="$(swift build --scratch-path .build/slice1 --configuration "$configuration" --show-bin-path)"
destination=".build/products/$configuration"
mkdir -p "$destination/OpenBlue.app/Contents/MacOS" "$destination/OpenBlue.driver/Contents/MacOS"
cp "$binary_dir/OpenBlue" "$destination/OpenBlue.app/Contents/MacOS/OpenBlue"
cp Resources/App-Info.plist "$destination/OpenBlue.app/Contents/Info.plist"
cp Resources/Driver-Info.plist "$destination/OpenBlue.driver/Contents/Info.plist"
optimization=-O0
if [ "$configuration" = release ]; then optimization=-O2; fi
xcrun clang -std=c11 "$optimization" -g -arch arm64 -mmacosx-version-min=14.0 \
    -Wall -Wextra -Werror -Wno-unused-parameter -fvisibility=hidden -bundle \
    Driver/OpenBlueDriver.c -framework CoreAudio -framework CoreFoundation \
    -o "$destination/OpenBlue.driver/Contents/MacOS/OpenBlueDriver"
codesign --force --sign - "$destination/OpenBlue.driver"
codesign --force --sign - "$destination/OpenBlue.app"
codesign --verify --strict "$destination/OpenBlue.driver"
codesign --verify --strict "$destination/OpenBlue.app"
printf 'Built %s\n' "$destination"
