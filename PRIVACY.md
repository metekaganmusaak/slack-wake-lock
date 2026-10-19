# Privacy and public distribution

## Data excluded from the packages

Source and release ZIPs are built from an explicit file allowlist. User
settings, logs, pause state, prayer-time cache, Slack sessions, message
history, Git history, work email addresses, certificates, and API keys are
not included. Paths are resolved from the current user's home directory;
no particular Mac's absolute user path is hardcoded in the source.

## User-specific files

The data paths and `local.wakelock` bundle identifier are retained for
compatibility with earlier Wakelock versions. The app's display name is
Slack Wake Lock.

- `~/Library/Application Support/Wakelock/config.json`: work hours and preferences.
- `state.json` and `prayer-cache.json` in the same folder: pause state and optional prayer-time cache.
- `~/Library/Logs/Wakelock.log`: app state, permission errors, nudge status, and notification counts.
- `~/Library/LaunchAgents/local.wakelock.plist`: app path for launch at login, when enabled.

These files are created on the user's own Mac. Review logs before attaching
them to an issue: they can include work hours, the selected city, or local
paths in system error messages.

## Slack and permissions

The app does not read Slack tokens, passwords, or cookies, and does not
connect to the Slack API. Accessibility permission is used to post synthetic
mouse movements, intercept app-switch shortcuts during the temporary lock,
and read Slack notification banner previews.

Sender names and message previews are kept only in memory, are not written
to logs, and are cleared when the temporary lock is dismissed. Previews are
visible without entering the PIN. Actual message contents are displayed as
received, without translation.

The temporary screen's fixed PIN is **123456**, visible in the source code.
It is not your macOS account password. This overlay does not replace the
secure macOS lock screen.

## Network requests

Slack Wake Lock contains no telemetry or analytics service. The Friday
prayer feature is disabled on new installations. If enabled, it requests
prayer times from `https://api.aladhan.com` using the selected city, country,
and calculation method. That service can also see the connection's IP
address. Existing preferences in config.json are preserved.

Download and settings links open only when the user selects them.

## Build and distribution

Releases are ad hoc signed without an Apple Developer or organization
certificate; no organization's signing identity is included. Source paths
are generalized with `-file-prefix-map`. Packages are created without macOS
resource forks or extended file attributes.
