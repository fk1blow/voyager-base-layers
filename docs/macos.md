# macOS

## Install

```
./host/install.sh
```

On macOS this copies the scripts to `~/.local/bin` and runs `voyager-layer --setup`, which
creates the private venv the `hidapi` backend needs, at `~/.local/share/voyager-layer/venv`,
and installs `hidapi` into it. The script re-launches itself inside that venv automatically
whenever `hidapi` is not importable, so nothing needs to be activated.

It must be **`hidapi`**, not `hid` — two different PyPI packages with a clashing import name.
If the wrong one is installed, `voyager-layer` says so and tells you how to fix it.

If `pip` fails to build it: `brew install hidapi`, then re-run `voyager-layer --setup`.

`install.sh --dry-run` and `--uninstall` work the same as on Linux — see
[omarchy.md](omarchy.md#install). `VOYAGER_BACKEND=hidraw|hidapi` forces a transport
instead of auto-detecting one; the only reason to set it here is to test the Linux path on a
Mac or vice versa.

## Automatic switching

Nothing runs automatically. The board powers up on layer 0, which is the Mac base, so in the
normal case the Mac needs nothing at all.

**Unless your dock switches hosts without cutting power.** Then the board keeps whatever base
it was on — hand it over while it is on `omarchy (2)` and the Mac inherits the Omarchy base.
Options, in increasing order of effort:

1. **Do it by hand.** `voyager-layer mac` after taking the keyboard back, or `voyager-layer
   omarchy` on the Linux side before handing it over. The Omarchy keybind in
   [omarchy.md](omarchy.md) makes the second one a single tap.
2. **A USB watcher.** The Mac still sees a USB attach when the dock hands the board over, even
   though the board never lost power. A [Hammerspoon](https://www.hammerspoon.org/)
   `hs.usb.watcher` matching vendor `0x3297` can run `voyager-layer mac` on attach.
3. **Firmware OS detection.** Build with `os_detection: true` **and** `keyboard_reset: true`
   — the second is the one that matters for a dock that keeps the board powered, since
   without it the firmware never re-runs detection when the host changes. It implies the
   first. This is the only option that needs no host software at
   all — but detection is a heuristic and a dock can fool it, which is why it is off by
   default. See [firmware.md](firmware.md).

Option 1 is what this repo ships. 2 and 3 are documented, not built.

## Testing

```
voyager-layer status
voyager-test
```

Quit Keymapp first. While Keymapp is open it keeps the board paired, which changes what you
observe — see [protocol.md](protocol.md).

Input Monitoring permission should not be needed: this talks to the vendor-defined raw HID
interface (usage page `0xFF60`), not the keyboard interface macOS guards.
