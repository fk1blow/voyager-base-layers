-- Omarchy / Hyprland snippet for voyager-base-layers.
--
-- PLAN.md §7.2 describes this as hyprland.conf with `exec-once =` and `bindd =`.
-- That is the pre-4.x Omarchy format. Omarchy 4.x configures Hyprland in Lua,
-- so the equivalent lines are below.
--
-- Add to ~/.config/hypr/autostart.lua (host/install.sh prints this; it only
-- edits the file if you pass --keybind, and marks what it added).

-- Switch to the Omarchy base layer at login.
-- Covers the case the udev rule cannot: at boot the board is already plugged in
-- and the user service manager does not exist yet when the device appears.
--
-- o.exec_on_start, not o.launch_on_start: the latter wraps the command in
-- `uwsm-app --`, which is for graphical applications, not a short-lived CLI.
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/voyager-layer omarchy --wait 5")

-- Optional manual toggle, in ~/.config/hypr/bindings.lua. Not enabled by
-- default (PLAN.md §2). Useful mainly in the other direction: a dock that
-- switches hosts without cutting power leaves the board on the Omarchy base,
-- so the Mac inherits the wrong one -- tap this before handing the dock over.
--
-- Pick a combo that is actually free: check with
--   omarchy menu keybindings --print
-- SUPER CTRL + K, which PLAN.md §7.2 suggests, is taken by "Herdr keybindings".
--
-- o.bind("SUPER + CTRL + V", "Toggle Voyager base layer", os.getenv("HOME") .. "/.local/bin/voyager-layer toggle --notify")
