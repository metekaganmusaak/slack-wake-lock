#!/bin/bash
# Temiz kaynak ZIP'i ve universal macOS uygulama ZIP'i üretir; yayınlamaz.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --universal
APP_VERSION="$(tr -d '\r\n' < VERSION)"
DIST_DIR="$PWD/dist"
STAGE_DIR="$(mktemp -d /tmp/wakelock-release.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$DIST_DIR"

RELEASE_NAME="Slack-Wake-Lock-$APP_VERSION-macos-universal"
SOURCE_NAME="Slack-Wake-Lock-$APP_VERSION-source"
mkdir -p "$STAGE_DIR/$RELEASE_NAME" "$STAGE_DIR/$SOURCE_NAME"

ditto --norsrc --noextattr --noacl "build/Slack Wake Lock.app" "$STAGE_DIR/$RELEASE_NAME/Slack Wake Lock.app"
for item in install.sh uninstall.sh LICENSE PRIVACY.md RELEASE.md; do
  cp "$item" "$STAGE_DIR/$RELEASE_NAME/"
done
cp RELEASE.md "$STAGE_DIR/$RELEASE_NAME/README.md"

# Açık dosya listesi: build, .git, yerel ayarlar, günlükler ve sertifikalar eklenmez.
for item in Sources Tests Assets build.sh install.sh uninstall.sh test.sh release.sh VERSION README.md LICENSE PRIVACY.md RELEASE.md .gitignore; do
  ditto --norsrc --noextattr --noacl "$item" "$STAGE_DIR/$SOURCE_NAME/$item"
done

codesign --verify --deep --strict "$STAGE_DIR/$RELEASE_NAME/Slack Wake Lock.app"
lipo "$STAGE_DIR/$RELEASE_NAME/Slack Wake Lock.app/Contents/MacOS/Wakelock" -verify_arch arm64 x86_64
for name in "$RELEASE_NAME" "$SOURCE_NAME"; do
  rm -f "$DIST_DIR/$name.zip"
  ditto -c -k --keepParent --norsrc --noextattr --noacl "$STAGE_DIR/$name" "$DIST_DIR/$name.zip"
done
(
  cd "$DIST_DIR"
  shasum -a 256 "$RELEASE_NAME.zip" "$SOURCE_NAME.zip" > "Slack-Wake-Lock-$APP_VERSION-SHA256SUMS.txt"
)
echo "Hazır: dist/$RELEASE_NAME.zip"
echo "Hazır: dist/$SOURCE_NAME.zip"
echo "Hazır: dist/Slack-Wake-Lock-$APP_VERSION-SHA256SUMS.txt"
