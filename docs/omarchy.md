# Omarchy / Linux

The Omarchy machine switches the keyboard to the Omarchy base itself — on plug-in via udev,
and at login via Hyprland autostart. Nothing runs in the background.

## Install

```
./host/install.sh
```

It copies `voyager-layer` and `voyager-test` to `~/.local/bin`, writes
`~/.config/voyager-layer/config` from `tools/layers.conf`, installs the udev rule (asks for
sudo), installs the systemd user unit, and **prints** the Hyprland snippet without editing
anything.

`--autostart` appends the Hyprland autostart line for you; `--keybind` adds the toggle key
too. `--dry-run` shows what it would do, `--uninstall` backs it out. Re-running is safe, and
both Hyprland edits detect a line that is already there, however it got added.

Note it replaces any dev symlink in `~/.local/bin` with a real copy, so an installed tool does
not break if the repo moves. If you later edit `host/voyager-layer`, re-run `install.sh`.

`voyager-layer` reads its layer names and indices from that written config, unless
`VOYAGER_LAYERS="mac=0,omarchy=2"` is set in the environment — which always wins over the
file — and falls back to its own built-in defaults if neither is present. `VOYAGER_BACKEND`
is unrelated to layer config: it forces the raw-HID transport (`hidraw` on Linux, `hidapi` on
macOS) instead of auto-detecting one, which you'd only need for testing.

## The pieces

### udev — switch on plug-in

`/etc/udev/rules.d/70-zsa-voyager.rules`:

```
KERNEL=="hidraw*", ATTRS{idVendor}=="3297", TAG+="uaccess"
ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3297", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="voyager-omarchy.service"
```

- `ATTRS` walks parent devices, so this works through a hub or dock.
- `TAG+="systemd"` is **required**. udev properties are ignored on untagged devices
  (`systemd.device(5)`), and the board's hidraw nodes are tagged only `:seat:uaccess:`.
  Without it `SYSTEMD_USER_WANTS` silently does nothing.
- The board exposes several hidraw nodes, so the unit may be triggered more than once.
  Harmless: it is a oneshot and switching is idempotent.
- If Keymapp is installed, its own udev rules already grant access regardless of the `uaccess`
  line here — see [protocol.md](protocol.md) for what they do.

### systemd — the unit udev starts

`voyager-omarchy.service`, a `--user` oneshot running
`voyager-layer omarchy --wait 5`. `--wait` covers the gap between the device appearing and
being ready.

```
systemctl --user status voyager-omarchy.service
journalctl --user -u voyager-omarchy.service
```

### Hyprland — switch at login

The udev path cannot cover boot: the board is already plugged in when the user service manager
starts, so no `add` event fires. Add to `~/.config/hypr/autostart.lua`:

```lua
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/voyager-layer omarchy --wait 5")
```

`o.exec_on_start`, not `o.launch_on_start` — the latter wraps the command in `uwsm-app --`,
which is for graphical applications, not a short-lived CLI.

Validate with `hyprctl reload && hyprctl configerrors`.

### Optional: a manual toggle keybind

Not enabled by default. It earns its place mainly in the *other* direction: a dock that
switches hosts without cutting power leaves the board on the Omarchy base, so the Mac inherits
the wrong one. Tap this before handing the dock over.

```lua
o.bind("SUPER + CTRL + V", "Toggle Voyager base layer", os.getenv("HOME") .. "/.local/bin/voyager-layer toggle --notify")
```

`--notify` shows a desktop notification with the result; drop it if you'd rather rely on the
per-key amber indicator.

`SUPER + CTRL + V` is what ships because the originally planned `SUPER + CTRL + K` turned out
to be taken by "Herdr keybindings". Check your own bindings before committing to either —
`omarchy menu keybindings --print`. `install.sh --keybind` appends both lines, marked, and
refuses rather than silently stealing a key that is already bound.

## Checking it works

```
voyager-layer status                # omarchy (2)
voyager-test                        # guided round trip: omarchy -> mac -> omarchy
voyager-layer events 10             # debug dump; type during it
voyager-layer 4                     # jump to any layer by index, base or not
```

After a replug, `status` should say `omarchy (2)` within about a second with no manual step.
After a reboot and login, the same, via autostart.

A bare number switches to that layer whatever it is — handy for testing a non-base layer, and
the reason the firmware only folds the two configured base indices and leaves everything else
alone. Switching to a non-base layer does **not** make the board go quiet.

`voyager-layer events` pairs the board, which is what makes it report — so it cannot be used
to observe the board being quiet. See [protocol.md](protocol.md).

## Note on Omarchy versions

Omarchy 4.x configures Hyprland in **Lua** (`autostart.lua`, `bindings.lua`). Earlier versions
used `.conf` files with `exec-once =` and `bindd =`. The snippets here are the Lua form.
