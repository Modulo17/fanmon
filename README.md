# fanmon

> This started as a side project when my M5 suddenly got very hot and kept
> sleeping quicker than I could see what was making it sleep — now I get a
> warning first.

A tiny native macOS **menu bar** widget that shows live temperature and fan RPM
for Apple Silicon Macs (built and tested on an M5 Max).

**Menu bar title:** a thermometer + the headline temperature, e.g. `🌡 49°`
(kept compact — fan speeds live in the dropdown). The thermometer and
temperature are colour-coded by heat:

| State | Temp      | Colour            |
|-------|-----------|-------------------|
| cool  | < 70 °C   | neutral (passive) |
| warm  | 70–89 °C  | orange            |
| hot   | ≥ 90 °C   | red               |

The **headline** temperature is the hottest of the die / battery / NAND (SSD).

**Click** it for a compact panel (full-strength text, custom-drawn — no per-die
noise), ending in a 30-minute trend graph of die-average, battery, and NAND.
Periods when a fan was running are marked with an orange band and a fan icon:

```
FANS
  Fan 1                     1347 rpm   25%
  Fan 2                     1460 rpm   25%
TEMPERATURES
  Hottest die                       39.6 °C
  Average die                       38.7 °C
  Battery                           34.3 °C
  NAND (SSD)                        35.0 °C
TREND · LAST 30 MIN                        ✼ fan on
  [ Die / Battery / NAND lines; orange bands mark fan-on periods ]
```

## History log

Readings are sampled **once per minute** and kept for the **last 30 minutes**,
persisted to `~/Library/Application Support/fanmon/history.csv` so the trend
graph survives relaunches/reboots.

## How it reads sensors

Apple Silicon splits these across two subsystems, and fanmon reads both
directly — **no `sudo`, no kernel extension, no entitlements**:

- **Fans** — the SMC (`AppleSMC` IOKit user client), keys `FNum`, `F<n>Ac/Mn/Mx`.
- **Temperatures** — the IOKitHID thermal sensors (usage page `0xff00`,
  usage `0x05`). The classic SMC `T…` temperature keys don't exist on M-series;
  temps come through `IOHIDServiceClientCopyEvent`. Note the client must be made
  with the private `IOHIDEventSystemClientCreate` — the public
  `CreateSimpleClient` enumerates sensors but never delivers readings.

Nothing is hardcoded to a particular chip: fan count and sensors are discovered
at runtime, so it works across Apple Silicon (M1–M5). Fans are also readable on
Intel Macs, but temperatures there use a different (SMC) path that isn't
implemented here.

## Build

```bash
./build.sh
```

Produces `build/Fanmon.app` (a menu-bar-only app — `LSUIElement`, no Dock icon).

## Run

```bash
open build/Fanmon.app
```

Or print a one-shot reading to the terminal without the menu bar:

```bash
./build/Fanmon.app/Contents/MacOS/fanmon --dump
```

## Customising the bundle identifier

The bundle ID is a neutral placeholder, `com.example.fanmon`. To rebrand it to
your own reverse-DNS domain, edit `BUNDLE_ID` at the top of `build.sh`. If you
install a login agent (below), give the agent's `Label` the **same** value.

## Start automatically at login

Move the app somewhere permanent first (e.g. symlink it into `/Applications`):

```bash
ln -sfn "$PWD/build/Fanmon.app" /Applications/Fanmon.app
```

**Simple:** System Settings → General → Login Items → **＋** → select the app.

**Robust (auto-restart on crash):** create
`~/Library/LaunchAgents/<BUNDLE_ID>.plist` with `Label` = your `BUNDLE_ID`,
`ProgramArguments` = `[/Applications/Fanmon.app/Contents/MacOS/fanmon]`,
`RunAtLoad` = true, and `KeepAlive` = `{ SuccessfulExit = false }` (so a manual
Quit is respected). Load it with:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<BUNDLE_ID>.plist
```

## Files

- `Sources/main.swift` — SMC reader, thermal reader, and the menu bar app.
- `bridge/fanmon-bridge.h` — declares the private IOKit symbols + SMC structs.
- `build.sh` — compiles and assembles the `.app` bundle.
- `LICENSE` — MIT.

## Diagnostics

```bash
fanmon --dump                 # one-shot text reading
fanmon --render <png> [--dark] # render the panel to an image
fanmon --render-title <png>    # preview the menu bar title states
```
