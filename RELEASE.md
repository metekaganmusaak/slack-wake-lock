# Slack Wake Lock v1.1.0 — macOS

Requires macOS 13 or later. Universal app for Apple Silicon and Intel Macs.
The interface supports 16 languages and follows the device language by default. This is an independent project, not affiliated
with Slack or Salesforce.

## Download and install

1. Extract `Slack-Wake-Lock-1.1.0-macos-universal.zip`.
2. Copy `Slack Wake Lock.app` to Applications and open it.
3. Enable Slack Wake Lock in System Settings → Privacy & Security → Accessibility.
4. Sign in to the Slack desktop app. Slack Wake Lock appears in the menu bar.

You can enable **Launch at login** from the menu. The temporary lock always
starts disabled after an app or Mac restart.

For automatic installation and Slack's App Nap override, run
`bash install.sh` in the extracted release folder. The installer uses the
prebuilt app; Xcode and the Swift compiler are not required. It replaces an
older Wakelock installation while preserving work hours and preferences.
Existing configuration keys and data paths remain compatible.

## First launch and Apple approval

This release is **ad hoc signed, without a Developer ID signature or Apple
notarization**. macOS may block the first launch after downloading it. Verify
the file and source, then use **System Settings → Privacy & Security → Open
Anyway**. Managed devices may restrict this option. You do not need to
disable system security globally.

See [Apple's guidance](https://support.apple.com/102445).

## Included features

- Work schedules, breaks, and pause controls.
- Temporary desktop overlay with the fixed PIN **123456**.
- Solid black background, battery status, brightness dimming after five seconds, and brightness restoration on input.
- The last three new Slack banner previews, with an optional extra alert sound.
- A macOS app icon inspired by Slack's colors.
- Optional Friday prayer times, disabled on new installations.
- Language menu with 16 languages, alphabetical names, and a device-language default.
- Immediate language switching for menus, alerts, dates, battery status, and the temporary lock screen.
- Language selection is saved across restarts; existing preferences are preserved.
- Logs, installation scripts, and documentation remain in English.

## Limitations

The temporary PIN screen is not the secure macOS lock screen. Its PIN is
visible in the source. Notification previews can be read without entering
the PIN. Quitting or force-quitting the app removes the overlay. Use the
macOS lock screen for actual session security.

Slack presence is not guaranteed. Network connectivity, Slack settings,
session locking, sleep, and a closed lid can affect it. The DisplayServices
brightness interface and the Accessibility structure used for notification
previews can change between macOS releases. External display support depends
on the hardware.

Runtime tests were performed on Apple Silicon. The Intel slice was compiled
and its package structure verified; it has not been tested on a physical Intel Mac.

See `PRIVACY.md` for privacy details and `LICENSE` for the MIT license.

## Uninstall

Run `bash uninstall.sh` from this folder. Add `--all` to also remove local
settings, cached prayer times, and logs. Automatic installation uses
`~/Applications`; remove any app copies you manually placed elsewhere too.

## Publish on GitHub

1. Create a public `slack-wake-lock` repository under your personal account.
2. Extract the source ZIP and upload its contents to the repository root. Upload the source files themselves, not just the ZIP.
3. Select Releases → Draft a new release. Create tag `v1.1.0` and use the title `Slack Wake Lock v1.1.0`.
4. Attach the app ZIP and `Slack-Wake-Lock-1.1.0-SHA256SUMS.txt`.
5. Copy the content above this publishing section into the release description and publish.

For future versions, update `VERSION` and run `bash release.sh`. It creates
the app ZIP, clean source ZIP, and checksums in `dist/`; it does not upload
anything to GitHub. Update the version references in README.md and RELEASE.md
for the next release as well.
