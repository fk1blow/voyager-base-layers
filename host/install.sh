#!/usr/bin/env bash
# Install voyager-layer / voyager-test and their OS integration. PLAN.md §7.4.
#
#   install.sh [--autostart] [--keybind] [--uninstall] [--dry-run]
#
# Idempotent: re-running changes nothing that is already in place.
set -euo pipefail

AUTOSTART_OPT=0
KEYBIND=0
UNINSTALL=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --autostart) AUTOSTART_OPT=1 ;;
        --keybind)   KEYBIND=1; AUTOSTART_OPT=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/voyager-layer"
MARKER="voyager-base-layers (host/install.sh)"

case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=macos ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
run()  {
    if [ "$DRY_RUN" -eq 1 ]; then say "   would run: $*"; return 0; fi
    "$@"
}
# sudo in a terminal is the right place to ask for a password
sudo_run() {
    if [ "$DRY_RUN" -eq 1 ]; then say "   would run: sudo $*"; return 0; fi
    sudo "$@"
}

UDEV_RULE=/etc/udev/rules.d/70-zsa-voyager.rules
USER_UNIT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" -eq 1 ]; then
    step "Removing voyager-base-layers"
    for f in "$BIN_DIR/voyager-layer" "$BIN_DIR/voyager-test"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            run rm -f "$f"
            say "   removed $f"
        fi
    done
    if [ "$OS" = linux ]; then
        for u in voyager-omarchy.service; do
            if [ -f "$USER_UNIT_DIR/$u" ]; then
                run rm -f "$USER_UNIT_DIR/$u"
                say "   removed $USER_UNIT_DIR/$u"
            fi
        done
        run systemctl --user daemon-reload || true
        if [ -f "$UDEV_RULE" ]; then
            say "   removing $UDEV_RULE (needs sudo)"
            sudo_run rm -f "$UDEV_RULE"
            sudo_run udevadm control --reload
        fi
    fi
    say ""
    say "Left alone on purpose: $CONFIG_DIR, and any lines you added to your"
    say "Hyprland config (look for '$MARKER')."
    exit 0
fi

# ------------------------------------------------------------------ scripts
step "Installing scripts to $BIN_DIR"
run mkdir -p "$BIN_DIR"
for s in voyager-layer voyager-test; do
    [ -f "$HERE/$s" ] || { echo "missing $HERE/$s" >&2; exit 1; }
    # a dev symlink from an earlier run would otherwise be written through
    if [ -L "$BIN_DIR/$s" ]; then
        say "   replacing symlink $BIN_DIR/$s with a copy"
        run rm -f "$BIN_DIR/$s"
    fi
    run install -m 0755 "$HERE/$s" "$BIN_DIR/$s"
    say "   $BIN_DIR/$s"
done
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "   NOTE: $BIN_DIR is not on your PATH" ;;
esac

# ----------------------------------------------------------- layer indices
# PLAN.md §11.1: tools/layers.conf is the single source of truth. The config
# file uses the same `name=index` format, so it is a straight copy.
step "Layer indices"
LAYERS_CONF="$REPO_ROOT/tools/layers.conf"
if [ -f "$LAYERS_CONF" ]; then
    run mkdir -p "$CONFIG_DIR"
    if [ "$DRY_RUN" -eq 0 ] && cmp -s "$LAYERS_CONF" "$CONFIG_DIR/config"; then
        say "   $CONFIG_DIR/config already matches tools/layers.conf"
    else
        run cp "$LAYERS_CONF" "$CONFIG_DIR/config"
        say "   wrote $CONFIG_DIR/config from tools/layers.conf"
    fi
    sed -n 's/^[[:space:]]*\([a-z_]*\)[[:space:]]*=[[:space:]]*\([0-9]\+\).*/     \1 = layer \2/p' "$LAYERS_CONF"
else
    say "   tools/layers.conf not found (running outside the repo?)"
    say "   voyager-layer will fall back to its built-in defaults."
fi

