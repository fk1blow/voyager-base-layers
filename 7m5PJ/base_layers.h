// Base-layer folding for the Voyager. See PLAN.md §6 and docs/firmware.md.
#pragma once
#include QMK_KEYBOARD_H

// BASE_MAC / BASE_OMARCHY come from tools/layers.conf via
// tools/apply_customizations.sh. Deliberately no fallback values here: a build
// without the generated header must fail loudly rather than silently pick 0/1.
#include "base_layers_config.h"

// rawhid_state and oryx_layer_event() live here. QMK_KEYBOARD_H does not pull
// the module header in for a plain SRC file, so ask for it the same way ZSA's
// own keyboards/zsa/voyager/voyager.c does.
#ifdef COMMUNITY_MODULE_ORYX_ENABLE
#    include "oryx.h"
#endif

layer_state_t base_layers_fold(layer_state_t state);
