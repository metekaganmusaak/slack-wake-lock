#!/bin/bash
# Build from source or use the prebuilt Slack Wake Lock.app in a release folder.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.wakelock"
DEST="$HOME/Applications/Slack Wake Lock.app"
LEGACY_DEST="$HOME/Applications/Wakelock.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ -f "Slack Wake Lock.app/Contents/MacOS/Wakelock" ]]; then
  SOURCE_APP="Slack Wake Lock.app"
else
  ./build.sh
  SOURCE_APP="build/Slack Wake Lock.app"
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" != "$LABEL" ]]; then
  echo "Invalid Slack Wake Lock app bundle" >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
if [[ -e "$DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)" != "$LABEL" ]]; then
  echo "A different app already exists at the destination: $DEST" >&2
  exit 1
fi

# Stop the previous running version
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x Wakelock 2>/dev/null || true

# Clear stale Accessibility registration so macOS can prompt for the rebuilt app.
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
ditto --norsrc --noextattr --noacl "$SOURCE_APP" "$DEST"
codesign --verify --deep --strict "$DEST"
# Remove only our legacy app bundle; preserve settings and log paths.
if [[ -d "$LEGACY_DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_DEST/Contents/Info.plist" 2>/dev/null || true)" == "$LABEL" ]]; then
  rm -rf "$LEGACY_DEST"
fi

# Safely encode paths containing ampersands, quotes, or other XML characters.
AGENT_TEMP="$(mktemp "$PLIST.tmp.XXXXXX")"
trap 'rm -f "$AGENT_TEMP"' EXIT
plutil -create xml1 "$AGENT_TEMP"
plutil -insert Label -string "$LABEL" "$AGENT_TEMP"
plutil -insert ProgramArguments -array "$AGENT_TEMP"
plutil -insert ProgramArguments.0 -string "$DEST/Contents/MacOS/Wakelock" "$AGENT_TEMP"
plutil -insert RunAtLoad -bool true "$AGENT_TEMP"
plutil -insert KeepAlive -dictionary "$AGENT_TEMP"
plutil -insert KeepAlive.SuccessfulExit -bool false "$AGENT_TEMP"
plutil -insert ProcessType -string Interactive "$AGENT_TEMP"
plutil -insert LimitLoadToSessionType -string Aqua "$AGENT_TEMP"
plutil -insert AssociatedBundleIdentifiers -array "$AGENT_TEMP"
plutil -insert AssociatedBundleIdentifiers.0 -string "$LABEL" "$AGENT_TEMP"
mv "$AGENT_TEMP" "$PLIST"

# Disable App Nap for Slack while it runs in the background.
defaults write com.tinyspeck.slackmacgap NSAppSleepDisabled -bool YES

launchctl bootstrap "$DOMAIN" "$PLIST"

REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$REGISTER" ]]; then "$REGISTER" -f "$DEST" >/dev/null 2>&1 || true; fi
# A failed Finder cache refresh must not fail an otherwise successful install.
touch "$DEST" 2>/dev/null || true

cat <<'MSG'

Slack Wake Lock is installed and running (look for ⚡️ / ⚠️ in the menu bar).

Final step: macOS may show an Accessibility permission prompt.
  Enable "Slack Wake Lock" in System Settings > Privacy & Security > Accessibility.
  (If no prompt appears, click the menu bar icon > "Accessibility permission required".)

Download the Slack desktop app if needed: https://slack.com/downloads/mac
MSG
