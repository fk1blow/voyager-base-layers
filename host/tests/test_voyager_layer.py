"""Tests for voyager-layer against the firmware model. Run: python3 -m unittest -v"""
import atexit
import contextlib
import io
import os
import shutil
import tempfile
import runpy
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("VOYAGER_LAYER", os.path.join(HERE, "..", "voyager-layer"))
sys.path.insert(0, HERE)
os.environ["VOYAGER_BACKEND"] = "hidapi"
os.environ.pop("VOYAGER_LAYERS", None)
# keep the developer's real ~/.config/voyager-layer/config out of the tests
CONFIG_HOME = tempfile.mkdtemp(prefix="voyager-test-xdg-")
os.environ["XDG_CONFIG_HOME"] = CONFIG_HOME
atexit.register(shutil.rmtree, CONFIG_HOME, True)

import fw_model  # noqa: E402


def run(*args):
    sys.argv = ["voyager-layer", *map(str, args)]
    out = io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            runpy.run_path(SCRIPT, run_name="__main__")
        except SystemExit as e:
            if isinstance(e.code, str):
                print(e.code)
                code = 1
            else:
                code = e.code or 0
    return code, out.getvalue().strip()


class Base(unittest.TestCase):
    mode = "stock"

    def setUp(self):
        fw_model.BOARD = self.board = fw_model.FW(self.mode)

    def assertOn(self, layer):
        self.assertEqual(self.board.active(), layer)


class Stock(Base):
    mode = "stock"

    def test_status(self):
        self.assertEqual(run("status"), (0, "mac (0)"))

    def test_switch_and_toggle(self):
        self.assertEqual(run("omarchy"), (0, "switched to omarchy (2)"))
        self.assertOn(2)
        self.assertEqual(self.board.leds, 0b0010)       # stock shows the layer number
        self.assertEqual(run("toggle"), (0, "switched to mac (0)"))
        self.assertOn(0)
        self.assertEqual(run("toggle")[0], 0)
        self.assertOn(2)
        self.assertEqual(run("status"), (0, "omarchy (2)"))

    def test_already_on(self):
        run("omarchy")
        self.assertEqual(run("omarchy"), (0, "already on omarchy (2)"))

    def test_flag_stays_on(self):
        run("omarchy")
        self.assertTrue(self.board.paired)

    def test_default_layer_conflict_is_reported(self):
        # stock-style firmware with a default layer of 2 (e.g. OS detection, no fold)
        self.board.default_layer_set(1 << 2)
        code, out = run("mac")
        self.assertEqual(code, 1)
        self.assertIn("asked for mac (0), keyboard reports omarchy (2)", out)

    def test_stray_key_events_ignored(self):
        self.board.paired = True
        self.board.key()
        self.assertEqual(run("omarchy"), (0, "switched to omarchy (2)"))

    def test_numeric_layer(self):
        self.assertEqual(run(3), (0, "switched to layer (3)"))
        self.assertOn(3)


class Custom(Base):
    mode = "custom"

    def test_switch_is_quiet_and_dark(self):
        self.assertEqual(run("omarchy"), (0, "switched to omarchy (2)"))
        self.assertOn(2)
        self.assertEqual(self.board.leds, 0)
        self.assertFalse(self.board.paired)
        self.board.out.clear()
        self.board.key()
        self.board.layer_on(3)
        self.board.layer_off(3)
        self.assertEqual(list(self.board.out), [])      # nothing sent after the switch

    def test_toggle_both_ways(self):
        for expected in (2, 0, 2, 0):
            code, _ = run("toggle")
            self.assertEqual(code, 0)
            self.assertOn(expected)
            self.assertEqual(self.board.leds, 0)
            self.assertFalse(self.board.paired)

    def test_already_on_is_quiet(self):
        run("omarchy")
        self.assertEqual(run("omarchy"), (0, "already on omarchy (2)"))
        self.assertFalse(self.board.paired)

    def test_status_is_quiet_and_changes_nothing(self):
        run("omarchy")
        self.assertEqual(run("status"), (0, "omarchy (2)"))
        self.assertOn(2)
        self.assertFalse(self.board.paired)

    def test_status_leaves_toggled_layer_alone(self):
        self.board.layer_on(3)                     # e.g. TG(3) on the keyboard
        self.assertEqual(run("status"), (0, "layer (3)"))
        self.assertOn(3)                           # not switched off
        self.assertTrue(self.board.paired)         # so the flag stays on

    def test_switch_from_toggled_layer(self):
        self.board.layer_on(3)
        self.assertEqual(run("omarchy"), (0, "switched to omarchy (2)"))
        self.assertOn(2)
        self.assertFalse(self.board.paired)

    def test_other_layers_still_light_leds(self):
        run("omarchy")
        self.board.layer_on(3)
        self.assertEqual(self.board.leds, 0b0011)
        self.board.layer_off(3)
        self.assertEqual(self.board.leds, 0)

    def test_keymapp_session(self):
        run("omarchy")
        # Keymapp opens: pairs, events flow
        self.board.rx(0x01, [0] * 31)
        self.board.out.clear()
        self.board.key()
        self.assertTrue(self.board.out)
        # Keymapp closes: flag stays on (by design)
        self.assertTrue(self.board.paired)
        # next base switch (script or TO key) goes quiet again
        self.board.layer_move(0)
        self.assertFalse(self.board.paired)
        self.assertOn(0)

    def test_os_detection_default(self):
        fw_model.BOARD = self.board = fw_model.FW("custom", default_base=2)
        self.assertEqual(run("status"), (0, "omarchy (2)"))
        self.assertEqual(run("mac"), (0, "switched to mac (0)"))
        self.assertOn(0)

    def test_events_dump(self):
        # while listening: a key press and a layer change happen on the keyboard
        self.board.later = [lambda b: b.key(5, 1), lambda b: b.layer_on(3),
                            lambda b: b.layer_off(3)]
        code, out = run("events", 0.2)
        self.assertEqual(code, 0)
        self.assertIn("KEYDOWN  col 5 row 1", out)
        self.assertIn("LAYER    layer 3", out)
        self.assertFalse(self.board.paired)                    # quiet afterwards


