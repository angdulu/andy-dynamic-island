#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/andy-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
swiftc -swift-version 5 -o "$TEST_ROOT/tests" \
    "$PROJECT_ROOT/DynamicIsland/managers/WhisperServer.swift" \
    "$PROJECT_ROOT/DynamicIsland/managers/DictationRecordingStore.swift" \
    "$PROJECT_ROOT/Tests/DictationCoreTests.swift"
"$TEST_ROOT/tests" "$PROJECT_ROOT/Tests/Fixtures/whisper-server.rb"
swiftc -swift-version 5 -o "$TEST_ROOT/live-tests" \
    "$PROJECT_ROOT/DynamicIsland/managers/LiveDictationAudio.swift" \
    "$PROJECT_ROOT/DynamicIsland/managers/DictationCleanupPolicy.swift" \
    "$PROJECT_ROOT/DynamicIsland/managers/DictationPreviewTranscript.swift" \
    "$PROJECT_ROOT/Tests/LiveDictationTests.swift"
"$TEST_ROOT/live-tests"

# Optional real-model checks. Requires Andy's bundled server and the downloaded
# Llama cleanup model; no user settings or microphone access are used.
if [[ "${1:-}" == "--cleanup" ]]; then
    TEST_APP="$TEST_ROOT/ManagerTests.app/Contents"
    mkdir -p "$TEST_APP/MacOS" "$TEST_APP/Resources"
    ln -s /Applications/Andy.app/Contents/Resources/Llama "$TEST_APP/Resources/Llama"
    cat > "$TEST_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ManagerTests</string>
<key>CFBundleIdentifier</key><string>local.andy.cleanup-manager-tests</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
    swiftc -emit-module -emit-library -module-name Defaults \
        -emit-module-path "$TEST_ROOT/Defaults.swiftmodule" \
        "$PROJECT_ROOT/Tests/Fixtures/Defaults.swift" -o "$TEST_ROOT/libDefaults.dylib"
    swiftc -swift-version 5 -I "$TEST_ROOT" -L "$TEST_ROOT" -lDefaults \
        -Xlinker -rpath -Xlinker "$TEST_ROOT" -o "$TEST_APP/MacOS/ManagerTests" \
        "$PROJECT_ROOT/DynamicIsland/managers/LlamaManager.swift" \
        "$PROJECT_ROOT/DynamicIsland/managers/DictationCleanupPolicy.swift" \
        "$PROJECT_ROOT/Tests/LlamaManagerTests.swift"
    "$TEST_APP/MacOS/ManagerTests"
fi
