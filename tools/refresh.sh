#!/usr/bin/env bash
# One command from "I edited the layout in Oryx" to "here is the .bin to flash".
#
#   tools/refresh.sh [--os-detection] [--keyboard-reset] [-l ID] [-o DIR]
#                    [--no-install] [--yes] [--dry-run]
#
# Dispatches the Fetch and build layout workflow, waits for it, pulls what it
# pushed, shows the layout diff, runs the checks, re-runs host/install.sh, and
# leaves the binary in build/. Flashing stays manual: Keymapp is a GUI, and
# putting the wrong file on the board is the one step worth doing by hand.
set -euo pipefail

WORKFLOW=fetch-and-build-layout.yml
ARTIFACT_GEOMETRY=voyager
LAYOUT_ID=7m5PJ
OUT_DIR=""
OS_DETECTION=0
KEYBOARD_RESET=0
DO_INSTALL=1
ASSUME_YES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --os-detection)   OS_DETECTION=1 ;;
        # only meaningful with OS detection, so it turns that on too
        --keyboard-reset) KEYBOARD_RESET=1; OS_DETECTION=1 ;;
        --no-install)     DO_INSTALL=0 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        -l|--layout-id)   shift; LAYOUT_ID="${1:?--layout-id needs a value}" ;;
        -o|--out)         shift; OUT_DIR="${1:?--out needs a value}" ;;
        -h|--help)        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
[ -n "$OUT_DIR" ] || OUT_DIR="$REPO_ROOT/build"

step() { printf '\n== %s\n' "$*"; }
say()  { printf '   %s\n' "$*"; }
die()  { echo "refresh: ERROR: $*" >&2; exit 1; }
run()  {
    if [ "$DRY_RUN" -eq 1 ]; then say "would run: $*"; return 0; fi
    "$@"
}
confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || return 1
    local reply
    read -r -p "   $1 [y/N] " reply
    [ "$reply" = y ] || [ "$reply" = Y ]
}

# ---------------------------------------------------------------- preflight
step "Preflight"
for tool in gh git python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated -- run: gh auth login"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = main ] || die "on branch '$BRANCH'; the workflow pushes to main -- switch first"

# The workflow merges oryx into main and pushes. A dirty tree loses to the pull
# that follows, and unpushed commits make that pull a non-fast-forward.
if [ -n "$(git status --porcelain)" ]; then
    die "working tree is dirty -- commit or stash first (git status)"
fi
git fetch --quiet origin main
AHEAD="$(git rev-list --count origin/main..HEAD)"
[ "$AHEAD" -eq 0 ] || die "local main is $AHEAD commit(s) ahead of origin -- push first"
say "clean tree on main, in sync with origin"

VARIANT="stock"
[ "$OS_DETECTION" -eq 1 ] && VARIANT="os-detection"
[ "$KEYBOARD_RESET" -eq 1 ] && VARIANT="os-detection + keyboard-reset"
say "layout $LAYOUT_ID, firmware variant: $VARIANT"

# ---------------------------------------------------------------- dispatch
step "Dispatching $WORKFLOW"
DISPATCH=(gh workflow run "$WORKFLOW" -f "layout_id=$LAYOUT_ID")
[ "$OS_DETECTION" -eq 1 ]   && DISPATCH+=(-f os_detection=true)
[ "$KEYBOARD_RESET" -eq 1 ] && DISPATCH+=(-f keyboard_reset=true)

if [ "$DRY_RUN" -eq 1 ]; then
    say "would run: ${DISPATCH[*]}"
    say "would then wait for it, pull, verify, check, download and install"
    exit 0
fi

# Note the newest run id first: gh workflow run prints none, so afterwards we
# watch for a run that is not this one.
BEFORE="$(gh run list -w "$WORKFLOW" -L1 --json databaseId -q '.[0].databaseId // ""')"
"${DISPATCH[@]}"

