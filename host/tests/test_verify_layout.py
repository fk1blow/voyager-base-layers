"""tools/verify_layout.sh, driven against synthetic Oryx output.

The case that matters: Oryx reorders the layers, the base that layers.conf
points at still *exists*, so the range check passes -- and you flash firmware
whose Omarchy base is actually a symbol layer. Fingerprints catch that.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir)
SCRIPT = os.path.join(REPO, "tools", "verify_layout.sh")

MAC = "KC_A, KC_B, KC_C, KC_D"
SYM = "KC_1, KC_2, KC_3, KC_4"
OMARCHY = "KC_Q, KC_W, KC_E, KC_R"
NAV = "KC_F1, KC_F2, KC_F3, KC_F4"


class VerifyLayout(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="verify-layout-")
        self.addCleanup(shutil.rmtree, self.root, True)
        os.makedirs(os.path.join(self.root, "tools"))
        os.makedirs(os.path.join(self.root, "fake"))
        shutil.copy(SCRIPT, os.path.join(self.root, "tools", "verify_layout.sh"))
        self.write_conf(mac=0, omarchy=2)
        with open(os.path.join(self.root, "fake", "config.h"), "w") as f:
            f.write('#define SERIAL_NUMBER "test/rev1"\n')
        open(os.path.join(self.root, "fake", "base_layers.c"), "w").close()

    def write_conf(self, **bases):
        with open(os.path.join(self.root, "tools", "layers.conf"), "w") as f:
            for name, idx in bases.items():
                f.write(f"{name}={idx}\n")

    def write_layers(self, *payloads, combos=None):
        body = "".join(f"  [{i}] = LAYOUT_voyager({p}),\n"
                       for i, p in enumerate(payloads))
        out = "const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {\n" + body + "};\n"
        if combos:
            for i, (keys, _) in enumerate(combos):
                out += f"const uint16_t PROGMEM combo{i}[] = {{ {keys}, COMBO_END}};\n"
            out += "combo_t key_combos[COMBO_COUNT] = {\n"
            out += "".join(f"    COMBO(combo{i}, {act}),\n"
                           for i, (_, act) in enumerate(combos))
            out += "};\n"
        with open(os.path.join(self.root, "fake", "keymap.c"), "w") as f:
            f.write(out)

    def verify(self, update=False):
        cmd = [os.path.join(self.root, "tools", "verify_layout.sh")]
        if update:
            cmd.append("--update")
        cmd.append(os.path.join(self.root, "fake"))
        return subprocess.run(cmd, capture_output=True, text=True)

    def record(self, *payloads):
        self.write_layers(*payloads)
        r = self.verify(update=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    # ------------------------------------------------------------------
    def test_snapshot_records_base_fingerprints(self):
        self.record(MAC, SYM, OMARCHY, NAV)
        with open(os.path.join(self.root, "tools", "layout.snapshot.json")) as f:
            snap = json.load(f)
        self.assertEqual(set(snap["bases"]), {"mac", "omarchy"})
        self.assertEqual(snap["bases"]["omarchy"]["index"], 2)
        self.assertTrue(snap["bases"]["omarchy"]["hash"])

    def test_reordered_base_is_a_hard_failure(self):
        self.record(MAC, SYM, OMARCHY, NAV)
        self.write_layers(MAC, SYM, NAV, OMARCHY)   # omarchy moved 2 -> 3
        r = self.verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn("now at layer 3", r.stderr)
        self.assertIn("omarchy=3", r.stderr)

    def test_reorder_accepted_once_layers_conf_agrees(self):
        self.record(MAC, SYM, OMARCHY, NAV)
        self.write_layers(MAC, SYM, NAV, OMARCHY)
        self.write_conf(mac=0, omarchy=3)
        self.assertEqual(self.verify().returncode, 0)

    def test_editing_a_base_is_not_a_move(self):
        self.record(MAC, SYM, OMARCHY, NAV)
        self.write_layers(MAC, SYM, OMARCHY + ", KC_T", NAV)
        r = self.verify()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("keys changed", r.stdout)

    # --- combos --------------------------------------------------------
    def test_same_keys_in_a_different_order_is_a_hard_failure(self):
        """The bug Oryx shipped: {3,4,1,2} and {1,2,3,4} are one chord."""
        self.write_layers(MAC, SYM, OMARCHY, NAV, combos=[
            ("KC_3, KC_4, KC_1, KC_2", "TO(3)"),
            ("KC_1, KC_2, KC_3, KC_4", "TO(2)"),
        ])
        r = self.verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn("same keys", r.stderr)
        self.assertIn("combo0 -> TO(3)", r.stderr)
        self.assertIn("combo1 -> TO(2)", r.stderr)

    def test_duplicated_combo_is_a_hard_failure(self):
        """And the one it shipped next: the same chord listed twice."""
        self.write_layers(MAC, SYM, OMARCHY, NAV, combos=[
            ("KC_BSPC, KC_1", "TO(2)"),
            ("KC_BSPC, KC_1", "TO(0)"),
        ])
        r = self.verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn("KC_1 + KC_BSPC", r.stderr)

    def test_distinct_combos_are_fine(self):
        self.write_layers(MAC, SYM, OMARCHY, NAV, combos=[
            ("KC_SLASH, KC_ENTER", "TO(3)"),
            ("KC_BSPC, KC_0", "TO(2)"),
        ])
        r = self.verify()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 combos", r.stdout)

    def test_keycodes_with_parentheses_parse(self):
        """MEH_T(KC_SPACE) holds a comma-free paren group; do not split on it."""
        self.write_layers(MAC, SYM, OMARCHY, NAV, combos=[
            ("MEH_T(KC_SPACE), MT(MOD_LCTL, KC_ESCAPE)", "TG(5)"),
            ("KC_B, KC_V", "KC_SPACE"),
        ])
        r = self.verify()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 combos", r.stdout)

    def test_a_layout_with_no_combos_is_fine(self):
        self.write_layers(MAC, SYM, OMARCHY, NAV)
        r = self.verify()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("0 combos", r.stdout)

    def test_base_index_past_the_end_still_fails(self):
        self.write_conf(mac=0, omarchy=9)
        self.write_layers(MAC, SYM, OMARCHY)
        r = self.verify()
        self.assertEqual(r.returncode, 1)
        self.assertIn("layers.conf wants 'omarchy' at layer 9", r.stderr)


if __name__ == "__main__":
    unittest.main()