class Fold(Base):
    """Fold hook without the quiet lines: still works, flag stays on."""
    mode = "fold"

    def test_switch(self):
        for target, name in ((2, "omarchy"), (0, "mac"), (2, "omarchy")):
            code, out = run(name)
            self.assertEqual(code, 0, out)
            self.assertOn(target)
            self.assertEqual(self.board.leds, 0)


class Errors(unittest.TestCase):
    def test_not_found(self):
        import hid
        orig = hid.enumerate
        hid.enumerate = lambda v, p: []
        try:
            code, out = run("status")
        finally:
            hid.enumerate = orig
        self.assertEqual(code, 1)
        self.assertIn("keyboard not found", out)

    def test_bad_target(self):
        code, out = run("nope")
        self.assertNotEqual(code, 0)


class LayerConfig(unittest.TestCase):
    """tools/layers.conf is the single source of truth (PLAN.md §11.1)."""

    def test_defaults_match_layers_conf(self):
        # drift here means the firmware and the host scripts disagree
        import runpy as _runpy
        mod = _runpy.run_path(SCRIPT, run_name="not_main")
        self.assertEqual(mod["DEFAULT_LAYERS"], fw_model.LAYERS)

    def test_config_file_overrides_defaults(self):
        path = os.path.join(CONFIG_HOME, "voyager-layer", "config")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("# comment\nmac = 0\nomarchy = 5\n\n")
        try:
            fw_model.BOARD = fw_model.FW("stock")
            self.assertEqual(run("omarchy"), (0, "switched to omarchy (5)"))
        finally:
            os.remove(path)

    def test_env_beats_config_file(self):
        path = os.path.join(CONFIG_HOME, "voyager-layer", "config")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("mac=0\nomarchy=5\n")
        os.environ["VOYAGER_LAYERS"] = "mac=0,omarchy=4"
        try:
            fw_model.BOARD = fw_model.FW("stock")
            self.assertEqual(run("omarchy"), (0, "switched to omarchy (4)"))
        finally:
            os.remove(path)
            os.environ.pop("VOYAGER_LAYERS", None)


class EventOrdering(Base):
    """The oryx module emits a stale LAYER event before our fold hook runs."""
    mode = "custom"

    def test_last_event_names_the_new_base(self):
        self.board.default = 1 << fw_model.LAYERS["omarchy"]
        self.board.rx(0x01, [0] * 31)          # host pairs
        self.board.out.clear()
        self.board.rx(0x04, [1, fw_model.LAYERS["mac"]])   # SET_LAYER mac
        layers = [e[1] for e in self.board.out if e[0] == 0x05]
        self.assertEqual(layers[-1], fw_model.LAYERS["mac"],
                         f"last LAYER event must name the new base, got {layers}")
        self.assertFalse(self.board.paired)

    def test_stale_event_costs_no_extra_pairing(self):
        # The base moved while nothing was paired -- a TO() key, or firmware OS
        # detection -- so the module's current_layer cache still says 0 and its
        # dedup will not swallow the stale event. switch() must scan past it
        # instead of falling into the re-pair path, which costs a PAIRING_INIT.
        self.board.layer_move(fw_model.LAYERS["omarchy"])
        self.assertEqual(self.board.current_layer, 0)
        self.assertEqual(self.board.pairings, 0)
        self.assertEqual(run("mac"), (0, "switched to mac (0)"))
        self.assertEqual(self.board.pairings, 1, "switch() re-paired instead of scanning")


if __name__ == "__main__":
    unittest.main()
