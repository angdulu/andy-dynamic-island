#!/bin/bash
set -euo pipefail

WHISPER_VERSION=v1.9.5
WHISPER_COMMIT=d1be6fde11ac6e0407606b4e42fe72d34add8037
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DESTINATION=${1:-"$PROJECT_ROOT/DynamicIsland/Vendor/Whisper"}
BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/andy-whisper.XXXXXX")
trap 'rm -rf "$BUILD_ROOT"' EXIT

git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$BUILD_ROOT/source"
test "$(git -C "$BUILD_ROOT/source" rev-parse HEAD)" = "$WHISPER_COMMIT"

cmake -S "$BUILD_ROOT/source" -B "$BUILD_ROOT/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6 \
    -DCMAKE_INSTALL_PREFIX="$BUILD_ROOT/install" \
    -DCMAKE_INSTALL_RPATH='@loader_path' \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_IS_DEV=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON
cmake --build "$BUILD_ROOT/build" --parallel 4
cmake --install "$BUILD_ROOT/build"

mkdir -p "$BUILD_ROOT/runtime"
cp "$BUILD_ROOT/install/bin/whisper-server" "$BUILD_ROOT/install/bin/whisper-cli" "$BUILD_ROOT/runtime/"
cp -P "$BUILD_ROOT/install/lib/"libggml*.dylib "$BUILD_ROOT/install/lib/"libwhisper*.dylib "$BUILD_ROOT/runtime/"
cp "$BUILD_ROOT/source/LICENSE" "$BUILD_ROOT/runtime/LICENSE"
for binary in "$BUILD_ROOT/runtime/"*; do
    if [ -f "$binary" ] && [ ! -L "$binary" ] && [ "$(basename "$binary")" != LICENSE ]; then
        codesign --force --sign - "$binary"
    fi
done
"$BUILD_ROOT/runtime/whisper-server" --help >/dev/null
"$BUILD_ROOT/runtime/whisper-cli" --help >/dev/null

# Preserve the separately downloaded Silero VAD model while replacing the runtime as a unit.
if [ -f "$DESTINATION/ggml-silero-v5.1.2.bin" ]; then
    cp "$DESTINATION/ggml-silero-v5.1.2.bin" "$BUILD_ROOT/runtime/"
else
    cp "$PROJECT_ROOT/DynamicIsland/Vendor/Whisper/ggml-silero-v5.1.2.bin" "$BUILD_ROOT/runtime/"
fi
mkdir -p "$DESTINATION"
find "$DESTINATION" -maxdepth 1 \( -name '*.dylib' -o -name 'whisper-server' -o -name 'whisper-cli' \) -delete
cp -R "$BUILD_ROOT/runtime/." "$DESTINATION/"
printf 'Updated Whisper runtime to %s (%s) in %s\n' "$WHISPER_VERSION" "$WHISPER_COMMIT" "$DESTINATION"
