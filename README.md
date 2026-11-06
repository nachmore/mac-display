# mac-display

[![build](https://github.com/nachmore/mac-display/actions/workflows/build.yml/badge.svg)](https://github.com/nachmore/mac-display/actions/workflows/build.yml)

Pin external monitors on Apple silicon Macs to the **connection mode** you want: bit depth,
RGB / YCbCr 4:4:4 / 4:2:2, full or limited range, SDR or HDR, and optionally resolution and
refresh rate. mac-display re-applies it whenever macOS resets it after sleep/wake, a
reconnect or a link retrain, **including at the login window and lock screen**.

## Why

Some monitors only behave in one particular signal format. For example, a Samsung Odyssey G9
that needs 8-bit SDR YCbCr 4:4:4 Limited. macOS picks its own default every time the display
reconnects, which happens on every wake from sleep.

Tools like [BetterDisplay](https://github.com/waydabber/BetterDisplay) can change this
"connection mode", but they are apps in your login session. Until you log in, the login window
and lock screen show whatever macOS chose.

mac-display is a small LaunchDaemon. It starts at boot, needs no logged-in user, and puts the
mode back within a few seconds of any change.

## Requirements

* An Apple silicon Mac, with the display connected natively (USB-C/Thunderbolt/HDMI, not
  DisplayLink).
* macOS 13 or later. Developed and tested on macOS 26 on an M3 Pro.
* The Xcode Command Line Tools: `xcode-select --install`.

## Install

```sh
git clone https://github.com/nachmore/mac-display.git
cd mac-display
./install.sh
```

Run `install.sh` as yourself; it asks for sudo when it needs it. It builds the binary and installs:

| path | what |
|---|---|
| `/Library/PrivilegedHelperTools/local.mac-display` | the binary (root-owned; this is what the daemon runs) |
| `/usr/local/bin/mac-display` | symlink to the binary, for running commands |
| `/Library/LaunchDaemons/local.mac-display.plist` | the LaunchDaemon |
| `/usr/local/etc/mac-display/config.json` | your config (created empty if missing; never overwritten) |
| `/Library/Logs/mac-display/` | the log |

On a fresh install it then starts `mac-display setup`. When it finishes, it prints where
everything went and the daemon's status. Re-running `./install.sh` upgrades in place and keeps
your config.

macOS may show a "Background item added" notice. Leave the item allowed in
System Settings › General › Login Items & Extensions.

## Setup

```sh
mac-display setup
```

This is an interactive walkthrough and it asks for sudo:

1. Pick a display (skipped if only one is attached).
2. Look through the colour modes it offers. Type a number to switch to that mode live, or `t`
   to change resolution or refresh rate.
3. After each switch, mac-display waits a few seconds for the picture to come back. Then
   **type `y` within 15 s to keep the mode, or it reverts by itself**. A mode that blanks the
   screen therefore fixes itself. Keys pressed while the screen is dark are ignored, and Ctrl-C
   also reverts.
4. `s` saves the current mode as the display's default. You choose what the rule covers:
   * this model (matched by name),
   * only this unit (matched by serial),
   * or whatever is plugged into that port.

   You also choose whether to pin the resolution and refresh rate.

The daemon pauses while setup runs, so it doesn't undo your trials. The pause is a lease that
setup keeps renewing, so if setup is killed the daemon resumes within about a minute. Saving
rewrites the config with a standard comment header. The version from before the session is
kept as `config.json.bak`.

## Configuration

`/usr/local/etc/mac-display/config.json` is JSON with comments and trailing commas. You can
edit it with sudo. The daemon picks up changes within a few seconds. An invalid edit is logged
and the previous version stays in effect. Check a file with `mac-display check-config`. For a
fully commented example, see [`examples/config.json`](examples/config.json).

```jsonc
{
  "pollIntervalSeconds": 15,
  "displays": [                        // first matching rule wins
    {
      "label": "Samsung Odyssey G9",
      "match": { "name": ["LC49G95T", "LC49D95T"] },
      "colorMode": { "bitDepth": 8, "hdr": false, "encoding": "ycbcr444", "range": "limited", "colorimetry": "bt709" },
      // "timing": { "resolution": "5120x1440", "refreshHz": 60 },
    },
    {
      "label": "Office Dell, by serial",
      "match": { "vendor": "DEL", "serial": "ABC1234" },
      "colorMode": { "bitDepth": 10, "encoding": "rgb", "range": "full" },
    },
  ],
}
```

| `match` key | meaning |
|---|---|
| `name` | EDID product name, as shown by `mac-display list`. Globs (`LC49*`) are OK; case-insensitive |
| `vendor` | EDID manufacturer ID, e.g. `SAM`, `DEL`, `GSM` |
| `productID` | EDID product ID (number) |
| `serial` | EDID serial (alphanumeric or numeric). Use it to tell two identical monitors apart |
| `port` | display pipe, e.g. `dispext0` |

Each key takes a value, or a list meaning "any of". Every key you give must match, and `{}`
matches every display. A display that matches no rule is left alone.

| `colorMode` key | values |
|---|---|
| `bitDepth` | `6`, `8`, `10`, `12` |
| `encoding` | `rgb`, `ycbcr444`, `ycbcr422`, `ycbcr420` |
| `range` | `full`, `limited` |
| `hdr` | `false` (SDR) or `true` (any HDR) |
| `eotf` | `sdr`, `pq`, `hlg` (more specific than `hdr`) |
| `colorimetry` | `bt709`, `bt601`, `bt2020`, `bt2020rgb`, `srgb`, … |
| `id` | exact colour-element ID from `mac-display list` |

| `timing` key | values |
|---|---|
| `resolution`, or `width` / `height` | e.g. `"5120x1440"` |
| `refreshHz` | e.g. `60`, matched within `refreshToleranceHz` (default 0.5) |
| `id` | exact timing ID from `mac-display list --timings` |

Only the attributes you give are enforced. The rest stay as close to the current mode as
possible, and remaining ties go to the mode macOS rates highest. Give every attribute (or
`id`) to pin exactly one mode.

A rule without `timing` never changes the resolution or refresh rate. A rule with `timing`
changes only what it asks for: for example, `refreshHz` alone keeps the resolution. It also
picks a timing that offers the requested colour mode.

`mac-display list --json` prints each mode using these same keys and values, so you can copy
them straight into a rule.

Other top-level settings:

| key | default | meaning |
|---|---|---|
| `pollIntervalSeconds` | `15` | safety-net re-check; events trigger checks immediately (`0` = off) |
| `logLevel` | `info` | `debug` also logs every check and IOKit event |
| `logMaxKB`, `logKeep` | `1024`, `3` | log rotation (see Logs) |
| `settleDelaySeconds` | `2` | how long display events must be quiet before acting |
| `verifyDelaySeconds` | `4` | how long after a switch to check that it took |
| `maxAttempts` | `5` | switches before backing off, so it never fights another app forever. Resets on wake, reconnect or config change |

## Commands

```
mac-display setup                       interactive: try modes live, save the one you want
mac-display status                      daemon health + what the config does to each display
mac-display list [--timings] [--json]   displays, current mode, available modes (* = current)
mac-display logs [-f] [-n N|all]        the daemon log, across rotated files; -f follows it
mac-display apply [--dry-run]           apply the config once
mac-display set --depth 8 --encoding ycbcr444 --range limited --sdr [--display SEL] [--dry-run]
mac-display check-config [--config PATH]
mac-display default-config              print a starter config with no rules
mac-display daemon                      what the LaunchDaemon runs
```

Everything except `setup` works as a normal user. `--config PATH` points `status`, `apply` and
`check-config` at another file, which is handy for trying a config before installing it.

## Logs and troubleshooting

Start with `mac-display status`. It shows whether the daemon is running, its last error and
log line, and what it will do to each display.

`mac-display logs -f` follows the log at `/Library/Logs/mac-display/mac-display.log`. The log
records daemon start, config loads and errors, and every switch: the old mode, the new mode,
and what triggered it. It also records the verified result, sleep/wake, disconnects, and
anything that couldn't be applied. It stays quiet while nothing changes.

* **Bounded size:** the daemon rotates its own log. At `logMaxKB`, `.log` becomes `.1`, `.1`
  becomes `.2`, and so on. Only `logKeep` old copies are kept, about 4 MB with the defaults.
* **Unified log:** the same lines go to the macOS unified log, which also holds startup
  failures. View them with
  `/usr/bin/log show --last 1d --predicate 'subsystem == "local.mac-display"'`, or in
  Console.app filtered on `local.mac-display`.
* **Debug detail:** set `"logLevel": "debug"` in the config (picked up live) to see every check
  and IOKit event.
* **Restart the daemon:** `sudo launchctl kickstart -k system/local.mac-display`
* **launchd details:** `sudo launchctl print system/local.mac-display`

## How it works

* On Apple silicon, the display coprocessor (DCP) publishes each monitor's supported *colour
  elements* and *timing elements* in the IORegistry, as `ColorElements` / `TimingElements` on
  `IOMobileFramebufferShim`. The current pair is read and switched with the private
  `IOMobileFramebufferGetDigitalOutMode` / `SetDigitalOutMode` calls.
* These are plain IOKit calls. They don't involve WindowServer or a user session, so a root
  LaunchDaemon can make them at the login window.
* The daemon wakes on IOKit display events (DCP AV/DP proxies appearing, disappearing or
  posting link messages) and on system wake. Once events have been quiet for
  `settleDelaySeconds`, it compares the current mode with the rule, switches if needed, and
  verifies the result. A cheap poll catches anything missed.
* **Loop protection:** retries back off (3 s, 10 s, 30 s, 60 s) and stop after `maxAttempts`.
  More than 10 switches in 10 minutes on one display also pauses that display, even if it
  keeps disconnecting and reconnecting.

## Caveats

* This relies on private Apple API, which a future macOS could change. If that happens, the
  daemon logs an error and does nothing; it doesn't crash-loop. Use at your own risk.
* The FileVault unlock screen, shown before macOS starts, is not affected. Everything from the
  macOS login window onwards is.
* If BetterDisplay or another tool is set to force a *different* connection mode, the two will
  fight. mac-display backs off after `maxAttempts` switches and logs a warning. Using
  BetterDisplay for everything else is fine.
* **Encoding codes:** DCP code 3 is YCbCr 4:4:4 and code 2 is 4:2:2. DCP scores 3 higher, only
  3 is DSC-capable, and BetterDisplay labels them the same way. Asahi Linux's headers have
  them the other way round. `mac-display list --json` shows the raw codes.

## Uninstall

```sh
./uninstall.sh            # stop the daemon, remove the binary, symlink and plist
./uninstall.sh --purge    # also delete the config, its backup and the logs
```

## Development

```
Sources/mac-display/
  main.swift          CLI: argument parsing and commands
  Setup.swift         interactive setup, daemon pause lease, safe config writing
  Daemon.swift        the daemon: IOKit/power/config events, enforcement, loop protection
  Planner.swift       chooses the colour/timing pair that satisfies a rule
  Config.swift        config model and strict JSON5 decoding
  ConfigWriter.swift  renders a config back to commented JSON
  Model.swift         DCP colour/timing elements and their vocabularies
  Registry.swift      IORegistry access (displays, EDID attributes, elements)
  PrivateAPI.swift    IOMobileFramebuffer loader (dlopen/dlsym)
  DaemonStatus.swift  launchd/log inspection for `status`
  Log.swift           logging, self-rotating log file
examples/config.json  annotated example config
launchd/              LaunchDaemon plist
install.sh, uninstall.sh
```

Build and run without installing:

```sh
swift build -c release
.build/release/mac-display list
.build/release/mac-display status --config examples/config.json
```

`MAC_DISPLAY_SETUP_NO_SUDO=1 .build/release/mac-display setup --config /tmp/test.json` runs
setup without sudo, for testing. In that mode it can't pause an installed daemon.

## License

[Apache 2.0](LICENSE)
