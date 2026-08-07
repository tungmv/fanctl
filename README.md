# fand

A small, safe macOS fan-control **daemon + CLI** written in Swift. fand talks
directly to the SMC (System Management Controller) through IOKit — no kernel
extensions, no background daemons beyond one launchd service, no Electron.

It is a faithful Swift port of the architecture and SMC protocol of
[raminsharifi/MacFanControl](https://github.com/raminsharifi/MacFanControl),
with the terminal UI replaced by a root daemon with a Unix-domain-socket IPC
interface.

```
┌────────────┐   JSON over /tmp/fand.sock   ┌──────────────────────────┐
│ fanctl    │ ────────────────────────────► │ fand daemon (root)       │
│ (CLI)      │ ◄──────────────────────────── │  control thread          │
└────────────┘     status / fans / temps    │  own SMC connection      │
                                            │  unlock / retry / clamp  │
                                            │  re-assert after sleep   │
                                            │  restore-to-auto on exit │
                                            └──────────────────────────┘
```

## What it does

- Shows live fan RPM, mode, and ~180 temperature sensors
- Pins fans to a target RPM (`manual` mode) or returns them to automatic
- **Apple Silicon first**: M1 direct mode writes, plus the M3/M4
  `Ftst` thermal-manager unlock sequence (Intel `fpe2`/`FS! ` paths are
  implemented but untested)
- **Guarantees fans go back to automatic control** on every exit path
  (SIGTERM, Ctrl-C, SIGHUP), and re-engages your pinned speeds automatically
  after sleep/wake

## Install

```bash
./install.sh            # builds release binaries, installs to /usr/local/bin,
                        # registers the com.fand.daemon launchd service
```

Or manually:

```bash
swift build -c release
sudo install -m 0755 .build/release/fand /usr/local/bin/fand
sudo install -m 0755 .build/release/fanctl /usr/local/bin/fanctl
sudo fanctl install
```

The daemon runs as root via launchd (writing fan speeds requires root — that
is enforced by the SMC firmware itself, not by fand). Logs go to
`/var/log/fand.log`.

## Usage

```bash
fanctl status                    # fans, temperatures, curves, daemon state
fanctl set 2500                  # pin every fan to 2500 RPM
fanctl set 1500 0                # pin only fan 0 to 1500 RPM
fanctl set auto                  # all fans back to automatic
fanctl auto                      # same
fanctl curve 50:1500 60:2500 70:4000   # automatic temp→RPM curve (hottest sensor)
fanctl curve 40:1200 65:3000 --sensor avg      # curve on average temperature
fanctl curve 50:1500 70:3500 --sensor Tp05P 1  # one sensor, fan 1 only
fanctl curve off [fan]           # remove curve(s), back to automatic
fanctl curve                     # show active curves
fanctl daemon                    # run the daemon in the foreground (sudo)
sudo fanctl uninstall            # stop the service and remove it
```

`fanctl status` works even when the daemon is not running: reads need no
privileges, so the CLI opens its own SMC connection and shows a read-only
snapshot.

## Curves

A curve drives fans automatically from temperature: you give 2+ `temp:rpm`
breakpoints, fand linearly interpolates between them (below the first point
the first RPM applies, above the last the last RPM applies) and continuously
updates the fan target from live temperatures. The temperature source is
`hottest` (default), `avg`, or a specific SMC sensor key from `fanctl status`.

- Targets are clamped to each fan's limit (firmware `F0Mx` / model ceiling)
  exactly like manual pins.
- Curves are **persisted** at `/var/db/fand/curve.json` and re-applied
  automatically when the daemon restarts (pins remain memory-only by design).
- Setting a pin or `auto` on a curve fan clears its curve; `fanctl curve off`
  returns fans to automatic control.
- **Default curve:** `fanctl curve default [fan]` applies fand's built-in
  curve — the community-sourced "Balanced" preset of the FanCurve app
  (github.com/agoodkind/macos-fan-curve), the most widely shared Apple
  Silicon fan curve, adapted to RPM against the M1 Pro firmware max:
  ≤50 °C → 1500 RPM (silent floor) · 65 °C → 1500 · 75 °C → 1950 ·
  85 °C → 2600 · 95 °C → 3450 · 100 °C → 4300. It keeps fans at minimum
  below 50 °C, reaches 60% by 85 °C (the MacRumors consensus for the M1
  Pro, whose stock curve lets cores hit 100 °C before fans spin), and
  clamps per fan to the firmware/model limit.
- The target is re-written only when it moves by ≥ 20 RPM, and sleep/wake
  re-engages the curve like any manual control.

## How it works

### The SMC

Every Mac has an SMC that owns fans, temperature sensors, power rails, and
hundreds of other keys, each addressed by a four-character code. fand opens
the `AppleSMC` IOKit service from userspace and speaks the same 80-byte
struct protocol used by every fan tool since smcFanControl, implemented in
Swift with zero dependencies.

The keys that matter for fans:

| Key    | Type   | Meaning                                    |
|--------|--------|--------------------------------------------|
| `FNum` | `ui8`  | number of fans                             |
| `F0Ac` | `flt`  | actual RPM (read-only)                     |
| `F0Tg` | `flt`  | target RPM                                 |
| `F0Mn`/`F0Mx` | `flt` | firmware-recommended min/max RPM      |
| `F0Md` | `ui8`  | fan mode: `0` auto · `1` manual · `3` system |
| `Ftst` | `ui8`  | thermal-manager unlock flag (M3/M4)        |

On Apple Silicon all RPM values are little-endian IEEE-754 floats; on Intel
they are big-endian `fpe2` fixed-point, and forcing manual mode uses the
`FS! ` bitmask. fand reads the type of each key at runtime and encodes
accordingly — the host is detected with `hw.optional.arm64` at startup.

### The M3/M4 unlock

On M1 Macs, writing `F0Md = 1` as root just works. From the M3 generation on,
`thermalmonitord` holds fans in mode `3` and the firmware rejects manual-mode
writes with SMC error `0x82`. The working sequence:

1. Try `F0Md = 1` directly (works on M1, and on M3 when the system is not
   actively asserting mode 3)
2. On rejection: write `Ftst = 1`, wait ~3 s for the thermal manager to
   yield, then retry the mode write (up to 300 × 100 ms)
3. Write the target RPM to `F0Tg`

fand then keeps watching: sleep/wake resets `Ftst` in firmware and the
system reclaims the fans, so an idle loop in the control thread re-runs the
sequence automatically whenever the desired state and the hardware state
diverge.

### Safety guarantees

- **Restore on every exit path.** SIGTERM/SIGINT/SIGHUP trigger a graceful
  quit that returns every fan fand touched to automatic mode.
- **`Ftst` is released conservatively.** The unlock flag is cleared only
  after every fan is back under automatic control, and only if fand set it in
  the first place — leaving it stuck at `1` would partially inhibit macOS
  thermal management.
- **Intent is tracked eagerly.** The moment a mode write lands on the
  hardware the fan is marked dirty, so even a failed follow-up write is
  covered by the exit-restore. A fan can never be silently stranded in
  manual mode.
- **Targets are clamped** to the per-fan limit: the firmware-reported
  `F0Mx` when plausible, otherwise a **hardcoded per-model ceiling**
  (`Sources/FandCore/Hardware.swift`). Apple publishes no fan-RPM API, so
  the table is built from measured maxima (Notebookcheck stress tests, the
  Apple Wiki) and Apple's own model-identifier list (support.apple.com/HT201300);
  every ceiling is rounded *up* so it can never undercut the hardware.
  Unknown models fall back to an absolute ceiling of 9000 RPM (no MacBook
  fan has ever been measured above ~8000). `F0Mn`/`F0Mx` themselves are
  never written, and the CLI refuses values above 9000 outright.
- **Quit is interruptible.** A quit lands within ~50 ms even mid-unlock.
- **External state is respected.** fand only restores fans it touched — if
  another tool set something, exit leaves it alone.
- **Pins are memory-only.** A daemon restart returns everything to
  automatic control, by design.

## Development

```bash
swift build          # debug build
swift test           # unit tests (fourcc, 80-byte layout, codecs, control logic, IPC)
./install.sh         # release build + install
```

The SMC struct layout is locked by a size assertion and the byte codecs are
unit-tested; everything hardware-facing was verified against a live probe of
the SMC on real Apple Silicon hardware (M1 Pro, macOS 15.7).

## Troubleshooting

- **"rejected by thermal manager (SMC 0x82)"** after the unlock retries are
  exhausted — the thermal manager refused to yield (heavy thermal load can
  cause this). Try again, or accept that macOS really wants those fans under
  its control right now.
- **Settings revert after sleep** — expected; firmware resets the unlock on
  wake. fand re-engages your target automatically within a couple of seconds.
- **"permission denied"** — the daemon must run as root; `fanctl set`
  requires the daemon (not just the CLI) to be running as root.
- **Fanless Macs (MacBook Air)** — nothing to control; the daemon logs
  "no fans found" and exits.

## Roadmap

- Intel hardware verification
- `fanctl status --watch`

## License

MIT. Not affiliated with Apple. Use at your own risk — fand ships with the
same restore-on-exit guarantees it can honestly provide, but cooling is
ultimately the Mac's own thermal manager's job.
