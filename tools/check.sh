#!/usr/bin/env bash
# Everything that can be checked without a keyboard. PLAN.md §11.5.
# Used locally and by .github/workflows/host-tests.yml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FAILED=0

step() { printf '\n=== %s ===\n' "$1"; }
fail() { echo "check: FAILED: $1" >&2; FAILED=1; }

step "host tests (firmware model)"
(cd host/tests && python3 -m unittest) || fail "host tests"

step "python syntax"
python3 -m py_compile host/voyager-layer || fail "py_compile host/voyager-layer"
echo "host/voyager-layer compiles"

step "shell syntax"
before=$FAILED
mapfile -t SHELL_FILES < <(printf '%s\n' host/voyager-test host/install.sh tools/*.sh | sort -u)
for f in "${SHELL_FILES[@]}"; do
    [ -f "$f" ] || { echo "skip $f (not present yet)"; continue; }
    bash -n "$f" || fail "bash -n $f"
done
[ "$FAILED" -eq "$before" ] && echo "bash -n ok"

step "shellcheck"
before=$FAILED
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SHELL_FILES[@]}"; do
        [ -f "$f" ] || continue
        shellcheck "$f" || fail "shellcheck $f"
    done
    [ "$FAILED" -eq "$before" ] && echo "shellcheck ok"
else
    echo "shellcheck not installed - skipping (CI runs it)"
fi

step "layout assumptions"
./tools/verify_layout.sh || fail "verify_layout.sh"

step "customizations (dry run)"
./tools/apply_customizations.sh --dry-run || fail "apply_customizations.sh --dry-run"

printf '\n'
if [ "$FAILED" -ne 0 ]; then
    echo "check: one or more steps FAILED"
    exit 1
fi
echo "check: all good"
