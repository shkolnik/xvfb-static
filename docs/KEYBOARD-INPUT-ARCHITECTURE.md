# Keyboard input architecture

This document is for people building automation *on top of* xvfb-static — test
harnesses, screenshot pipelines, scrapers, RPA tools — who need to type text
into applications running on a headless X server.

It is not a description of how the embedded catalog is compiled. That is in
[AGENTS.md](../AGENTS.md) sections 3 and 5.

## The problem this is solving

You have a string. You want the application under test to receive it.

On a real desktop, a physical keypress travels a long path: the kernel emits a
scancode, X maps it to a keycode, XKB maps the keycode plus the current
modifier state to a keysym, and the toolkit maps the keysym to a character.
Every layer in that chain is layout-dependent. `XTestFakeKeyEvent` and
`xdotool key` inject at the **keycode** layer, which means the character your
application receives depends entirely on which layout the server has loaded.

The consequence is the thing that surprises people: injecting the keycode for
physical key `AD01` produces `q` under `us`, `a` under `fr`, and `й` under
`ru`. A harness that hardcodes keycodes is silently a `us`-only harness.

## Layer model

Build your input path in four layers. Keeping them separate is what makes the
result testable.

```
   "Grüße, Ελλάδα"                    what you want typed
        │
        ▼
  ┌──────────────┐
  │ 1. Selection │   pick a profile; start Xvfb with -keyboard PROFILE
  └──────────────┘
        │
        ▼
  ┌──────────────┐
  │ 2. Planning  │   text → sequence of (keycode, modifiers) steps,
  └──────────────┘   resolved against the *active* layout
        │
        ▼
  ┌──────────────┐
  │ 3. Injection │   XTEST / xdotool: press modifiers, press key, release
  └──────────────┘
        │
        ▼
  ┌──────────────┐
  │ 4. Verify    │   read the value back out of the application
  └──────────────┘
```

### Layer 1: selection

Choose the profile at server startup and never change it during a session:

```sh
Xvfb :99 -keyboard de -screen 0 1280x1024x24 -nolisten tcp
```

The catalog is closed. An unknown profile is a startup failure, by design —
`-keyboard xyz` will not fall back to `us`, it will refuse to boot. That is the
behavior you want: a typo in a config file should stop the run, not produce a
suite of subtly wrong assertions.

The full catalog, from `keyboard-profiles.nix`:

| Profile | Rules | Model | Layout | Variant | Options |
|---|---|---|---|---|---|
| `us` | evdev | pc105 | us | | |
| `us-intl` | evdev | pc105 | us | intl | |
| `gb` | evdev | pc105 | gb | | |
| `de` | evdev | pc105 | de | | |
| `fr` | evdev | pc105 | fr | | |
| `es` | evdev | pc105 | es | | |
| `latam` | evdev | pc105 | latam | | |
| `it` | evdev | pc105 | it | | |
| `pt` | evdev | pc105 | pt | | |
| `br` | evdev | pc105 | br | | |
| `pl` | evdev | pc105 | pl | | |
| `cz` | evdev | pc105 | cz | | |
| `tr` | evdev | pc105 | tr | | |
| `se` | evdev | pc105 | se | | |
| `ru` | evdev | pc105 | ru | | |
| `ua` | evdev | pc105 | ua | | |
| `gr` | evdev | pc105 | gr | | |
| `il` | evdev | pc105 | il | | |
| `ara` | evdev | pc105 | ara | | |
| `vn` | evdev | pc105 | vn | | |
| `be` | evdev | pc105 | be | | |
| `ch` | evdev | pc105 | ch | | |
| `nl` | evdev | pc105 | nl | | |
| `dk` | evdev | pc105 | dk | | |
| `no` | evdev | pc105 | no | | |
| `fi` | evdev | pc105 | fi | | |
| `rs` | evdev | pc105 | rs | | |
| `rs-latin` | evdev | pc105 | rs | latin | |

A profile is a full rules/model/layout/variant/options tuple, not a layout
name. Every current profile happens to be `evdev`/`pc105` with no options, but
do not encode that assumption: read the tuple.

The active profile is announced on stderr at startup:

```text
[xvfb-static:xserver] selected keyboard profile: ru
```

Capture that line. It is the cheapest possible assertion that the server you
are talking to is the one you configured, and it costs nothing to check.

### Layer 2: planning

**Do not hardcode keycodes.** Resolve them at runtime against the server you
are actually connected to. The X server will tell you its own mapping, and
that mapping already reflects whichever profile was selected.

The portable way is to walk the keyboard mapping and build a reverse index
from keysym to `(keycode, shift level)`:

```python
# python-xlib sketch; the same shape works from xcb, Xlib, or `xmodmap -pke`
import Xlib.display, Xlib.XK

display = Xlib.display.Display(":99")
min_kc = display.display.info.min_keycode
count = display.display.info.max_keycode - min_kc + 1
mapping = display.get_keyboard_mapping(min_kc, count)

# keysym -> (keycode, level). Lower levels win: prefer unmodified over Shift,
# and Shift over AltGr, so the plan uses the fewest modifiers that work.
index = {}
for offset, levels in enumerate(mapping):
    for level, keysym in enumerate(levels):
        if keysym and keysym not in index:
            index[keysym] = (min_kc + offset, level)
```