# gh workflow run prints no run id, so watch for one that is not the old one.
RUN_ID=""
for _ in $(seq 30); do
    RUN_ID="$(gh run list -w "$WORKFLOW" -L1 --json databaseId -q '.[0].databaseId // ""')"
    [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$BEFORE" ] && break
    RUN_ID=""
    sleep 2
done
[ -n "$RUN_ID" ] || die "the run never appeared -- check: gh run list -w $WORKFLOW"
say "run $RUN_ID: $(gh run view "$RUN_ID" --json url -q .url)"

# ---------------------------------------------------------------- wait
step "Building (about two minutes)"
if ! gh run watch "$RUN_ID" --exit-status; then
    echo
    echo "refresh: the build failed. Failing step's log:" >&2
    gh run view "$RUN_ID" --log-failed || true
    die "build failed -- an anchor in tools/apply_customizations.sh usually broke; see docs/firmware.md"
fi

# ---------------------------------------------------------------- pull
step "Pulling what the workflow pushed"
git pull --ff-only --quiet origin main
say "main is now $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

# ---------------------------------------------------------------- the diff
step "Layout diff"
VERIFY_OUT="$(mktemp)"
trap 'rm -f "$VERIFY_OUT"' EXIT
if ! ./tools/verify_layout.sh | tee "$VERIFY_OUT"; then
    die "verify_layout.sh rejected the layout -- fix tools/layers.conf before flashing"
fi

if grep -q "changes since the last reviewed snapshot" "$VERIFY_OUT"; then
    echo
    say "the layout changed. Record it so the next run's diff stays meaningful."
    if grep -qE "layer [0-9]+: (new|removed)|layer count" "$VERIFY_OUT"; then
        say "NOTE: layers were added or removed. If you renumbered a base, edit"
        say "      tools/layers.conf now -- the host and the firmware must agree."
    fi
    if confirm "Record tools/layout.snapshot.json and commit it?"; then
        ./tools/verify_layout.sh --update >/dev/null
        git add tools/layout.snapshot.json
        git commit -m "Record the reviewed layout snapshot" --quiet
        say "committed -- push when you are happy with it"
    else
        say "skipped; run tools/verify_layout.sh --update yourself when ready"
    fi
fi

# ---------------------------------------------------------------- checks
step "Checks"
./tools/check.sh || die "tools/check.sh failed -- not downloading a binary you should not flash"

# ---------------------------------------------------------------- artifact
step "Downloading the firmware"
mkdir -p "$OUT_DIR"
TMP_DL="$(mktemp -d)"
trap 'rm -f "$VERIFY_OUT"; rm -rf "$TMP_DL"' EXIT
gh run download "$RUN_ID" -D "$TMP_DL"
BIN_SRC="$(find "$TMP_DL" -type f -name '*.bin' -print -quit)"
[ -n "$BIN_SRC" ] || die "no .bin in artifact ${ARTIFACT_GEOMETRY}_${LAYOUT_ID} of run $RUN_ID"
BIN="$OUT_DIR/$(basename "$BIN_SRC")"
install -m 0644 "$BIN_SRC" "$BIN"
say "$BIN ($(wc -c < "$BIN") bytes)"

# ---------------------------------------------------------------- install
if [ "$DO_INSTALL" -eq 1 ]; then
    step "Re-running host/install.sh"
    say "so ~/.config/voyager-layer/config matches tools/layers.conf (may ask for sudo)"
    ./host/install.sh
else
    step "Skipping host/install.sh (--no-install)"
    say "re-run it yourself if tools/layers.conf changed"
fi

# ---------------------------------------------------------------- done
step "Ready to flash"
cat <<EOF
   Everything up to the board is done. What is left is manual:

     1. Keymapp -> flash a local file -> $BIN
        (not the layout list -- that would put stock firmware back)
     2. voyager-layer status      # expect the base you plugged into
     3. LEDs dark on both bases, amber 1/2 key indicator following the base

   Run $RUN_ID: $(gh run view "$RUN_ID" --json url -q .url)
EOF
