#!/bin/bash
# Test the temporary overlay briefly in an active macOS session.
set -euo pipefail
cd "$(dirname "$0")"

TEST_DIR="$(mktemp -d /tmp/wakelock-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Compile production types in the same file scope, replacing only the entry point.
sed '/^\/\/ MARK: - Entry point/,$d' Sources/main.swift > "$TEST_DIR/main.swift"
cat Tests/TemporaryLockTests.swift >> "$TEST_DIR/main.swift"
cat >> "$TEST_DIR/main.swift" <<'SWIFT'
MainActor.assumeIsolated {
    TemporaryLockTests.run()
}
SWIFT

swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  "$TEST_DIR/main.swift" Sources/TemporaryLock.swift Sources/LockPower.swift Sources/SlackNotifications.swift Sources/LockShortcutGuard.swift \
  -o "$TEST_DIR/WakelockTests"
"$TEST_DIR/WakelockTests"
