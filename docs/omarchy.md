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

`--dry-run` shows what it would do. `--uninstall` backs it out. Re-running is safe.

Note it replaces any dev symlink in `~/.local/bin` with a real copy, so an installed tool does
not break if the repo moves. If you later edit `host/voyager-layer`, re-run `install.sh`.

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
- If Keymapp is installed, its own `50-wally.rules` already sets `MODE:="0666"` on every ZSA
  device, so access is granted regardless of the `uaccess` line here.

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

Check the combo is free first — `omarchy menu keybindings --print`. `SUPER CTRL + K` is taken
by "Herdr keybindings" on a stock Omarchy 4.x install. `install.sh --keybind` appends both
lines, marked, and refuses if the combo is already bound.

## Checking it works

```
voyager-layer status                # omarchy (2)
voyager-test                        # guided round trip: omarchy -> mac -> omarchy
voyager-layer events 10             # debug dump; type during it
```

After a replug, `status` should say `omarchy (2)` within about a second with no manual step.
After a reboot and login, the same, via autostart.

`voyager-layer events` pairs the board, which is what makes it report — so it cannot be used
to observe the board being quiet. See [protocol.md](protocol.md).

## Note on Omarchy versions

Omarchy 4.x configures Hyprland in **Lua** (`autostart.lua`, `bindings.lua`). Earlier versions
used `.conf` files with `exec-once =` and `bindd =`. The snippets here are the Lua form.