if [ "$OS" = linux ]; then
    # ------------------------------------------------------------ udev rule
    step "udev rule"
    SRC_RULE="$HERE/linux/70-zsa-voyager.rules"
    if [ "$DRY_RUN" -eq 0 ] && cmp -s "$SRC_RULE" "$UDEV_RULE" 2>/dev/null; then
        say "   $UDEV_RULE already up to date"
    else
        say "   installing $UDEV_RULE (needs sudo)"
        sudo_run install -m 0644 "$SRC_RULE" "$UDEV_RULE"
        sudo_run udevadm control --reload
        say "   installed. Replug the keyboard for it to take effect."
    fi

    # ----------------------------------------------------------- user units
    step "systemd user unit"
    run mkdir -p "$USER_UNIT_DIR"
    run install -m 0644 "$HERE/linux/voyager-omarchy.service" "$USER_UNIT_DIR/voyager-omarchy.service"
    say "   $USER_UNIT_DIR/voyager-omarchy.service"
    run systemctl --user daemon-reload

    # ------------------------------------------------------------- hyprland
    step "Hyprland"
    SNIPPET="$HERE/linux/hyprland.lua"
    AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua"
    AUTOSTART_LINE="o.exec_on_start(os.getenv(\"HOME\") .. \"/.local/bin/voyager-layer omarchy --wait 5\")"
    if [ "$AUTOSTART_OPT" -eq 1 ]; then
        BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
        KEY_COMBO="SUPER + CTRL + V"
        KEY_LINE="o.bind(\"$KEY_COMBO\", \"Toggle Voyager base layer\", os.getenv(\"HOME\") .. \"/.local/bin/voyager-layer toggle --notify\")"

        # --- autostart line (always, when this branch runs) ---
        if [ ! -f "$AUTOSTART" ]; then
            say "   $AUTOSTART not found - add by hand:"
            say "     $AUTOSTART_LINE"
        elif grep -qF "voyager-layer omarchy" "$AUTOSTART"; then
            say "   autostart: already switches to the Omarchy base - left alone"
        elif [ "$DRY_RUN" -eq 1 ]; then
            say "   would append the autostart line to $AUTOSTART"
        else
            printf '\n-- %s\n%s\n' "$MARKER" "$AUTOSTART_LINE" >> "$AUTOSTART"
            say "   appended the autostart line to $AUTOSTART"
        fi

        # --- keybind (only with --keybind) ---
        if [ "$KEYBIND" -eq 1 ]; then
            # Never silently steal a bound key. PLAN.md §7.2 suggests SUPER CTRL + K,
            # which is "Herdr keybindings" on a stock Omarchy 4.x install.
            if command -v omarchy >/dev/null 2>&1 \
               && omarchy menu keybindings --print 2>/dev/null \
                  | grep -qiE "^SUPER +CTRL +\\+? *V\\b"; then
                echo "install.sh: '$KEY_COMBO' is already bound. Pick a free combo and add the" >&2
                echo "            keybind line from $SNIPPET by hand." >&2
                exit 1
            fi
            if [ ! -f "$BINDINGS" ]; then
                say "   $BINDINGS not found - add the keybind by hand"
            elif grep -qF "voyager-layer toggle" "$BINDINGS"; then
                say "   keybind: a toggle binding is already present - left alone"
            elif [ "$DRY_RUN" -eq 1 ]; then
                say "   would append '$KEY_COMBO' to $BINDINGS"
            else
                printf '\n-- %s\n%s\n' "$MARKER" "$KEY_LINE" >> "$BINDINGS"
                say "   appended '$KEY_COMBO' to $BINDINGS"
            fi
        fi
        [ "$DRY_RUN" -eq 1 ] || say "   validate with: hyprctl reload && hyprctl configerrors"
    else
        say "   Not editing your Hyprland config. Add this to $AUTOSTART:"
        say ""
        sed 's/^/     /' "$SNIPPET"
        say ""
        say "   --autostart appends the autostart line; --keybind adds a toggle key too"
    fi
else
    # --------------------------------------------------------------- macOS
    step "hidapi backend"
    run "$BIN_DIR/voyager-layer" --setup

    step "Automatic switching"
    say "   Nothing runs automatically on macOS. The board powers up on"
    say "   layer 0 (mac). NOTE: if your dock switches hosts WITHOUT cutting"
    say "   power, the board keeps whatever base it was on -- run"
    say "   'voyager-layer mac' after taking the keyboard back, or see"
    say "   docs/macos.md."
fi

step "Done"
say "Check it works:  voyager-layer status"
