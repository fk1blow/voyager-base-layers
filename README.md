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

## Scripts

Everything lives in `host/`. Install once, then the only command you need day to day is
`voyager-layer`.

### `install.sh` — one-time setup

```
./host/install.sh [--autostart] [--keybind] [--uninstall] [--dry-run]
```

Copies `voyager-layer` and `voyager-test` to `~/.local/bin`, and writes
`~/.config/voyager-layer/config` from [`tools/layers.conf`](tools/layers.conf) so the scripts
and the firmware always agree on layer numbers.

- On **Linux** it also installs the udev rule and the systemd user unit that switch the
  keyboard to the Omarchy base on plug-in, and prints the Hyprland autostart line rather than
  editing your config for you. `--autostart` appends that line instead of just printing it;
  `--keybind` (implies `--autostart`) also adds a manual toggle keybind. See
  [docs/omarchy.md](docs/omarchy.md) for what each piece does and why boot needs the
  autostart line in addition to udev.
- On **macOS** it also runs `voyager-layer --setup` (below). See [docs/macos.md](docs/macos.md)
  for what to do if a KVM or dock switches hosts without cutting power.
- `--dry-run` prints what it would do without doing it. `--uninstall` removes what it
  installed, but leaves `~/.config/voyager-layer` and anything you added to your Hyprland
  config alone. Re-running plain `install.sh` is always safe — it detects what is already in
  place and changes nothing else.

### `voyager-layer` — switch or query the base layer

```
voyager-layer omarchy        # jump to the Omarchy base layer
voyager-layer mac            # jump to the Mac base layer
voyager-layer toggle         # flip between the two
voyager-layer status         # print the currently active layer
voyager-layer 3              # jump to any layer by index
voyager-layer events [SECS]  # debug: print what the keyboard sends (default 10s)
```

Options:

- `--wait SECS` — keep retrying until the keyboard shows up. Used by the udev unit and the
  Hyprland autostart line to ride out the gap right after plug-in or login.
- `--notify` — show a desktop notification with the result.
- `--setup` — create the private venv the hidapi backend needs (see
  [docs/macos.md](docs/macos.md)) and install `hidapi` into it. The script re-launches itself
  in that venv automatically afterwards, so nothing needs activating by hand.

The base layer names (`mac`, `omarchy`) and their indices come from, in order: the
`VOYAGER_LAYERS` environment variable, `~/.config/voyager-layer/config` (written by
`install.sh`), or the script's built-in defaults. `VOYAGER_BACKEND=hidraw|hidapi` forces a
transport instead of auto-detecting one. On the custom firmware, switching to a base layer
also leaves the keyboard quiet afterwards — see [below](#why-the-firmware-needs-a-hook).

### `voyager-test` — manual verification harness

```
voyager-test              # full round trip: omarchy -> mac -> omarchy, with a summary
voyager-test mac          # switch to the Mac layer, then ask you to verify
voyager-test omarchy      # switch to the Omarchy layer, then ask you to verify
voyager-test toggle       # press Enter to flip layers, q to quit
```

It drives `voyager-layer` for you, then asks you to type in an editor and confirm by hand
whether the keyboard is behaving like the layer it just switched to — there is no way to
check key output without a person at the keyboard.

## Updating the layout from Oryx

You will keep editing the layout in Oryx. That should never mean redoing the firmware
customization by hand — it is re-applied automatically on every build. The short version:

1. Edit the layout in Oryx, then press **Compile** there.
2. Run the **Fetch and build layout** workflow (`layout_id: 7m5PJ`, `layout_geometry: voyager`)
   — the ZSA browser extension can start it from inside Oryx. It fetches the new layout,
   merges it in, verifies it, re-applies the customizations, and builds.
3. If it fails, the log names the anchor that broke — usually a one-line pattern fix in
   `tools/apply_customizations.sh`, then re-run.
4. **If you renumbered a base layer**, update [`tools/layers.conf`](tools/layers.conf) and
   re-run the workflow, **and** re-run `host/install.sh` so the host scripts pick up the new
   numbers. This is the one change that has to land on both the firmware and the host side —
   skip it and you get `error: asked for mac (0), keyboard reports omarchy (2)`.
5. Read the diff the workflow prints for the layout-verification step, then commit the
   refreshed layout and, if the change was intentional, an updated snapshot
   (`tools/verify_layout.sh --update`).
6. Download the `.bin` artifact and flash it with Keymapp.
7. Re-check: `voyager-layer status`, LEDs dark on both bases, and the per-key amber indicator
   still following the base.

The full mechanics — why generated files are never hand-edited, what
`apply_customizations.sh` actually changes, and what to do if it starts failing — are in
[docs/firmware.md](docs/firmware.md).

## Why the firmware needs a hook

QMK actually tracks two different things: which layer you're temporarily holding down (a
symbols layer while a thumb key is pressed, say) and which layer you're just sitting on as
your normal base. Stock Oryx firmware doesn't make that distinction when you ask it to switch
base layers — it turns the new base **on** the same way it turns on a temporary layer, instead
of updating the "this is now my base" variable.

That causes two real problems on a keyboard with two base layers instead of one:

- The keyboard decides what to actually type by combining both variables and taking the
  highest layer. So once you're sitting on the Omarchy base, asking the keyboard to switch to
  Mac can leave it still typing like it's on Omarchy — the request landed in the wrong bucket
  and lost the comparison. That's the `error: asked for mac (0), keyboard reports omarchy (2)`
  you'll see if this ever regresses.
- The keyboard's status LEDs are wired to read that same "temporary layer" variable. Since the
  Omarchy base was being switched on as if it were a temporary layer, sitting on it permanently
  lit an LED — as if you were holding down a key that was never actually released.

The fix in this repo's firmware is small: any request to turn on a base layer gets redirected
into the "this is now my base" variable instead, before it does anything else. With that in
place, the script and the keyboard always agree on which base is active, and the status LEDs
stay dark on both bases — they still light up normally for any layer that isn't a base.

One more effect worth knowing about: right after a base switch, the keyboard sends one reply
and then goes quiet — it stops reporting key and layer events until something (Keymapp,
`voyager-layer`) pairs with it again. This is just tidiness — the board no longer has a reason
to keep talking after a switch — **not** a security measure; [docs/protocol.md](docs/protocol.md)
spells out why it doesn't meaningfully hide anything. It does mean you can't watch the board
being quiet without un-quieting it: the protocol doc has the workaround if you need to verify it.

Worth relying on: the board always powers up on the Mac base, because the fix uses the
RAM-only way of setting the base layer and never writes it to EEPROM. Unplug and replug, and
it's Mac again — Omarchy's udev rule then switches it back within a second.

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
