# voyager-base-layers

One [ZSA Voyager](https://www.zsa.io/voyager) keyboard, shared between a Mac and an
[Omarchy](https://omarchy.org/) (Arch + Hyprland) box, each of which wants different keys in
different places — but a keyboard only has one active layout at a time. This project makes
each machine select the right base layout for itself, the moment the board is plugged in,
without any background software watching for it.

Two halves, usable separately:

- **Host scripts.** `voyager-layer` talks to the keyboard over raw HID using ZSA's Oryx
  protocol. No Keymapp, no kontroll, no daemon. Works on stock Oryx firmware too.
- **Custom firmware.** The Oryx layout plus a small QMK hook, built through ZSA's
  GitHub Actions template. The layout stays 100% Oryx; the hook is applied at build time.

```
voyager-layer status      # mac (0)
voyager-layer omarchy     # switched to omarchy (2)
voyager-layer toggle      # switched to mac (0)
```

## Scripts

Everything lives in `host/`. Run `./host/install.sh` once — see
[docs/omarchy.md](docs/omarchy.md) or [docs/macos.md](docs/macos.md) for exactly what it sets
up on each OS and for its flags. Day to day, the only command you need is `voyager-layer`:

```
voyager-layer omarchy      # jump to the Omarchy base layer
voyager-layer mac          # jump to the Mac base layer
voyager-layer toggle       # flip between the two
voyager-layer status       # print the currently active layer
```

`voyager-test` is a manual harness: it drives those same switches and asks you to confirm by
hand that the keyboard is behaving like the layer it just switched to.

## Updating the layout from Oryx

The layout keeps changing — new keys, moved keys, a new layer — and Oryx is where that
happens. The whole point of this repo's build setup is that those edits never require redoing
the firmware customization by hand: the hook described below, plus a small LED fix, live
outside the generated layout and get re-applied automatically every time, onto whatever the
layout looks like now.

So the routine is just: edit the layout in Oryx, press **Compile**, then run the **Fetch and
build layout** workflow (`layout_id: 7m5PJ`, `layout_geometry: voyager`) — the ZSA browser
extension can start it from inside Oryx. It fetches your new layout, merges it in, re-applies
the customization, and builds a `.bin`.

The one way this can need attention is if Oryx changes the shape of its generated code enough
that the customization script no longer recognizes the spot it edits — it looks for exact
patterns and refuses to guess rather than apply something wrong. If a build fails, the log
names which pattern broke, and the fix is almost always a one-line change in
`tools/apply_customizations.sh`.

**The one manual step that is not optional: if you renumber a base layer in Oryx**, update
[`tools/layers.conf`](tools/layers.conf) to match, and re-run `host/install.sh` so the host
scripts pick up the new numbers before you flash. The layer numbers are the one thing
deliberately duplicated between the firmware and the host script, and this is the one place
they have to be kept in sync by hand — skip it and you get
`error: asked for mac (0), keyboard reports omarchy (2)`, the two sides disagreeing over stale
numbers rather than a real firmware bug.

The workflow commits and pushes the refreshed layout for you, before it builds. What is left
for you is the diff it prints: read it, and if the change was intentional record it with
`tools/verify_layout.sh --update` and commit that snapshot — that is what makes the *next*
run's diff meaningful. Then download the `.bin` artifact, flash it
with Keymapp, and confirm with `voyager-layer status` that you land on the base you expect and
that the LEDs stay dark on both.

The full mechanics — why generated files are never hand-edited, and exactly what
`apply_customizations.sh` changes — are in [docs/firmware.md](docs/firmware.md).

## Why the firmware needs a hook

QMK actually tracks two different things: which layer you're temporarily holding down (a
symbols layer while a thumb key is pressed, say) and which layer you're just sitting on as
your normal base. Stock Oryx firmware doesn't make that distinction when you ask it to switch
base layers — it turns the new base **on** the same way it turns on a temporary layer, instead
of updating the "this is now my base" variable.

That causes two real problems on a keyboard with two base layers instead of one:

- The keyboard decides what to actually type by combining both variables and taking the
  highest layer. So once you're sitting on the Omarchy base, asking the keyboard to switch to
  Mac can leave it still typing like it's on Omarchy — the request landed in the wrong bucket
  and lost the comparison. That's the `error: asked for mac (0), keyboard reports omarchy (2)`
  you'll see if this ever regresses.
- The keyboard's status LEDs are wired to read that same "temporary layer" variable. Since the
  Omarchy base was being switched on as if it were a temporary layer, sitting on it permanently
  lit an LED — as if you were holding down a key that was never actually released.

The fix in this repo's firmware is small: any request to turn on a base layer gets redirected
into the "this is now my base" variable instead, before it does anything else. With that in
place, the script and the keyboard always agree on which base is active, and the status LEDs
stay dark on both bases — they still light up normally for any layer that isn't a base.

One more effect worth knowing about: right after a base switch, the keyboard sends one reply
and then goes quiet — it stops reporting key and layer events until something (Keymapp,
`voyager-layer`) pairs with it again. This is just tidiness — the board no longer has a reason
to keep talking after a switch — **not** a security measure; [docs/protocol.md](docs/protocol.md)
spells out why it doesn't meaningfully hide anything. It does mean you can't watch the board
being quiet without un-quieting it: the protocol doc has the workaround if you need to verify it.

Worth relying on: the board always powers up on the Mac base, because the fix uses the
RAM-only way of setting the base layer and never writes it to EEPROM. Unplug and replug, and
it's Mac again — Omarchy's udev rule then switches it back within a second.

## Check it works

```
voyager-layer status
```

That is the one command worth remembering. It prints the active layer and, on a base layer,
quietly re-selects it — which on the custom firmware also makes the board go quiet again.

## Docs

- [docs/firmware.md](docs/firmware.md) — the build workflow, the hook, updating from Oryx
- [docs/omarchy.md](docs/omarchy.md) — udev, systemd, Hyprland autostart, the optional keybind
- [docs/macos.md](docs/macos.md) — setup, and what a host-switching dock means
- [docs/protocol.md](docs/protocol.md) — the Oryx raw HID protocol, and what the board reports
- [docs/troubleshooting.md](docs/troubleshooting.md) — when something does not work
