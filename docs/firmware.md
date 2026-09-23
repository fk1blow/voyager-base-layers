# Firmware

The layout is built from Oryx through ZSA's
[oryx-with-custom-qmk](https://github.com/zsa/oryx-with-custom-qmk) template, with a small
QMK hook added at build time.

## Updating the layout from Oryx

This is the routine you will actually use. It is designed so that editing the layout in Oryx
never means redoing the custom work.

`tools/refresh.sh` runs steps 2-6 and the install, then stops and hands you the `.bin`. It
refuses to start on a dirty tree, on a branch other than `main`, or with unpushed commits,
because the workflow pushes to `main` and the pull afterwards has to fast-forward. Flashing
stays manual: Keymapp is a GUI, and putting the wrong file on the board is worth doing by
hand. The steps below are what it automates.

1. Edit the layout in Oryx, then press **Compile** there.
2. Run the **Fetch and build layout** workflow (`layout_id: 7m5PJ`). The ZSA browser
   extension can start it from inside Oryx. Leave `layout_geometry` alone — it is the
   template's knob for its other boards, and `voyager` is already the default.
3. The workflow fetches into the `oryx` branch, merges into `main`, verifies the layout,
   applies the customizations, and builds.
4. If it fails, the log names the anchor that broke. Usually a one-line pattern fix in
   `tools/apply_customizations.sh`, then re-run.
5. If you renumbered a layer, update `tools/layers.conf` and re-run — **and** re-run
   `host/install.sh` so `~/.config/voyager-layer/config` matches. This is the one change that
   has to land on both sides; if they drift you get
   `error: asked for omarchy (2), keyboard reports …`. See *Layer order* below — you do not
   have to notice this yourself.
6. The workflow has **already committed and pushed** the refreshed layout — it does that
   before it verifies or builds. Read the diff the **Verify layout assumptions** step printed;
   if the change was intentional, run `tools/verify_layout.sh --update` locally and commit the
   updated `tools/layout.snapshot.json`. That snapshot is the only thing left for you to
   commit, and it is what makes the next run's diff meaningful.
7. Download the `.bin` artifact and flash it with Keymapp.
8. Re-check: `voyager-layer status`, LEDs dark on both bases, and the per-key amber indicator
   still following the base.

### Combo timing

QMK's default `COMBO_TERM` is 50 ms: every key of a combo must go down within
50 ms of the first, or the combo is abandoned and the keys arrive as ordinary
keystrokes. A chord that switches layers tends to be two-handed and misses that
window easily -- it looks exactly like "the combo does nothing", except a stray
character is typed.

Raising `COMBO_TERM` globally is not the fix: Oryx layouts put combos on letter
keys too, and at 150 ms a `B`+`V` combo fires inside "obvious". So
`base_layers.c` defines `get_combo_term()` and lengthens only the combos whose
action is `TO()` or `TG()`; everything else keeps the default.

It is keyed on the combo's **action**, never its index. Oryx renumbers
`combo0..comboN` whenever a combo is added or removed, so an index-based rule
would silently attach to the wrong chord after an unrelated edit.

`tools/apply_customizations.sh --combo-term MS` changes the window; the value is
part of the variant marker, so a tree customized for one term is never reused
for another.

### Layer order

Oryx names nothing. Its `keymap.c` is `[0] = LAYOUT_voyager(...)` through `[5]`, and
`keymap.json` carries only the module list, so nothing in the generated output says which
layer is the Omarchy base. `tools/layers.conf` asserts it, and a reorder in Oryx silently
invalidates that assertion: if `omarchy` slides from 2 to 3, layer 2 still exists, so an
index-range check passes and you flash a board whose Omarchy base is a symbol layer.

So the snapshot records a fingerprint — a hash of each layer's key list — plus one per base
under `bases`, keyed by name. On the next run `verify_layout.sh` asks whether the keys it
recorded for `omarchy` are still at the index `layers.conf` claims:

- **Same index, same keys** — nothing to say.
- **Moved to another index** — hard failure, naming the index to put in `layers.conf`. This is
  the case that would otherwise bite after flashing.
- **Still at that index, keys changed** — you edited the base. Reported as an ordinary change.
- **Ambiguous** (the old keys now match several layers, e.g. two blank ones) — hard failure
  asking you to check Oryx by hand rather than guessing.

`host/tests/test_verify_layout.py` drives all of these against synthetic Oryx output. A
snapshot recorded before fingerprints existed says so and skips the check until `--update`.

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
| `COMBO_TERM_PER_COMBO` + `BASE_LAYERS_COMBO_TERM` | how long a layer-switch chord may take, in ms (default 150) |

The first two have build flags: run the workflow with `os_detection: true`, and
`keyboard_reset: true` if a dock hands the board over without cutting power (that one implies
`os_detection`). Locally the same switches are
`tools/apply_customizations.sh --os-detection --keyboard-reset`.

`BASE_LAYERS_KEEP_PAIRING` has no flag — it is always emitted commented out. Turning it on
means hand-editing the generated `config.h` before building, which the build does not
preserve. Add a flag if you ever need it regularly.

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

## Checking a change without a keyboard

```
./tools/check.sh
```

Runs the host tests against the firmware model, compiles `voyager-layer`, `bash -n` and
shellcheck on every shell script, `verify_layout.sh`, and `apply_customizations.sh --dry-run`.

`.github/workflows/host-tests.yml` runs **this same script** on every push or PR touching
`host/**` or `tools/**`, so a red check there reproduces locally with one command.

## Flashing

Keymapp, using its flash-a-local-file option — not the layout list, which would put stock
firmware back. The board resets to layer 0.

Keymapp's live view freezes after any base switch, because the switch clears the pairing flag.
Reopen Keymapp and it works again. This is the accepted trade-off.
