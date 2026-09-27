#!/bin/bash
# Build repository artifacts only. This script never changes the host environment.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2;; esac
test "$(uname -m)" = arm64
destination=".build/products/$configuration"
case "$configuration" in debug) xcode_configuration=Debug ;; release) xcode_configuration=Release ;; esac
xcodebuild -project OpenBlue.xcodeproj -scheme OpenBlue \
    -configuration "$xcode_configuration" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/xcode \
    CONFIGURATION_BUILD_DIR="$PWD/$destination" build
mkdir -p "$destination/OpenBlue.driver/Contents/MacOS"
cp Resources/Driver-Info.plist "$destination/OpenBlue.driver/Contents/Info.plist"
optimization=-O0
if [ "$configuration" = release ]; then optimization=-O2; fi
xcrun clang -std=c11 "$optimization" -g -arch arm64 -mmacosx-version-min=15.0 \
    -Wall -Wextra -Werror -Wno-unused-parameter -fvisibility=hidden -bundle \
    Driver/OpenBlueDriver.c -framework CoreAudio -framework CoreFoundation \
    -o "$destination/OpenBlue.driver/Contents/MacOS/OpenBlueDriver"
codesign --force --sign - "$destination/OpenBlue.driver"
codesign --verify --strict "$destination/OpenBlue.driver"
codesign --verify --strict "$destination/OpenBlue.app"
printf 'Built %s\n' "$destination"
