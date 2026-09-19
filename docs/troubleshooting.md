# Troubleshooting

## `keyboard not found`

The board exposes several hidraw interfaces and only one is the Oryx raw interface
(usage page `0xFF60`). List what is actually there:

```python
python3 -c "import hid; [print(d['path'], hex(d.get('usage_page',0)), d.get('product_string')) for d in hid.enumerate(0x3297, 0)]"
```

On Linux, without hidapi:

```bash
for n in /sys/class/hidraw/hidraw*; do
  grep -q 3297 "$n/device/uevent" && echo "$n $(grep HID_NAME "$n/device/uevent")"
done
```

If nothing lists, the board is not plugged in, or it is on stock non-Oryx firmware.

## `no permission to open /dev/hidrawN`

Install the udev rule and **replug** — udev rules apply when the device appears, not when the
rule is written.

```
./host/install.sh
udevadm control --reload
```

Check it took: `udevadm info -q property -n /dev/hidrawN | grep TAGS` should include `uaccess`.

## Wrong `hid` package

`hid` and `hidapi` are different PyPI packages that both import as `hid`. This needs `hidapi`.

```
pip3 uninstall hid && pip3 install hidapi
```

Or just `voyager-layer --setup`, which builds an isolated venv with the right one.

## `asked for mac (0), keyboard reports omarchy (2)`

The firmware has no fold hook and the default layer is not 0. Key lookup uses
`get_highest_layer(layer_state | default_layer_state)`, so `layer_move(0)` cannot win against
a default layer of 2.

Either flash the custom firmware, or find whatever set the default layer — a `DF()` key, or
firmware OS detection.

It also appears if `tools/layers.conf` and `~/.config/voyager-layer/config` have drifted.
Re-run `host/install.sh` after changing layer indices.

## The udev rule does not fire

```
systemctl --user status voyager-omarchy.service
journalctl --user -u voyager-omarchy.service
udevadm info -q property -n /dev/hidrawN | grep -E "TAGS|SYSTEMD"
```

`TAGS` must include `systemd`, otherwise `SYSTEMD_USER_WANTS` is ignored
(`systemd.device(5)`). At boot the unit cannot fire at all — the board is already present when
the user service manager starts, so no `add` event happens. That case is the Hyprland
autostart line's job; see [omarchy.md](omarchy.md).

## Keymapp's live view froze

Expected. A base switch — from the script or a `TO()` key — clears the pairing flag, and the
board stops reporting. Reopen Keymapp and it pairs again.

## The keyboard keeps reporting key events

Check what is open. Keymapp keeps the board paired for as long as it runs, so anything
observing raw HID will see traffic. Quit it, then switch base layers once: the switch is what
clears the flag, not merely closing Keymapp.

Remember you cannot observe quiet with `voyager-layer events` — pairing is what makes the
board report. See [protocol.md](protocol.md).

## The amber indicator stopped following the base

The status LEDs are dark on both bases by design, so the per-key amber `1`/`2` key is the only
cue left. If it is stuck on the Mac row while you are on Omarchy, the RGB edit in
`tools/apply_customizations.sh` did not land — Oryx picks the row with
`biton32(layer_state)`, which cannot see the default layer. Re-run the build and check the
**Apply customizations** step lists `keymap.c: RGB row follows default_layer_state`.

## A layer stopped working after an Oryx edit

Run the checks:

```
./tools/verify_layout.sh          # layer count, per-layer key counts, thumb keys
./tools/check.sh                  # the above plus tests, syntax and a dry run
```

`verify_layout.sh` diffs against `tools/layout.snapshot.json` and prints what changed. If you
renumbered a base layer, update `tools/layers.conf`, rebuild, reflash, and re-run
`host/install.sh`.

Layers 1 and 3 belong to one base each and are unreachable from the other — that is by design,
not a fault. Layers meant to be shared must be numbered **above both bases**.

## The build fails

- `arm-none-eabi-gcc: not found` — the Dockerfile lost its toolchain install. See
  [firmware.md](firmware.md); `qmk setup` cannot supply it.
- `rawhid_state undeclared` — `base_layers.h` lost its `oryx.h` include.
- `anchor missing in keymap.c` — Oryx changed its output. The message names the anchor; fix
  the pattern in `tools/apply_customizations.sh`.
- `was customized for a different variant` — the layout tree already carries the other
  OS-detection variant. Restore the generated files and re-run.
