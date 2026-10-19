#!/bin/bash
# Native architecture: ./build.sh; Apple Silicon + Intel: ./build.sh --universal
set -euo pipefail
cd "$(dirname "$0")"

APP_VERSION="$(tr -d '\r\n' < VERSION)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid VERSION: expected major.minor.patch" >&2
  exit 1
fi
case "${1:-}" in
  "") ARCHITECTURES=("$(uname -m)") ;;
  --universal) ARCHITECTURES=(arm64 x86_64) ;;
  *) echo "Usage: ./build.sh [--universal]" >&2; exit 2 ;;
esac

APP="build/Slack Wake Lock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/Localizations.json "$APP/Contents/Resources/Localizations.json"
cp Assets/Wakelock.icns "$APP/Contents/Resources/Wakelock.icns"

for architecture in "${ARCHITECTURES[@]}"; do
  mkdir -p "build/thin/$architecture"
  swiftc -O -swift-version 5 \
    -file-prefix-map "$PWD=." \
    -target "$architecture-apple-macos13.0" \
    Sources/*.swift \
    -o "build/thin/$architecture/Wakelock"
done
if [[ "${#ARCHITECTURES[@]}" -eq 2 ]]; then
  lipo -create build/thin/arm64/Wakelock build/thin/x86_64/Wakelock -output "$APP/Contents/MacOS/Wakelock"
else
  cp "build/thin/${ARCHITECTURES[0]}/Wakelock" "$APP/Contents/MacOS/Wakelock"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>        <string>local.wakelock</string>
  <key>CFBundleName</key>              <string>Slack Wake Lock</string>
  <key>CFBundleDisplayName</key>       <string>Slack Wake Lock</string>
  <key>CFBundleDevelopmentRegion</key> <string>en</string>
  <key>CFBundleLocalizations</key>     <array><string>en</string><string>tr</string><string>es</string><string>it</string><string>fr</string><string>de</string><string>ru</string><string>uk</string><string>hi</string><string>zh</string><string>ja</string><string>ko</string><string>pt</string><string>nb</string><string>da</string><string>sv</string></array>
  <key>CFBundleExecutable</key>        <string>Wakelock</string>
  <key>CFBundleIconFile</key>          <string>Wakelock.icns</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHumanReadableCopyright</key>  <string>Keep your Mac awake during work hours</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.wakelock "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
