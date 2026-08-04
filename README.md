# fanmon

A tiny native macOS **menu bar** widget that shows live temperature and fan RPM
for Apple Silicon Macs (built and tested on an M5 Max).

**Menu bar title:** a thermometer + the headline temperature + a fan glyph + RPM,
e.g. `🌡 49°  ✼ 1462`. The thermometer and temperature are colour-coded by heat:

| State | Temp      | Colour           |
|-------|-----------|------------------|
| cool  | < 70 °C   | neutral (passive)|
| warm  | 70–89 °C  | orange           |
| hot   | ≥ 90 °C   | red              |

The **headline** temperature is the hottest of the die / battery / NAND(SSD).

**Click** it for a compact panel (full-strength text, custom-drawn — no per-die
noise), ending in a 30-minute trend graph of die-average, battery, and NAND:

```
FANS
  Fan 1                     1347 rpm   25%
  Fan 2                     1460 rpm   25%
TEMPERATURES
  Hottest die                       39.6 °C
  Average die                       38.7 °C
  Battery                           34.3 °C
  NAND (SSD)                        35.0 °C
TREND · LAST 30 MIN
  [ line graph: Die / Battery / NAND over the last 30 min ]
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

## Start automatically at login

System Settings → General → Login Items → **＋** → select `build/Fanmon.app`.
(Move the app somewhere permanent, like `/Applications`, first.)

## Files

- `Sources/main.swift` — SMC reader, thermal reader, and the menu bar app.
- `bridge/fanmon-bridge.h` — declares the private IOKit symbols + SMC structs.
- `build.sh` — compiles and assembles the `.app` bundle.
