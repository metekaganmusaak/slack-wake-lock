#!/bin/bash
# Kaynak klasöründe derler; release klasöründe hazır Slack Wake Lock.app'i kullanır.
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
  echo "Geçersiz Slack Wake Lock uygulama paketi" >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
if [[ -e "$DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)" != "$LABEL" ]]; then
  echo "Hedefte farklı bir uygulama var: $DEST" >&2
  exit 1
fi

# Çalışan eski sürümü durdur
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x Wakelock 2>/dev/null || true

# Yeni derlenen uygulama macOS için "yeni" bir uygulamadır; eski Erişilebilirlik kaydını temizle ki izin penceresi düzgün çıksın
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
ditto --norsrc --noextattr --noacl "$SOURCE_APP" "$DEST"
codesign --verify --deep --strict "$DEST"
# Eski adı taşıyan kendi paketimizi kaldır; ayar ve günlük yolları korunur.
if [[ -d "$LEGACY_DEST" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_DEST/Contents/Info.plist" 2>/dev/null || true)" == "$LABEL" ]]; then
  rm -rf "$LEGACY_DEST"
fi

# Kullanıcı dizinindeki &, tırnak vb. karakterleri XML'e güvenli yaz.
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

# Slack arka plandayken macOS onu "uyutmasın" (App Nap kapalı)
defaults write com.tinyspeck.slackmacgap NSAppSleepDisabled -bool YES

launchctl bootstrap "$DOMAIN" "$PLIST"

REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$REGISTER" ]]; then "$REGISTER" -f "$DEST" >/dev/null 2>&1 || true; fi
# Finder önbelleği yenilenemezse başarılı kurulumu hata sayma.
touch "$DEST" 2>/dev/null || true

cat <<'MSG'

Slack Wake Lock kuruldu ve çalışıyor (menü çubuğunda ⚡️ / ⚠️ simgesi).

Son adım: macOS bir "Erişilebilirlik" izni penceresi açacak.
  Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik > "Slack Wake Lock" anahtarını aç.
  (Pencere çıkmazsa menü çubuğundaki simgeye tıkla > "Erişilebilirlik izni gerekli".)

Slack masaüstü uygulaması yüklü değilse: https://slack.com/downloads/mac
MSG
