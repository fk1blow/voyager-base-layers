#!/usr/bin/env bash
# Check the Oryx-generated layout against this repo's assumptions, and report
# what changed since the last reviewed snapshot. PLAN.md §11.3.
#
# Runs right after the layout is fetched, BEFORE tools/apply_customizations.sh.
#
# Hard failures (exit 1): a base index out of range, both bases equal, or fewer
# layers than tools/layers.conf needs.
# Soft report: a diff against tools/layout.snapshot.json, printed, never fatal.
#
# Note: PLAN.md §11.3 says to summarise from keymap.json, but Oryx's keymap.json
# contains only the module list -- no layers. We parse keymap.c instead.
#
# Usage: tools/verify_layout.sh [--update] [LAYOUT_DIR]
set -euo pipefail

UPDATE=0
LAYOUT_DIR=""
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)  LAYOUT_DIR="$arg" ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$LAYOUT_DIR" ]; then
    mapfile -t candidates < <(find "$REPO_ROOT" -maxdepth 2 -name keymap.c -not -path '*/qmk_firmware/*' -printf '%h\n' | sort -u)
    [ "${#candidates[@]}" -eq 1 ] || { echo "verify_layout: ERROR: expected one layout dir, found ${#candidates[@]}" >&2; exit 1; }
    LAYOUT_DIR="${candidates[0]}"
fi

UPDATE="$UPDATE" python3 - "$LAYOUT_DIR" "$REPO_ROOT/tools/layers.conf" "$REPO_ROOT/tools/layout.snapshot.json" <<'PY'
import hashlib, json, os, re, sys

layout_dir, layers_conf, snapshot_path = sys.argv[1], sys.argv[2], sys.argv[3]
update = os.environ.get("UPDATE") == "1"
errors = []

def fail(msg):
    errors.append(msg)

# --- parse tools/layers.conf ------------------------------------------------
bases = {}
with open(layers_conf) as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            name, _, idx = line.partition("=")
            bases[name.strip()] = int(idx.strip())

# --- parse the generated keymap.c -------------------------------------------
src = open(os.path.join(layout_dir, "keymap.c")).read()

def split_top_level(text):
    """Split on commas that are not inside parentheses."""
    out, depth, cur = [], 0, []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        out.append("".join(cur).strip())
    return out

layers = {}
for m in re.finditer(r"\[(\d+)\]\s*=\s*LAYOUT\w*\(", src):
    idx = int(m.group(1))
    depth, i = 1, m.end()
    while depth and i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
        i += 1
    keys = [k for k in split_top_level(src[m.end():i - 1]) if k]
    layers[idx] = {
        "keys": len(keys),
        "non_transparent": sum(1 for k in keys if k != "KC_TRANSPARENT"),
        "thumbs": keys[-4:],
        # identity, not just shape: this is what catches a layer that moved to a
        # different index in Oryx while layers.conf kept pointing at the old one.
        "hash": hashlib.sha1("\n".join(keys).encode()).hexdigest()[:12],
    }

if not layers:
    fail("no LAYOUT_*() blocks found in keymap.c -- Oryx output changed")

# --- combos: two chords with the same keys (hard) ---------------------------
# QMK matches a combo as an unordered SET of keys, so {3,4,1,2} and {1,2,3,4}
# are the same chord. Oryx lists them in order and will happily let you define
# both -- and has duplicated one on its own. Both then fire, the last one in
# key_combos[] wins, and the other looks simply dead.
combo_keys, combo_actions = {}, {}
for m in re.finditer(r"const\s+uint16_t\s+PROGMEM\s+(\w+)\[\]\s*=\s*\{(.*?)\}", src, re.S):
    if "COMBO_END" not in m.group(2):
        continue
    combo_keys[m.group(1)] = [k for k in split_top_level(m.group(2)) if k and k != "COMBO_END"]
for m in re.finditer(r"COMBO\(", src):
    depth, i = 1, m.end()
    while depth and i < len(src):
        depth += (src[i] == "(") - (src[i] == ")")
        i += 1
    parts = split_top_level(src[m.end():i - 1])
    if len(parts) == 2:
        combo_actions[parts[0]] = parts[1]

by_keys = {}
for name, keys in combo_keys.items():
    by_keys.setdefault(frozenset(keys), []).append(name)
for keys, names in sorted(by_keys.items(), key=lambda kv: sorted(kv[1])):
    if len(names) > 1:
        which = ", ".join(f"{n} -> {combo_actions.get(n, '?')}" for n in sorted(names))
        fail(f"these combos use the same keys ({' + '.join(sorted(keys))}): {which}. "
             f"QMK matches combos as unordered sets, so they conflict and the last "
             f"one listed wins -- give them different keys in Oryx.")

