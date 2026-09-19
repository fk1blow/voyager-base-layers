# voyager-base-layers

Switch a [ZSA Voyager](https://www.zsa.io/voyager) between two base layers — one for macOS,
one for [Omarchy](https://omarchy.org/) — and have each machine pick the right one by itself.

Two halves, usable separately:

- **Host scripts.** `voyager-layer` talks to the keyboard over raw HID using ZSA's Oryx
  protocol. No Keymapp, no kontroll, no daemon. Works on stock Oryx firmware too.
- **Custom firmware.** The Oryx layout plus a small QMK hook, built through ZSA's
  GitHub Actions template. The layout stays 100% Oryx; the hook is applied at build time.

```
voyager-layer status      # mac (0)
voyager-layer omarchy     # switched to omarchy (2)
voyager-layer toggle      # switched to mac (0)
```

## Layers

| Layer | Name | |
|---|---|---|
| 0 | `mac` | **base** |
| 1 | `mac/sys` | reachable only from the Mac base |
| 2 | `omarchy` | **base** |
| 3 | `oma/sys` | reachable only from the Omarchy base |
| 4 | `symbols` | shared |
| 5 | `l nav` | shared |

Indices live in [`tools/layers.conf`](tools/layers.conf) — the single source of truth for the
firmware, the host scripts and the tests. Change them there and nowhere else.

## What the firmware hook does

QMK keeps two separate variables: `default_layer_state` (the base) and `layer_state`
(momentary layers). Stock Oryx switches base layers by turning them **on** in `layer_state`.
This firmware folds any such request into `default_layer_set()` instead. Three consequences:

- **The script and the firmware always agree** on which base is active. Without the fold,
  once the default layer is 2, `voyager-layer mac` moves `layer_state` to 0 but key lookup
  still takes the highest of `layer_state | default_layer_state` — and reports `omarchy (2)`.
- **The status LEDs stay dark on both bases**, because the stock Voyager LED code only reads
  `layer_state`. Layers that are not bases still light them exactly as before.
- **Power-up is always Mac.** The hook uses `default_layer_set()`, the RAM-only variant,
  never the persistent one — nothing is written to EEPROM. So every power cycle comes up on
  layer 0, whatever base it was on when it lost power. Unplug, replug: Mac, then Omarchy's
  udev rule switches it back within a second.
- **The board goes quiet after a switch.** It answers with one LAYER event, then clears its
  pairing flag and stops reporting until something pairs again. This is tidiness, not a
  security feature — see [docs/protocol.md](docs/protocol.md).

## Modes

| Mode | Firmware | Who switches | LEDs on Omarchy base | Raw HID after a switch | Background software |
|---|---|---|---|---|---|
| Scripts only | stock Oryx | udev / autostart / CLI | lit (layer 2 in binary) | keeps reporting until unplug | none |
| **Firmware + scripts** | custom, detection off | udev / autostart / CLI | dark | quiet | none |
| Firmware only | custom, detection on | the keyboard | dark | quiet | none |

The middle row is the intended setup. OS detection is off by default because a USB hub or
dock can fool it; enable it with the `os_detection` input on the build workflow.

## Quick start

**Omarchy / Linux**

```
./host/install.sh          # scripts, layer config, udev rule, systemd user unit
voyager-layer status
```

Then add the autostart line it prints to `~/.config/hypr/autostart.lua`.
See [docs/omarchy.md](docs/omarchy.md).

**macOS**

```
./host/install.sh          # scripts + the hidapi venv
voyager-layer status
```

See [docs/macos.md](docs/macos.md).

**Firmware** — edit the layout in Oryx, run the *Fetch and build layout* workflow, download
the `.bin` artifact, flash it with Keymapp. See [docs/firmware.md](docs/firmware.md).

## Check it works

```
voyager-layer status
```

That is the one command worth remembering. It prints the active layer and, on a base layer,
quietly re-selects it — which on the custom firmware also makes the board go quiet again.

## Docs

- [docs/firmware.md](docs/firmware.md) — the build workflow, the hook, updating from Oryx
- [docs/omarchy.md](docs/omarchy.md) — udev, systemd, Hyprland autostart, the optional keybind
- [docs/macos.md](docs/macos.md) — setup, and what a host-switching dock means
- [docs/protocol.md](docs/protocol.md) — the Oryx raw HID protocol, and what the board reports
- [docs/troubleshooting.md](docs/troubleshooting.md) — when something does not work
