// Base-layer folding for the Voyager. See PLAN.md §6 and docs/firmware.md.
#pragma once
#include QMK_KEYBOARD_H

// BASE_MAC / BASE_OMARCHY come from tools/layers.conf via
// tools/apply_customizations.sh. Deliberately no fallback values here: a build
// without the generated header must fail loudly rather than silently pick 0/1.
#include "base_layers_config.h"

layer_state_t base_layers_fold(layer_state_t state);
