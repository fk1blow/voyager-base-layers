#include "base_layers.h"

// Any request to turn ON a base layer (host SET_LAYER -> layer_move, TO(), TG(), ...)
// becomes a default-layer change. Base layers never stay in layer_state, so:
//  - host scripts and firmware agree on which base is active,
//  - the stock Voyager status LEDs show nothing on either base, while layers
//    that are not bases keep lighting them as usual.
// Uses default_layer_set (RAM only), never the persistent variant.
//
// When a host is paired, it also answers with the new layer and clears the
// pairing flag, so the board stops sending key/layer reports until something
// (Keymapp, voyager-layer) pairs again.
//
// Note for the host side: this is NOT the only layer event a switch produces.
// The oryx module's own layer_state_set hook runs before this one (modules ->
// _kb -> _user) and computes its value while default_layer_state still holds
// the OLD base -- QMK assigns it after the hook chain, see
// quantum/action_layer.c -- so it reports the base we are leaving. Our event
// is therefore the LAST one, not the only one, and voyager-layer scans for the
// target rather than trusting the first (see read_layer_until).
// Clearing the flag before the switch instead of after was tried: the module's
// second hook (default_layer_state_set_oryx) computes the same value as the
// first, so its own dedup already suppresses it. Identical on the wire.
layer_state_t base_layers_fold(layer_state_t state) {
    const layer_state_t mask = ((layer_state_t)1 << BASE_MAC) | ((layer_state_t)1 << BASE_OMARCHY);
    const layer_state_t requested = state & mask;
    if (!requested) {
        return state;
    }

    const uint8_t base = get_highest_layer(requested);
    state &= ~mask;

    if (get_highest_layer(default_layer_state) != base) {
        default_layer_set((layer_state_t)1 << base);
    }

#if defined(COMMUNITY_MODULE_ORYX_ENABLE) && !defined(BASE_LAYERS_KEEP_PAIRING)
    // Answer even when the base did not change: the host uses a repeated switch
    // to the active base as its "go quiet" command (voyager-layer's quiet()).
    if (rawhid_state.paired) {
        oryx_layer_event();          // reports the new default layer
        rawhid_state.paired = false; // go quiet
    }
#endif

    return state;
}

#if defined(COMBO_ENABLE) && defined(COMBO_TERM_PER_COMBO)
// A chord that switches layers is usually two-handed, and QMK's default
// COMBO_TERM of 50ms is too tight for that: miss the window and the combo is
// abandoned, so the keys arrive as ordinary keystrokes and the layer never
// changes. Raising COMBO_TERM globally is not an option -- combos on letter
// keys would start firing mid-word, e.g. B and V inside "obvious".
//
// Keyed on the combo's ACTION, never its index: Oryx renumbers combo0..comboN
// whenever one is added or removed, so an index-based rule would silently
// attach itself to the wrong chord after an unrelated edit in Oryx.
uint16_t get_combo_term(uint16_t combo_index, combo_t *combo) {
    if (IS_QK_TO(combo->keycode) || IS_QK_TOGGLE_LAYER(combo->keycode)) {
        return BASE_LAYERS_COMBO_TERM;
    }
    return COMBO_TERM;
}
#endif

#if defined(OS_DETECTION_ENABLE) && defined(BASE_LAYERS_OS_DETECTION)
bool process_detected_host_os_user(os_variant_t os) {
    default_layer_set((layer_state_t)1 << (os == OS_LINUX ? BASE_OMARCHY : BASE_MAC));
    return true;
}
#endif
