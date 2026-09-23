# voyager-base-layers

One [ZSA Voyager](https://www.zsa.io/voyager), shared between a Mac and an
[Omarchy](https://omarchy.org/) (Arch + Hyprland) box. Both want the same layout, but not the
same base layer: the Mac sits on `mac` (0), Omarchy on `omarchy` (2). A keyboard only has one
active base at a time, so something has to pick.

Nothing runs in the background. The board powers up on the Mac base, and the Omarchy machine
switches itself to `omarchy` the moment the board appears — on plug-in via a udev rule, and at
login via Hyprland autostart, since a board that is already plugged in fires no `add` event.
Both paths run the same one-shot: `voyager-layer omarchy --wait 5`.

Making that reliable needs a small QMK hook, because stock Oryx firmware turns a new base
layer *on* instead of making it the default, which leaves the board typing on the wrong layer
and a status LED stuck lit. The hook lives outside the Oryx-generated layout and is re-applied
at build time, so editing the layout in Oryx never means redoing it. Details in
[docs/firmware.md](docs/firmware.md).

## Setup on Omarchy

```bash
./host/install.sh --autostart
```

Installs `voyager-layer` / `voyager-test` into `~/.local/bin`, writes the layer config from
`tools/layers.conf`, adds the udev rule (asks for sudo) and the systemd user unit, and appends
the Hyprland autostart line. Without `--autostart` it prints that line instead of editing
anything; `--keybind` also adds a `SUPER + CTRL + V` toggle; `--dry-run` and `--uninstall` do
what they say. Re-running is safe.

Verify with a replug — within about a second:

```bash
voyager-layer status        # omarchy (2)
```

Full breakdown of each piece in [docs/omarchy.md](docs/omarchy.md); the Mac side is
[docs/macos.md](docs/macos.md).

## Updating the layout

Edit the layout in Oryx and press **Compile**. Everything after that is
[**Fetch and build layout**](.github/workflows/fetch-and-build-layout.yml), a GitHub Actions
workflow in this repo: it pulls your new layout from Oryx, merges it into `main`, updates QMK,
re-applies the customizations, and builds a `.bin`. It runs on GitHub's machines, not this
one — the build wants Docker and the ARM toolchain — and only when you start it.

The short way is one command, which does everything below and stops at the flash:

```bash
tools/refresh.sh
```

It dispatches the workflow, waits for it, pulls what it pushed, shows the layout diff and
offers to record it, runs the checks, re-runs `host/install.sh`, and drops the firmware in
`build/`. `--dry-run` shows what it would do; `--os-detection` picks that variant;
`--no-install` skips the last step. The rest of this section is what it does, by hand.

To start the build yourself, two ways:

**From Oryx.** The ZSA browser extension adds a button to your layout page that dispatches the
workflow directly. This is the path to use when you are already in Oryx.

**From the terminal.**

```bash
gh workflow run fetch-and-build-layout.yml -f layout_id=7m5PJ
```

Keep that one `-f`: with no flags at all, `gh` prompts for every input. Everything else falls
back to its default — including `layout_geometry: voyager`, which you never change. Add
`-f os_detection=true` only for that firmware variant ([docs/firmware.md](docs/firmware.md)).

Then watch it and collect the `.bin` (~2 minutes):

```bash
run=$(gh run list -w fetch-and-build-layout.yml -L1 --json databaseId -q '.[0].databaseId')
gh run watch "$run"
gh run download "$run" -D ~/Downloads
```

The `.bin` is never committed — it exists only as an artifact on that run, for 90 days. The
download lands at `~/Downloads/voyager_7m5PJ/zsa_voyager_7m5PJ.bin`; in the browser it is the
*Artifacts* section of the run summary, as a zip.

Afterwards — all of this is what `tools/refresh.sh` automates:

1. **`git pull`** — the workflow already committed and pushed the refreshed layout.
2. **Read the diff** printed by the *Verify layout assumptions* step. If the change was
   intentional, `tools/verify_layout.sh --update` and commit the snapshot. That is what makes
   the next run's diff meaningful, and it is the only thing left for you to commit.
3. **If you renumbered a base layer in Oryx**, update `tools/layers.conf` and re-run
   `host/install.sh`. The indices are deliberately duplicated between firmware and host, and
   this is the one place they are kept in sync by hand. `verify_layout.sh` fingerprints both
   base layers, so a base that moved to a different index is a hard failure naming the new
   one — it will not let you flash a board whose Omarchy base is really a symbol layer.
4. **Flash** with Keymapp's *flash a local file*, not its layout list, which would put stock
   firmware back.
5. **Re-check**: `voyager-layer status`, LEDs dark on both bases, amber `1`/`2` key indicator
   still following the base.

If the build fails, it is almost always Oryx having moved code that
`tools/apply_customizations.sh` anchors to. The script refuses to guess, and the log names the
pattern that broke; the fix is usually one line. `./tools/check.sh` reproduces the host and
customization checks locally, no keyboard needed.

## voyager-layer

Rarely needed by hand, since udev and autostart cover the normal cases. It talks to the board
over raw HID using ZSA's Oryx protocol — no Keymapp, no kontroll, no daemon — and works on
stock Oryx firmware too.

```bash
voyager-layer status        # print the active layer
voyager-layer toggle        # flip between the two bases
voyager-layer mac           # or: omarchy, or a bare layer index
voyager-layer events 10     # debug dump; type during it
```

`toggle` earns its keybind mainly for a dock that switches hosts without cutting power: that
leaves the board on the Omarchy base, so the Mac inherits the wrong one. `voyager-test` is a
guided round trip that asks you to confirm by hand that the board behaves like the layer it
just switched to.

## Docs

- [docs/firmware.md](docs/firmware.md) — the build workflow, the hook, updating from Oryx
- [docs/omarchy.md](docs/omarchy.md) — udev, systemd, Hyprland autostart, the optional keybind
- [docs/macos.md](docs/macos.md) — setup, and what a host-switching dock means
- [docs/protocol.md](docs/protocol.md) — the Oryx raw HID protocol, and what the board reports
- [docs/troubleshooting.md](docs/troubleshooting.md) — when something does not work
