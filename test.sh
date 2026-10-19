#!/bin/bash
# Açık macOS oturumunda geçici kaplamayı kısa süre göstererek test eder.
set -euo pipefail
cd "$(dirname "$0")"

TEST_DIR="$(mktemp -d /tmp/wakelock-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Üretim türlerini aynı dosya kapsamında derle; yalnızca giriş noktasını değiştir.
sed '/^\/\/ MARK: - Giriş noktası/,$d' Sources/main.swift > "$TEST_DIR/main.swift"
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
