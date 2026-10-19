# Slack Wake Lock — macOS menu bar app

<img src="Assets/AppIcon.png" width="112" alt="Slack Wake Lock app icon">

Keeps your Mac awake on a schedule, refreshes the system idle timer with
synthetic mouse movements, and provides a temporary PIN screen. Designed for
use with the Slack desktop app; Slack presence is not guaranteed.

**macOS 13+ · Apple Silicon and Intel · MIT license · English interface**

An independent project, not affiliated with Slack or Salesforce.

## Download

Download `Slack-Wake-Lock-1.0.0-macos-universal.zip` from this repository's
**Releases** page. Extract it, copy `Slack Wake Lock.app` to Applications,
and grant Accessibility permission. Xcode is not required. For automatic
installation, run `bash install.sh` in the extracted release folder.

The app is ad hoc signed and is not notarized by Apple. If macOS blocks the
first launch, verify the download and use **System Settings → Privacy &
Security → Open Anyway** for this app. See [Apple's guidance](https://support.apple.com/102445).

Installation and publishing: [RELEASE.md](RELEASE.md).
Local files, network requests, and permissions: [PRIVACY.md](PRIVACY.md).

**The temporary screen uses the fixed PIN `123456`, which is visible in the
source code. It does not replace the secure macOS lock screen.**

## How it works

During work hours, Slack Wake Lock posts a synthetic mouse movement when
you have been idle for more than one minute. It first moves the pointer to
its current position. If that does not reset the idle timer, it switches to
a one-pixel round trip. Slack's presence behavior depends on its version,
settings, and connection; the app refreshes the system idle timer.

- It does not nudge the mouse while you are actively using the computer.
- It does not click Slack, send messages, or call the Slack API.
- It prevents idle display sleep and system sleep during work hours, including on battery.

The Slack desktop app is recommended. Browser tabs have their own activity
tracking and background restrictions, so the web app may behave differently.

## Default schedule

| Time | Behavior |
|---|---|
| 08:45–11:50 | Keep awake and refresh idle time |
| 11:50–12:00 | Stop nudging so Slack can become away around 12:00 |
| 12:00–13:00 | Lunch break: no mouse nudging |
| 13:00–17:50 | Keep awake and refresh idle time |
| 17:50–18:00 | Stop nudging so Slack can become away around 18:00 |
| Before or after work | Keep awake only while you are active, with a 30-minute grace period after your last input |
| Weekends | Inactive |

The default schedule assumes Slack becomes away after approximately ten
minutes of inactivity. Nudging stops that much earlier than a break or the
end of the workday. This timing is an estimate, not a guarantee from Slack.

**Optional Friday prayer break:** Disabled on new installations. Set
`friday.enabled` to `true` to fetch prayer times for your selected city from
aladhan.com using the Diyanet calculation method. The break starts **15
minutes before** the prayer time and ends **45 minutes after** it.
Overlapping breaks are merged. An approximate calculation is used offline.

During a break, the app stops nudging. It does not force Slack offline;
using your computer can still keep you active in Slack.

## Install from source

Building requires Xcode Command Line Tools (`xcode-select --install`).

1. Install the [Slack desktop app](https://slack.com/downloads/mac) and sign in.
2. Run the installer in this folder:

   ```bash
   bash install.sh
   ```

   It builds the app, installs it in `~/Applications/Slack Wake Lock.app`,
   enables launch at login, and starts it. In an extracted release folder,
   the same installer uses the prebuilt app instead.
3. Enable **Slack Wake Lock** in **System Settings → Privacy & Security →
   Accessibility**. The app needs this permission to post mouse events.
   A warning symbol in the menu bar indicates missing permission.

You may need to grant Accessibility permission again after rebuilding or updating.

## Menu bar controls

| Symbol | Meaning |
|---|---|
| Filled bolt | Keeping awake during work hours |
| Hourglass | Nudging has stopped ahead of a break or the end of the workday |
| Coffee cup / moon and stars | Lunch break / Friday prayer |
| Outline bolt | Keeping awake outside work hours while you are active |
| Sleeping moon | Outside work hours; inactive |
| Pause | Paused |
| Warning | Missing permission, Slack not installed, or invalid configuration |
| Lock | Temporary screen lock is active |

- **Pause:** Choose **1 hour**, **For today (resume tomorrow)**, or **Until I resume**. While paused, normal Mac sleep behavior is restored unless the temporary lock is active.
- **Resume:** End the pause.
- **Open temporary screen lock:** Cover every display. Enter **`123456`** and press **Return**, or click **Unlock**. An incorrect PIN or Escape does not dismiss the screen.
- **Friday prayer city:** Change the city used for prayer times. Country and calculation method are configured in `config.json`.
- **Launch at login:** Toggle automatic startup.
- **Quit Slack Wake Lock:** Exit until the next launch.

The menu also shows today's schedule, idle time, and the last mouse nudge.
**Show log** opens `~/Library/Logs/Wakelock.log`.

## Temporary screen lock

This screen covers the desktop without locking your macOS session. The Dock
and menu bar remain behind the overlay. The app avoids kiosk presentation
options that can silence notifications. App-switching and Spotlight shortcuts
are intercepted only while the overlay is active and Accessibility permission
is granted. The screen covers all connected displays and updates when a
monitor is connected or disconnected.

The background is solid black. The screen shows the battery percentage and
**Charging / Plugged in / On battery** status, updating when the power source
changes. It preserves your current brightness for the first **5 seconds**,
then lowers supported displays to at most **5%**. A display already below
that level is not brightened. Mouse or keyboard activity restores the original
brightness; another five seconds of inactivity dims it again. The app's own
synthetic mouse movements do not wake the display brightness. Unlocking or
quitting normally restores the original brightness.

Hardware brightness control depends on the display. Unsupported external
monitors still show a black background and dimmed text, but their backlight
may stay unchanged. The Mac and display remain awake, so battery use does not stop.

**Slack notifications:** The three most recent new Slack banners delivered
to the macOS notification interface during the lock appear in the top-right
corner. Other apps are filtered out. Accessibility permission is required.
Sender, title, and message previews are held only in memory, are not written
to files or logs, and are cleared on unlock. They are visible without entering the PIN.

Enable **Extra Slack alert sound during temporary lock** to play the macOS
Glass sound for newly captured Slack banners. Turn it off if Slack's own sound
already plays and you hear duplicate alerts. **Test Slack lock notification
and sound** shows a local sample; it does not send a real Slack message or
verify Slack's notification delivery.

Slack Wake Lock cannot produce previews if Slack or macOS does not deliver
a banner, Focus silences notifications, banners are disabled, or message
previews are hidden. Check Slack's notification preferences and macOS
**System Settings → Notifications → Slack**, including notification sounds.
Preview capture depends on the Accessibility structure exposed by macOS and
may need updates for future versions.

While the temporary lock is active, the Mac and display stay awake and mouse
nudging continues **during breaks, outside work hours, and while paused**.
Unlocking restores the previous schedule and pause state. The overlay has no
timeout and starts only when you select it. Lock state is never saved to disk:
restarting the app or Mac does **not** reopen it. Launch at login is independent.

**This is not the secure macOS lock screen.** The PIN is fixed in the source,
and system actions such as Force Quit can bypass the overlay. Use the macOS
lock screen when you need actual session security. A real session lock, closed
lid, lost connection, or Slack's own behavior can affect your online status.

To print the schedule for a particular day:

```bash
"$HOME/Applications/Slack Wake Lock.app/Contents/MacOS/Wakelock" --plan 2026-10-23
```

## Settings

**Edit settings (config.json)** opens
`~/Library/Application Support/Wakelock/config.json`. Changes are reloaded
within 15 seconds. Existing data paths and configuration keys are retained
for compatibility. The previous default Turkish lunch label is displayed as
**Lunch break**; your custom break labels and Slack message contents are preserved.

| Setting | Default | Description |
|---|---|---|
| `workStart` / `workEnd` | `"08:45"` / `"18:00"` | Work hours |
| `workDays` | `[1,2,3,4,5]` | 1 = Monday through 7 = Sunday |
| `breaks` | Lunch 12:00–13:00 | Add breaks such as `{"name": "Coffee break", "start": "15:00", "end": "15:15"}` |
| `friday.city` / `friday.country` | `Istanbul` / `Turkey` | Location used for prayer times |
| `friday.method` | `13` | Prayer-time calculation method: Diyanet |
| `friday.minutesBeforeEzan` | `15` | Minutes before prayer time when the Friday break starts |
| `friday.minutesAfterEzan` | `45` | Minutes after prayer time when the Friday break ends |
| `friday.enabled` | `false` | Enable the Friday break and prayer-time downloads |
| `holidays` | `[]` | Inactive dates, e.g. `["2026-10-29"]` |
| `afterHoursGraceMinutes` | `30` | Grace period after real input outside work hours; use `0` to disable |
| `slackAwayAfterMinutes` | `10` | Assumed Slack away interval; determines when nudging stops before breaks |
| `nudgeWhenIdleSeconds` | `60` | Idle time before a mouse nudge |
| `keepDisplayAwakeDuringBreaks` | `true` | Keep the display awake during breaks |
| `launchSlackIfClosed` | `true` | Open Slack in the background when needed during work |
| `lockScreenSlackSound` | `true` | Play an extra Glass sound for captured Slack notifications during the temporary lock |

## Sleep and session behavior

The Mac must be awake with a signed-in session. Closing the lid normally
puts it to sleep unless the hardware and power setup supports closed-display
operation. Launch at login runs the app after you sign in, when enabled.

A real macOS lock (**Control–Command–Q** or Touch ID) is not blocked by this
app and can affect Slack presence. During work hours, automatic idle sleep
is prevented; keep that in mind when leaving your desk.

With `keepDisplayAwakeDuringBreaks: true`, the display stays awake during
breaks. Setting it to `false` allows display sleep and a possible system lock,
which can delay Slack becoming active again when the break ends.

The installer disables App Nap for Slack using `NSAppSleepDisabled`, so
macOS does not throttle it in the background. Uninstalling removes that override.

## Uninstall

```bash
bash uninstall.sh          # Remove the app and launch agent; keep settings
bash uninstall.sh --all    # Also remove settings, cached prayer times, and logs
```

## Project files

- `Sources/main.swift`: menu bar, scheduling, idle activity, and launch at login.
- `Sources/TemporaryLock.swift`: temporary PIN screen and multiple displays.
- `Sources/LockPower.swift`: battery status and delayed hardware brightness control.
- `Sources/SlackNotifications.swift`: in-memory previews of Slack notification banners.
- `Sources/LockShortcutGuard.swift`: app-switch shortcut blocking without kiosk mode.
- `Assets/AppIcon.png` / `Assets/Wakelock.icns`: app icon and native icon resource.
- `build.sh`: build `build/Slack Wake Lock.app`.
- `install.sh` / `uninstall.sh`: installation and removal.
- `test.sh`: UI and behavior tests in an active macOS session; the overlay briefly appears.
- `release.sh`: universal app ZIP, clean source ZIP, and SHA-256 checksums.
- `VERSION`, `LICENSE`, `PRIVACY.md`, `RELEASE.md`: version, license, privacy, and distribution notes.

## Prepare a release

```bash
bash test.sh
bash release.sh
python3 Tests/verify-release.py
```

Extract the source ZIP in `dist/` and upload its contents to your public
repository. Attach the app ZIP and checksum file to the GitHub Release.
Build output, user settings, and certificates are excluded by `.gitignore`
and the release script's source-file allowlist.

## License

[MIT](LICENSE). The icon was generated for this project and uses colors
inspired by Slack; it is not the official Slack logo. Slack's name and
trademarks belong to their respective owners.
