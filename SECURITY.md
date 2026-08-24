# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories:
**repo → Security → Report a vulnerability**. For non-sensitive bugs, open a
regular issue. There is no fixed response-time guarantee — this is a small,
best-effort open-source project.

## Design & threat model

fanmon is intentionally minimal and low-risk:

- **Read-only.** It reads SMC fan values and IOKit HID thermal sensors. It does
  **not** set fan speeds or write to any hardware.
- **No elevated privileges.** No `sudo`, no kernel extension, no code-signing
  entitlements, no sandbox exceptions.
- **No network access and no telemetry.** The only data written is a local file:
  `~/Library/Application Support/fanmon/history.csv` (a rolling 30-minute log of
  temperatures and fan RPM). Delete it any time.

## Private API note

Reading Apple Silicon temperatures requires a private Apple API
(`IOHIDEventSystemClientCreate` and the IOKit HID thermal event calls). This is
the only way to read on-die temperatures without `sudo`. A future macOS release
could change or remove these symbols; the app is written to fail closed (report
no temperatures) rather than crash.

## Installing safely

No pre-built binaries are distributed. Build from source with `./build.sh` so you
run only code you can inspect. Release source archives on GitHub include a
`SHA256SUMS` file you can verify with `shasum -a 256 -c SHA256SUMS`.
