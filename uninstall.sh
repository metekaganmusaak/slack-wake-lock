#!/bin/bash
# Remove Slack Wake Lock. To also remove settings: ./uninstall.sh --all
set -uo pipefail

LABEL="local.wakelock"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x Wakelock 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
for app in "$HOME/Applications/Slack Wake Lock.app" "$HOME/Applications/Wakelock.app"; do
  if [[ -d "$app" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$LABEL" ]]; then
    rm -rf "$app"
  fi
done
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1
defaults delete com.tinyspeck.slackmacgap NSAppSleepDisabled 2>/dev/null

if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/Wakelock" "$HOME/Library/Logs/Wakelock.log"
  echo "Slack Wake Lock and its settings have been removed."
else
  echo "Slack Wake Lock has been removed. (Settings remain in ~/Library/Application Support/Wakelock — run ./uninstall.sh --all to remove them.)"
fi
