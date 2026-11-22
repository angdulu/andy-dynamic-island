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
