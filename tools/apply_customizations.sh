#!/usr/bin/env bash
# Apply this repo's customizations to the Oryx-generated layout, in place.
#
# PLAN.md §11 rule 1: generated files are never edited in git. They hold exactly
# what Oryx produced, so the template's `git merge -Xignore-all-space oryx` can
# never conflict. This script reapplies every edit at build time instead.
#
# Idempotent (marker comments guard each edit) and anchored: if Oryx changes its
# output so an anchor no longer matches, exit non-zero with a clear message
# rather than guess. A failed build is wanted; a silently skipped edit is not.
#
# Usage: tools/apply_customizations.sh [--dry-run] [LAYOUT_DIR]
set -euo pipefail

MARKER="base-layers: applied by tools/apply_customizations.sh"
DRY_RUN=0
LAYOUT_DIR=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)  LAYOUT_DIR="$arg" ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYERS_CONF="$REPO_ROOT/tools/layers.conf"

die() { echo "apply_customizations: ERROR: $*" >&2; exit 1; }
note() { echo "apply_customizations: $*"; }

# --- locate the layout directory -------------------------------------------
if [ -z "$LAYOUT_DIR" ]; then
    # the one directory holding a keymap.c that Oryx generated
    mapfile -t candidates < <(find "$REPO_ROOT" -maxdepth 2 -name keymap.c -not -path '*/qmk_firmware/*' -printf '%h\n' | sort -u)
    [ "${#candidates[@]}" -eq 1 ] || die "expected exactly one layout dir with keymap.c, found ${#candidates[@]}: ${candidates[*]:-none}"
    LAYOUT_DIR="${candidates[0]}"
fi
[ -d "$LAYOUT_DIR" ] || die "layout dir not found: $LAYOUT_DIR"
note "layout dir: ${LAYOUT_DIR#"$REPO_ROOT"/}"

KEYMAP="$LAYOUT_DIR/keymap.c"
RULES="$LAYOUT_DIR/rules.mk"
CONFIG="$LAYOUT_DIR/config.h"
GENERATED="$LAYOUT_DIR/base_layers_config.h"
for f in "$KEYMAP" "$RULES" "$CONFIG"; do
    [ -f "$f" ] || die "missing generated file: $f"
done
[ -f "$LAYOUT_DIR/base_layers.c" ] || die "missing $LAYOUT_DIR/base_layers.c (should be committed)"

CHANGES=0
changed() { CHANGES=$((CHANGES + 1)); note "  + $*"; }
skipped() { note "  = $* (already applied)"; }

# write $2 to file $1 unless --dry-run
write() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    printf '%s' "$2" > "$1"
}
append() {
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    printf '%s' "$2" >> "$1"
}

# --- 1. base_layers_config.h from tools/layers.conf -------------------------
[ -f "$LAYERS_CONF" ] || die "missing $LAYERS_CONF"
get_layer() {
    local name="$1" value
    value="$(sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p" "$LAYERS_CONF" | head -1)"
    [ -n "$value" ] || die "no '$name=' entry in tools/layers.conf"
    printf '%s' "$value"
}
MAC="$(get_layer mac)"
OMARCHY="$(get_layer omarchy)"
[ "$MAC" != "$OMARCHY" ] || die "mac and omarchy are both layer $MAC in tools/layers.conf"

generated_content="$(cat <<EOF
// Generated from tools/layers.conf by tools/apply_customizations.sh. Do not edit,
// do not commit. Change tools/layers.conf instead.
#pragma once
#define BASE_MAC $MAC
#define BASE_OMARCHY $OMARCHY
EOF
)"
generated_content="$generated_content"$'\n'
# byte comparison: command substitution would strip the trailing newline
if [ -f "$GENERATED" ] && cmp -s "$GENERATED" <(printf '%s' "$generated_content"); then
    skipped "base_layers_config.h (mac=$MAC omarchy=$OMARCHY)"
else
    write "$GENERATED" "$generated_content"
    changed "base_layers_config.h (mac=$MAC omarchy=$OMARCHY)"
fi

# --- 2. rules.mk: build base_layers.c ---------------------------------------
if grep -qF "$MARKER" "$RULES"; then
    skipped "rules.mk"
else
    grep -q '^ORYX_ENABLE[[:space:]]*=[[:space:]]*yes' "$RULES" \
        || die "anchor missing in rules.mk: expected 'ORYX_ENABLE = yes'. Oryx output changed."
    append "$RULES" "$(cat <<EOF

# --- $MARKER ---
SRC += base_layers.c
# OS_DETECTION_ENABLE = yes   # needed by BASE_LAYERS_OS_DETECTION (see config.h)
EOF
)"$'\n'
    changed "rules.mk: SRC += base_layers.c"
fi

# --- 3. config.h: commented options block -----------------------------------
if grep -qF "$MARKER" "$CONFIG"; then
    skipped "config.h"
else
    append "$CONFIG" "$(cat <<EOF

// --- $MARKER ---
// #define BASE_LAYERS_OS_DETECTION      // pick base layer from detected host OS (needs OS_DETECTION_ENABLE)
// #define OS_DETECTION_KEYBOARD_RESET   // re-detect when a KVM/switch changes hosts without power loss
// #define BASE_LAYERS_KEEP_PAIRING      // don't clear the pairing flag on base switches
EOF
)"$'\n'
    changed "config.h: options block"
fi

# --- 4. keymap.c: the fold hook ---------------------------------------------
if grep -qF "$MARKER" "$KEYMAP"; then
    skipped "keymap.c: fold hook"
elif grep -qE '^[[:alnum:]_ ]*layer_state_set_user[[:space:]]*\(' "$KEYMAP"; then
    # Oryx started generating its own hook: insert our call as the first statement.
    die "keymap.c now defines layer_state_set_user itself. Add 'state = base_layers_fold(state);' as its first line here (PLAN.md §6.3) and update this script's anchor."
else
    append "$KEYMAP" "$(cat <<EOF

// --- $MARKER ---
#include "base_layers.h"
layer_state_t layer_state_set_user(layer_state_t state) {
    return base_layers_fold(state);
}
EOF
)"$'\n'
    changed "keymap.c: layer_state_set_user -> base_layers_fold"
fi

# --- 5. keymap.c: per-key RGB must follow the default layer -----------------
# Oryx picks the ledmap row with biton32(layer_state), which cannot see the
# default layer. After the fold both bases would light ledmap[BASE_MAC]. The
# per-key indicator is the only visual cue left for which base is active,
# because the status LEDs are dark on both.
RGB_OLD='switch (biton32(layer_state)) {'
RGB_NEW='switch (get_highest_layer(layer_state | default_layer_state)) {  // '"$MARKER"
if grep -qF "$RGB_NEW" "$KEYMAP"; then
    skipped "keymap.c: RGB row"
elif [ "$(grep -cF "$RGB_OLD" "$KEYMAP")" = "1" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        python3 - "$KEYMAP" "$RGB_OLD" "$RGB_NEW" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    text = f.read()
assert text.count(old) == 1
with open(path, "w") as f:
    f.write(text.replace(old, new))
PY
    fi
    changed "keymap.c: RGB row follows default_layer_state"
else
    die "anchor missing in keymap.c: expected exactly one '$RGB_OLD'. Oryx output changed; check rgb_matrix_indicators_user (PLAN.md §6.3)."
fi

# --- summary ----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    note "dry run: $CHANGES edit(s) would be applied"
else
    note "$CHANGES edit(s) applied"
fi