revision = ""
try:
    cfg = open(os.path.join(layout_dir, "config.h")).read()
    mm = re.search(r'#define\s+SERIAL_NUMBER\s+"([^"]+)"', cfg)
    revision = mm.group(1) if mm else ""
except OSError:
    pass

summary = {
    "layout_dir": os.path.basename(layout_dir.rstrip("/")),
    "revision": revision,
    "layer_count": len(layers),
    "layers": [dict(index=i, **layers[i]) for i in sorted(layers)],
    "bases": {name: {"index": idx, "hash": layers[idx]["hash"]}
              for name, idx in sorted(bases.items()) if idx in layers},
}

# --- hard checks ------------------------------------------------------------
seen = {}
for name, idx in sorted(bases.items()):
    if idx in seen:
        fail(f"'{name}' and '{seen[idx]}' are both layer {idx} in layers.conf")
    seen[idx] = name
    if idx not in layers:
        fail(f"layers.conf wants '{name}' at layer {idx}, but the layout has "
             f"{len(layers)} layers (0-{max(layers) if layers else -1})")

print(f"verify_layout: {summary['layout_dir']} revision {summary['revision'] or '?'}, "
      f"{summary['layer_count']} layers, {len(combo_keys)} combos")
for name, idx in sorted(bases.items(), key=lambda kv: kv[1]):
    info = layers.get(idx)
    if info:
        print(f"  base {name:<8} = layer {idx}  "
              f"({info['non_transparent']}/{info['keys']} non-transparent keys)")

# --- soft diff against the snapshot ----------------------------------------
old = None
if os.path.exists(snapshot_path):
    try:
        old = json.load(open(snapshot_path))
    except (OSError, ValueError) as e:
        print(f"  (snapshot unreadable: {e})")

if old is None:
    print("  no snapshot yet -- run tools/verify_layout.sh --update to record one")
else:
    changes = []
    if old.get("revision") != summary["revision"]:
        changes.append(f"revision {old.get('revision')} -> {summary['revision']}")
    if old.get("layer_count") != summary["layer_count"]:
        changes.append(f"layer count {old.get('layer_count')} -> {summary['layer_count']}")
    oldl = {l["index"]: l for l in old.get("layers", [])}
    for cur in summary["layers"]:
        prev = oldl.get(cur["index"])
        i = cur["index"]
        if prev is None:
            changes.append(f"layer {i}: new ({cur['non_transparent']} non-transparent keys)")
            continue
        if prev["non_transparent"] != cur["non_transparent"]:
            changes.append(f"layer {i}: {prev['non_transparent']} -> "
                           f"{cur['non_transparent']} non-transparent keys")
        if prev.get("thumbs") != cur["thumbs"]:
            changes.append(f"layer {i}: thumbs {prev.get('thumbs')} -> {cur['thumbs']}")
    for i in sorted(set(oldl) - {l["index"] for l in summary["layers"]}):
        changes.append(f"layer {i}: removed")
    # --- did a base layer move? (hard) ---------------------------------
    old_bases = old.get("bases") or {}
    if not old_bases:
        print("  (snapshot predates base fingerprints -- run --update to record them)")
    else:
        by_hash = {}
        for l in summary["layers"]:
            by_hash.setdefault(l["hash"], []).append(l["index"])
        for name, idx in sorted(bases.items(), key=lambda kv: kv[1]):
            prev = old_bases.get(name)
            if not prev or idx not in layers:
                continue
            if prev["hash"] == layers[idx]["hash"]:
                continue
            found = by_hash.get(prev["hash"], [])
            if len(found) == 1:
                fail(f"base '{name}' is layer {idx} in layers.conf, but that layer's "
                     f"keys are now at layer {found[0]} -- Oryx reordered the layers. "
                     f"Set {name}={found[0]} in tools/layers.conf and re-run "
                     f"host/install.sh before flashing.")
            elif len(found) > 1:
                fail(f"base '{name}' (layer {idx}) changed, and its old keys now match "
                     f"layers {found} -- check the order in Oryx by hand.")
            else:
                changes.append(f"base '{name}' (layer {idx}): keys changed")

    if changes:
        print("  changes since the last reviewed snapshot:")
        for c in changes:
            print(f"    - {c}")
    else:
        print("  no change since the last reviewed snapshot")

if errors:
    for e in errors:
        print(f"verify_layout: ERROR: {e}", file=sys.stderr)
    sys.exit(1)

if update:
    with open(snapshot_path, "w") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    print(f"verify_layout: snapshot written to {os.path.relpath(snapshot_path)}")
PY
