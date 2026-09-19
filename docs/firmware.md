# Firmware

The layout is built from Oryx through ZSA's
[oryx-with-custom-qmk](https://github.com/zsa/oryx-with-custom-qmk) template, with a small
QMK hook added at build time.

## Updating the layout from Oryx

This is the routine you will actually use. It is designed so that editing the layout in Oryx
never means redoing the custom work.

1. Edit the layout in Oryx, then press **Compile** there.
2. Run the **Fetch and build layout** workflow (`layout_id: 7m5PJ`, `layout_geometry: voyager`).
   The ZSA browser extension can start it from inside Oryx.
3. The workflow fetches into the `oryx` branch, merges into `main`, verifies the layout,
   applies the customizations, and builds.
4. If it fails, the log names the anchor that broke. Usually a one-line pattern fix in
   `tools/apply_customizations.sh`, then re-run.
5. If you renumbered a layer, update `tools/layers.conf` and re-run — **and** re-run
   `host/install.sh` so `~/.config/voyager-layer/config` matches. This is the one change that
   has to land on both sides; if they drift you get
   `error: asked for omarchy (2), keyboard reports …`.
6. Read the **Verify layout assumptions** step's diff in the workflow log, then commit the
   refreshed layout and, if the change was intentional, an updated snapshot
   (`tools/verify_layout.sh --update`).
7. Download the `.bin` artifact and flash it with Keymapp.
8. Re-check: `voyager-layer status`, LEDs dark on both bases, and the per-key amber indicator
   still following the base.

### Three rules that make this work

1. **Generated files are never edited in git.** `7m5PJ/` holds exactly what Oryx produced, so
   the template's `git merge -Xignore-all-space oryx` can never conflict. The only files
   committed inside it are `base_layers.c` and `base_layers.h`.
2. **Customizations are applied at build time**, idempotently, by a script that fails loudly.
3. **Every refresh prints a diff** of what changed in the layout, so a renumbered layer cannot
   slip through silently.

## The hook

`base_layers_fold()` runs from `layer_state_set_user`. Any request to turn **on** a base layer
— the host's `SET_LAYER`, a `TO()` key, `TG()` — becomes a `default_layer_set()` instead, and
the base bits are stripped from `layer_state`.

Why it is required: key lookup uses `get_highest_layer(layer_state | default_layer_state)`.
Once the default layer is 2, `layer_move(0)` leaves the highest at 2, so the keyboard stays on
Omarchy while the script thinks it asked for Mac. The firmware model reproduces this in
`Stock.test_default_layer_conflict_is_reported`.

### Power-up is always the Mac base

The hook uses `default_layer_set()`, the RAM-only variant — never
`set_single_persistent_default_layer()`. Nothing is written to EEPROM, so `default_layer_state`
always starts at layer 0 after a power cycle, whatever base was active when power was lost.

This is deliberate and worth relying on: a board that loses power is guaranteed to hand the
Mac the right base, and on Omarchy the udev rule switches it back within a second. It is also
the reason a dock that switches hosts *without* cutting power needs help — see
[macos.md](macos.md).

### Going quiet

In the same hook, if a host is paired, the firmware sends one LAYER event and clears
`rawhid_state.paired`. The board then reports nothing until something pairs again.

**A base switch produces more than one LAYER event.** The oryx module's own
`layer_state_set` hook runs *before* ours (modules → `_kb` → `_user`) and computes its value
while `default_layer_state` still holds the old base — QMK assigns it after the hook chain, see
`quantum/action_layer.c`. So the first event names the base you are *leaving*; ours is last and
correct. `voyager-layer` scans for the target rather than trusting the first event.

Clearing the flag *before* the switch instead of after was tried and makes no difference: the
module's second hook computes the same value as its first, so its own dedup already suppresses
it. Identical on the wire.

## Configuration

`config.h` carries a commented options block, written by `apply_customizations.sh`:

| Define | Effect |
|---|---|
| `BASE_LAYERS_OS_DETECTION` | pick the base layer from the detected host OS (needs `OS_DETECTION_ENABLE`) |
| `OS_DETECTION_KEYBOARD_RESET` | re-detect when a KVM or dock changes hosts without power loss |
| `BASE_LAYERS_KEEP_PAIRING` | do not clear the pairing flag on base switches |

**OS detection is off by default.** It is a heuristic, and a USB hub or dock can fool it. To
build with it on, run the workflow with `os_detection: true` — that sets both defines. Note
`config.h` also defines `LAYER_STATE_8BIT`, so the board is capped at 8 layers.

## What to re-check after Oryx changes

`tools/apply_customizations.sh` makes five edits and fails if any anchor is missing. Two are
worth knowing about because they touch generated code:

- **The fold hook** is appended only if Oryx did *not* define `layer_state_set_user` itself.
  If Oryx starts generating one, the script stops and tells you to add
  `state = base_layers_fold(state);` as its first line.
- **The per-key RGB row.** Oryx picks it with `switch (biton32(layer_state))`, which cannot see
  the default layer — after the fold both bases would light `ledmap[BASE_MAC]`. The script
  rewrites it to `get_highest_layer(layer_state | default_layer_state)`. This is the only
  in-place edit to a generated function, and the amber `1`/`2` key indicator is the only
  visual cue for which base is active, since the status LEDs are dark on both. If that
  indicator stops following the base, this edit is what broke.

## Build notes

Two deviations from ZSA's template, both required:

- **The Dockerfile installs the ARM toolchain.** The template leaves it to `qmk setup`, which
  cannot do it: the workflow bind-mounts the `qmk_firmware` *submodule*, whose `.git` is a file
  pointing outside the mount, so QMK sees "not a git repository" and skips dependency
  installation. Without this the build dies on `arm-none-eabi-gcc: not found`.
- **The `oryx` branch had to be created.** The workflow checks it out, but ZSA's copy of the
  template ships only `main`. It was branched from `main` so the merge has shared history.
  Never commit to `oryx` by hand.

## Flashing

Keymapp, using its flash-a-local-file option — not the layout list, which would put stock
firmware back. The board resets to layer 0.

Keymapp's live view freezes after any base switch, because the switch clears the pairing flag.
Reopen Keymapp and it works again. This is the accepted trade-off.
