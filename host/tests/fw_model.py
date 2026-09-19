"""Python model of ZSA firmware25 + the oryx module, for testing voyager-layer
without a keyboard. Follows QMK's hook order:

  layer_state_set:         modules (oryx) -> _kb -> _user, then layer_state = result
  default_layer_state_set: modules (oryx) -> _kb/_user,   then default = result

mode:
  "stock"  - plain Oryx firmware
  "fold"   - base layers folded into the default layer (no quiet)
  "custom" - fold + on base switch: send LAYER event, clear pairing flag
"""
import collections
import os

def _load_bases():
    """Base layer indices from tools/layers.conf -- the single source of truth
    the firmware defines and the host scripts also read (PLAN.md §11.1)."""
    conf = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, os.pardir, "tools", "layers.conf")
    bases = {}
    with open(conf) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                name, _, idx = line.partition("=")
                bases[name.strip()] = int(idx.strip())
    return bases


LAYERS = _load_bases()
BASES = tuple(sorted(LAYERS.values()))


def hi(x):
    return x.bit_length() - 1 if x else 0


class FW:
    def __init__(self, mode=None, default_base=0):
        self.mode = mode or os.environ.get("FW_MODE", "stock")
        self.layer_state = 0
        self.default = 1 << default_base
        self.current_layer = 0      # oryx module's cache
        self.paired = False
        self.pairings = 0        # PAIRING_INIT count, to spot extra round trips
        self.out = collections.deque()
        self.leds = 0

    # --- oryx module ---
    def send(self, *ev):
        self.out.append(list(ev))

    def oryx_layer_event(self):
        self.send(0x05, hi(self.layer_state | self.default))

    def oryx_layer_state_set(self, state):
        if self.paired:
            layer = hi(state | self.default)
            if layer != self.current_layer:
                self.current_layer = layer
                self.send(0x05, layer)

    def rx(self, cmd, p):
        if cmd == 0x01:
            self.pairings += 1
            self.paired = True
            self.send(0x04, 0xFE)
            self.oryx_layer_event()
        elif cmd == 0x04 and self.paired and p[0]:
            self.layer_move(p[1])
        elif cmd not in (0x00, 0x02, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0xFE):
            self.send(0xFF, 0xFF)   # unknown command

    # --- QMK core ---
    def default_layer_set(self, st):
        self.oryx_layer_state_set(st | self.layer_state)
        self.default = st

    def user_hook(self, state):
        if self.mode == "stock":
            return state
        mask = sum(1 << b for b in BASES)
        req = state & mask
        if not req:
            return state
        base = hi(req)
        state &= ~mask
        if hi(self.default) != base:
            self.default_layer_set(1 << base)
        # The module's own hook already fired, before this one, while `default`
        # still held the old base -- so it reported the base we are leaving.
        # Ours is the LAST layer event of a switch, not the only one.
        if self.mode == "custom" and self.paired:
            self.oryx_layer_event()
            self.paired = False
        return state

    def layer_state_set(self, state):
        self.oryx_layer_state_set(state)
        state = self.user_hook(state)
        self.leds = hi(state) & 0xF          # stock Voyager LED code
        self.layer_state = state

    def layer_move(self, layer):
        self.layer_state_set(1 << layer)

    def layer_on(self, layer):
        self.layer_state_set(self.layer_state | (1 << layer))

    def layer_off(self, layer):
        self.layer_state_set(self.layer_state & ~(1 << layer))

    def key(self, col=3, row=2):
        """A key press + release on the physical keyboard."""
        if self.paired:
            self.send(0x06, col, row)
            self.send(0x07, col, row)

    def active(self):
        """Layer used for key lookup when nothing is held."""
        return hi(self.layer_state | self.default)


BOARD = FW()