Then map each character to a keysym (`Xlib.XK.string_to_keysym`, or the
Unicode-to-keysym rule: keysym `0x01000000 + codepoint` for characters with no
legacy keysym) and look it up.

Three cases the plan must handle:

**Direct.** The keysym is at level 0 or 1 — press it, with Shift if level 1.

**AltGr.** Levels 2 and 3 need `ISO_Level3_Shift` held. On `de`, `@` is
AltGr+Q; on `pl`, `ą` is AltGr+A. Hold the modifier for the duration of the
keypress and release it afterwards, not once for the whole string.

**Dead keys.** `ü` on a `us-intl` keyboard is `dead_diaeresis` followed by `u`.
Composed characters are usually *not* in the mapping at all, so a lookup that
only consults the index will report them as untypeable. Handle them with a
compose table: character → sequence of keysyms. This is the case most harnesses
get wrong, and it is exactly why `us-intl`, `fr`, `es`, and `pt` are in the
catalog — they are the profiles where dead keys are load-bearing.

**When a character is genuinely unreachable**, fail loudly. A harness that
silently drops `€` because the active profile cannot produce it will produce a
test failure ten steps later that looks like an application bug. Report the
character, the profile, and the fact that the two are incompatible.

There is an escape hatch worth knowing about: you can temporarily bind an
arbitrary keysym to an unused keycode with `XChangeKeyboardMapping`, type it,
and unbind. It works, and it is the standard trick for injecting text a layout
cannot express. It also means you are no longer testing what a user of that
layout would experience — so use it for setup and fixtures, not for the
keyboard behavior under test.

### Layer 3: injection

Use XTEST. Press modifiers, press the key, release the key, release modifiers,
in that order, and release everything you pressed even on an error path — a
leaked held modifier corrupts every subsequent keystroke in the session and
produces failures that look random.

```sh
# xdotool does the planning and injection together for simple cases
DISPLAY=:99 xdotool type --delay 12 'Grüße'
```

`xdotool type` does its own keysym resolution and its own temporary remapping,
which makes it a reasonable default and a poor choice when the layout mapping
is the thing under test. For layout-sensitive work, plan explicitly and use
`xdotool key --window <id> ...` or XTEST directly.

Two practical notes:

- **Insert a small delay between keystrokes.** Zero-delay injection outruns
  some toolkits' event handling. 10–20 ms is usually enough; treat it as a
  tunable, not a constant.
- **Focus is your responsibility.** XTEST events go to the focused window. If
  nothing has focus the events go nowhere and the failure is silent.

### Layer 4: verification

Read the value back — from the DOM, the accessibility tree, the application's
own state, whatever is available. Do not treat "the injection call returned
successfully" as evidence that text arrived.

If nothing else is available, screenshot-and-OCR is a weak but real check. It
is enough to catch the failure mode that matters most here, which is not
"nothing was typed" but "the wrong characters were typed" — and the wrong
characters are precisely what a layout mismatch produces.

## Testing your input layer

Cover, per profile you support:

1. an unmodified character (`a`);
2. a `Shift` character (`A`);
3. an AltGr character, on a profile that has one (`@` on `de`, `ę` on `pl`);
4. a dead-key composition (`ü` on `us-intl`, `é` on `fr`);
5. a non-Latin script, if the profile provides one (`д` on `ru`, `α` on `gr`);
6. a character the profile genuinely cannot produce — assert that your layer
   reports it rather than typing something else.

Case 6 is the one worth writing first. It is the difference between a harness
that fails honestly and one that produces plausible wrong answers.

## Multiple layouts in one run

The catalog is fixed at startup and there is no live switching. To exercise
several layouts, start several servers on different display numbers:

```sh
Xvfb :91 -keyboard us &
Xvfb :92 -keyboard de &
Xvfb :93 -keyboard ru &
```

They are independent processes with independent keyboard state, which is
simpler to reason about than layout switching and removes a whole class of
ordering bug from your suite.

## What this artifact deliberately does not do

- **Arbitrary XKB layouts.** The catalog is closed; there is no `xkbcomp` and
  no `share/X11/xkb` in the archive. If you need a layout that is not listed,
  the options are to add it to `keyboard-profiles.nix` and rebuild, or to use a
  distribution Xvfb.
- **Runtime layout switching.** No `setxkbmap`, no layout groups.
- **IME and composition input.** Japanese, Korean, Chinese, and Indic text
  entry need an input method above the X layer. A physical layout alone would
  not give honest coverage, so those layouts are deliberately absent rather
  than present-but-inadequate.

## See also

- [AGENTS.md](../AGENTS.md) — sections 3 and 5, for the product contract and
  how the catalog is compiled and embedded.
- `keyboard-profiles.nix` — the catalog itself, and the only place the profile
  set is defined.
- `test/smoke.sh` — the boot-time assertions on profile selection, including
  the failure paths for unknown and missing profile arguments.
