# The Oryx raw HID protocol

Verified against [`zsa/qmk_modules`](https://github.com/zsa/qmk_modules) `oryx/oryx.c` and
`oryx/oryx.h`, and [`zsa/qmk_firmware`](https://github.com/zsa/qmk_firmware) branch
`firmware25` (`keyboards/zsa/voyager/voyager.c`, `quantum/action_layer.c`). Re-check if the
firmware version has moved on.

## Transport

Raw HID, usage page `0xFF60`, usage `0x61`, 32-byte reports, vendor ID `0x3297`.

- **Linux:** `/dev/hidrawN`, writing `0x00` (report ID) followed by 32 bytes.
- **macOS:** hidapi (`pip install hidapi`, **not** `hid`).

Pick the node by walking `/sys/class/hidraw/*` for one whose `HID_ID` names vendor `3297` and
whose report descriptor contains the `0xFF60` usage page. The board exposes several hidraw
nodes and only one of them is this interface.

## Commands

| Code | Command | Notes |
|---|---|---|
| `0x00` | GET_FW_VERSION | |
| `0x01` | PAIRING_INIT | Sets the flag instantly, no key sequence. Replies `0x04` PAIRING_SUCCESS, then `0x05` LAYER with the live value. |
| `0x02` | PAIRING_VALIDATE | no-op, kept for old clients |
| `0x04` | SET_LAYER `[on, layer]` | `on=1` → `layer_move(layer)`. **Ignored unless paired.** |
| `0x05` / `0x06` / `0x09` | RGB control / set one key light / set all | |
| `0x07` | SET_STATUS_LED `[idx, on]` | takes LED control from the firmware |
| `0x08` | brightness up/down | |
| `0x0A` | STATUS_LED_CONTROL `[0/1]` | `0` hands LED control back to the firmware |
| `0x0B` / `0x0C` | automouse set/get | |
| `0xFE` | GET_PROTOCOL_VERSION | |
| anything else | → error reply | `0x03` DISCONNECT is in the enum but **not handled** |

## Events

- `0x05` LAYER `[layer]` — `get_highest_layer(layer_state | default_layer_state)`
- `0x06` KEYDOWN / `0x07` KEYUP `[col, row]`

## Hook order

`layer_state_set`: modules (oryx) → `_kb` → `_user`, and `layer_state` is assigned **after**.
`default_layer_state_set` works the same way. So the module's own layer event is computed
before custom code runs and while the old value is still in place — which is why a base switch
emits a stale event first and the accurate one second. See [firmware.md](firmware.md).

`raw_hid_receive` in `oryx.c` is not weak, so custom code cannot replace the command handler.
`rawhid_state` and `oryx_layer_event()` are declared in `oryx.h` and can be used from custom
code — but `QMK_KEYBOARD_H` does not pull that header into a plain `SRC` file, so include it
explicitly.

## What the board reports, and when

Facts, not warnings.

- The pairing flag (`rawhid_state.paired`) is a boolean in the keyboard's RAM, not a
  connection. It starts **off** at power-up, and nothing is reported until something —
  Keymapp, `voyager-layer` — pairs on purpose.
- While paired, the board pushes a report on every key press and release and every layer
  change. If no program has the interface open, the OS discards them.
- **Stock firmware keeps the flag set until power loss** (or a report that cannot be delivered
  within 100 ms). The custom firmware in this repo clears it on every base switch.
- Reports carry key **positions** (col, row), not characters. Do not read that as protection:
  the board's USB serial number *is* the Oryx layout id and revision (e.g. `7m5PJ/nlz66J`), a
  public layout can be fetched anonymously, and layer changes are broadcast too — so positions
  decode easily.
- Any program that pairs on purpose can read events. Identical on stock and custom firmware.
- Where Keymapp is installed, `/usr/lib/udev/rules.d/50-wally.rules` sets `MODE:="0666"` on
  every ZSA device, so the raw interface is world-readable there. That, not `uaccess`, is what
  grants access on such a machine.

None of this is a meaningful attack surface: anything that can open the raw interface is
already running as you, with far easier ways to read your keystrokes. The custom firmware's
quiet behaviour is tidiness — it stops emitting USB traffic nobody reads, and makes the switch
reply deterministic.

### Observing it

There is a catch worth knowing: **you cannot read the layer without pairing**, and pairing is
what makes the board start reporting. So `voyager-layer events` can never show you the board
being quiet — the act of looking turns reporting back on.

To check the flag really was cleared, send `SET_LAYER` **without** pairing first. It is gated
on the flag, so if the layer does not move, the board was unpaired:

```
voyager-layer omarchy      # switch -> custom firmware goes quiet
# now, on a raw handle with no PAIRING_INIT, send SET_LAYER mac
voyager-layer status       # still omarchy (2) -> the command was ignored
```

The same catch applies to anything that wants to *display* the current layer, such as a status
bar widget: polling would re-pair the board constantly and undo the quiet behaviour. Read state
that `voyager-layer` writes on switch instead of asking the keyboard.
