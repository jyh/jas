# GUI_EYES — asserting visual facts about the live apps

A harness that drives a **real running app** and asserts facts read back out of
the **live DOM and the live canvas**. It exists to close a hole that is
structural, not accidental: three defect classes escaped every gate we have,
because no gate we have ever observes a renderer.

| # | Escape | Why CI could not see it |
|---|--------|-------------------------|
| 1 | a brush tile that declared a click behavior and was never wired | `widget_tree.rs` records `bind`/`style` key sets, not `behavior`, and is a projection of the compiled bundle — identical in every app |
| 2 | a checked icon-button whose highlight painted nothing | the state flipped correctly; only the *pixels* were wrong, and nothing compares them |
| 3 | a 5pt stroke that came back 1pt after an unrelated panel edit | the corpora replay at the `CanvasTool` / `dispatch_action` seam, well below the renderer |

The corpora in `test_fixtures/gestures|actions|keys` remain the right gate for
logic. This harness is the **manual-floor instrument**: it checks *correctness
of what is drawn*, and nothing about feel.

---

## Quick start

```sh
./scripts/gui_drive.sh                        # every check, exits nonzero on failure
./scripts/gui_drive.sh --list                 # what can be checked
./scripts/gui_drive.sh --check chain_visible   # one check
./scripts/gui_drive.sh --shot-dir /tmp/eyes   # keep evidence PNGs
./scripts/gui_drive.sh --headed               # watch it happen
./scripts/gui_drive.sh --regress dead_sweep   # prove a check can go red
```

`gui_drive.sh` starts a wasm dev server on **:8097** if nothing is serving there
(a private port, so a running `./dxserve.sh` on :8080 is never disturbed), runs
the checks, and exits nonzero if any failed. Needs Chrome, `dx`, and
`websocket-client` (already in `.venv`; the driver preflights all three and
picks the right Python even from a `git worktree`). **No macOS permission is
required** for the Rust lane — everything goes through the DevTools protocol —
so it runs unattended, on an unprivileged host. It is **CI-ready** (gates purely
on exit code, needs no display or grant); no CI lane is wired yet.

`$JAS_CHROME` overrides the Chrome binary; `$PYTHON` overrides the interpreter.

## The pieces

| File | Role |
|------|------|
| `scripts/gui_probe.py` | the probe library: launch, trusted input, DOM reads, canvas measurements, region statistics, liveness observer, freeze detector |
| `scripts/gui_checks.py` | the checks + the fault-injection modes |
| `scripts/gui_drive.sh` | conductor entry point (server up, run, exit code) |
| `scripts/gui_probe_swift.py` | the Swift lane: window capture + the same pixel measurements (partial — see §Swift) |

The DevTools transport is promoted from `scripts/record_pilot.py`, already
proven by five landed recorder pilots.

---

## What "assertable visual fact" means here

Prefer a **measurable property** over image equality. Whole-image diffs break on
every theme tweak and tell you nothing about *what* changed. In descending order
of preference:

1. **A measured quantity.** `ink_span()` scans a 1-px canvas line and returns
   `longest` — the contiguous inked run, i.e. the *thickness* of a stroke
   crossed perpendicularly. A 5pt stroke measures 6.0px; a 1pt stroke measures
   2.0px. Assert the number, or better, assert its **invariance** across an
   operation that must not change it (anti-aliasing-proof by construction).
2. **A pair that must agree.** The declared state (`data-checked`, published by
   the renderer for every `icon_button`) against the rendered state
   (`getComputedStyle`, and the actual pixel crop). Either side alone is green
   during escape #2; only their **divergence** names the bug.
3. **A colour at a probe point.** `probe_pixel(x, y)` returns exact canvas RGBA.
4. **Crop statistics.** `region_stats(target)` screenshots an element's exact
   rect and returns `mean` RGB, distinct-colour count, and a digest.
   `stats_distance(a, b)` is the Manhattan distance between two means — "checked
   looks different from unchecked" becomes `distance >= 10`, which survives a
   theme change, unlike a committed baseline image.
5. **Did anything move at all.** `watch_start()` / `watch_meaningful()` count DOM
   mutations attributable to a click, filtering the one record every click
   produces whether wired or not (`data-input-modality` on `<html>`, the
   focus-modality stamp). This is the generic detector for escape #1.

Baselines are supported (`--shot-dir`, element-clipped PNGs are ~1 KB) but are
**evidence, not oracles**. No check asserts image equality.

---

## The checks

| Check | Defect class it gates |
|-------|----------------------|
| `stroke_width_invariance` | a rendered property must survive an unrelated panel edit |
| `chain_visible` | declared-checked must be *visibly* checked (the pair assertion) |
| `tile_click_responds` | a declared-clickable tile must actually respond |
| `behavior_liveness` | the generic sweep — every declared-clickable widget in the DOM must move something |
| `arrowhead_reflects_scale` | a head's rendered size must match the scale the panel field shows |
| `brush_promotes_line` | applying a brush to a Line must thicken its ink (the Line→Path promotion) |
| `canvas_transform_balance` | a brushed repaint must leave the canvas transform exactly where it found it |
| `button_enter_activates` | a focused native `<button>` must still activate on Enter — the app may claim a key's default action only where the focused element has none of its own |
| `none_indicator_visible` | a no-paint swatch must *look* like no paint — the white face and the red diagonal, not a colour and not an empty slot (the unrendered-fact class) |

### The generic sweep is the one that scales

`behavior_liveness` derives its target list from `workspace/workspace.json`
(214 `behavior` blocks / 198 `event: click`), so it **grows with the YAML**
instead of needing a hand-written check per widget. For each declared-clickable
widget that the scene renders, is enabled, and is unoccluded, it dispatches a
trusted click and requires a meaningful DOM mutation.

It runs **one pristine app instance per widget**. That is not paranoia: clicking
widgets serially in a shared instance accumulates document and panel state, and
during development that accumulation produced a 200-record mutation storm — which
the sweep then blamed on the *next* widget. Isolation makes every verdict
attributable. (An unresponsive instance followed that storm; see §Findings 2 —
that half was never root-caused, and this driver has since been caught
manufacturing unresponsiveness of its own.)

A `DEAD` verdict is **not self-interpreting**. It can mean "declared clickable
and never wired" (the bug) or "a correct identity operation in the stock scene"
(clicking `cp_recent_3` when the recent-colour list is empty; clicking
`stk_swap_arrowheads` when both ends are None). Separating those takes a human
once per widget, after which the widget earns one of:

* a **precondition** (preferred) — `SWEEP_PRECONDITION` clicks something else
  first so the effect is non-trivial. `stk_reset_profile` does nothing when the
  profile is already uniform, so the sweep clicks `stk_flip_profile` first; the
  reset then registers, and an untestable skip became real coverage;
* a **`SWEEP_SKIP` reason** — every entry is a hole in the gate, so keep the
  list short and justify each line;
* a **bug report**.

Only *triaged* prefixes are gated by default (`SWEEP_DEFAULT_SCOPES`, currently
`align_` and `stk_`). Widen with `--sweep-scope cp_` to triage a shard, or
`--sweep-scope all` for everything. **Growing that tuple is the point** — each
prefix promoted is a permanent gate against escape #1.

The sweep can never be a headless gate: `widget_tree.rs` is a projection of the
same bundle and cannot observe wiring.

---

## HEALTH, MEASURED 2026-08-04 — the instrument still works, and still bites

Unrun for eleven days (built 2026-07-24). Re-run end to end on a cold tree:

```
./scripts/gui_drive.sh                 9/9 ok
every --regress MODE (all ten)         10/10 TEETH ok
wasm build                             24s
```

Both halves matter and only one of them is usually taken. **9/9 green says the
app is well; 10/10 TEETH says the checks can still tell.** A suite that has not
had its faults injected since it was written is a suite whose greens are
unaudited, and this one had gone eleven days.

One defect found and fixed in the same pass: `--list` and `--help` started
`dx serve` before answering from a static table — ~5 minutes to print nine lines
it already had. They now short-circuit before the server block: **0.14s with
nothing serving**, proven by killing the server and re-running.

## Fault injection — a green check proves nothing until it goes red

`--regress MODE` reproduces a real defect at the layer it escaped from. **Each
mode owns exactly one check** — the one it must break — so `--regress MODE`
with no `--check` auto-selects it. (Pairing a mode with a different `--check`
is a usage error, exit 2, never a fake red — the old behavior ran the fault
against *every* selected check, so the non-matching ones scored `TEETH MISSING`
and a bare `--regress dead_tile` exited nonzero on a perfectly healthy app.)

| Mode | Owning check | What it breaks |
|------|--------------|----------------|
| `invisible_highlight` | `chain_visible` | a stylesheet override neutralises the checked highlight — `data-checked` still flips, nothing paints |
| `dead_tile` | `tile_click_responds` | strips the clicked swatch's `data-dioxus-id`, so Dioxus's delegated dispatch can no longer resolve the handler: declared, rendered, unwired |
| `dead_sweep` | `behavior_liveness` | strips `data-dioxus-id` from one in-scope swept widget (`stk_link_arrowhead_scale`) **in the same pristine probe that clicks it**, so the sweep reports exactly that widget `DEAD` |
| `dead_brush_tile` | `brush_promotes_line` | strips `data-dioxus-id` from every brush tile, so the click applies no brush and the Line is never promoted |
| `thin_stroke` | `stroke_width_invariance` | draws the probe stroke at 1pt when the check asked for 5pt — trips the check's *absolute* assertion |
| `width_reset` | `stroke_width_invariance` | drives the rendered width to 1pt across the unrelated edit — trips the check's *invariance* assertion, the one that names the escape |
| `arrow_scale_lie` | `arrowhead_reflects_scale` | overwrites the end-scale field's DOM value to 200 while the head stays at its true 100%, so the panel claims a scale the canvas never rendered |
| `leaked_ctx_save` | `canvas_transform_balance` | pushes one un-restored `save()` + transform onto the live canvas context — the class the brushed-path early `return` used to leak |
| `enter_default_stolen` | `button_enter_activates` | prevents Enter's default from a **capturing document listener, regardless of what holds focus** — the over-broad suppression that killed native button activation (Dioxus delegates the app's keydown from the document root, so this is the same claim at the same layer) |
| `none_indicator_flat` | `none_indicator_visible` | strips the red diagonal from the fill swatch and keeps stripping it through re-render — what reverting the `explicit_none` plumbing renders, which every unit test, every golden and 8/8 of these checks were blind to |

**Scoring is not a blind inversion** — a red for the wrong reason proves
nothing. Each mode declares a *marker* (a fragment of its owning check's own
`ctx.want` message). The run reports:

* `TEETH ok`, **exit 0** — the check failed *and* the failure carried the
  marker (the fault was genuinely caught);
* `TEETH MISSING`, **exit 1** — the check passed with the fault injected (the
  gate is blind to the defect it claims to catch);
* `HARNESS ERROR`, **exit 3** — the check failed *without* the marker, or the
  harness itself broke (no Chrome, dev server down, a CDP timeout, a launch
  failure). "Teeth unproven": a caught fault and a broken host must not look
  alike.

**Add a fault whenever you add a check**, owning that one check, with a marker.
A check nobody has seen fail is a check nobody should trust.

---

## Adding a check

1. **Pick a defect class, not a widget.** The name should describe what must
   stay true.
2. **Find the handle.** Every YAML widget id is emitted as the DOM element id
   (`interpreter/renderer.rs`), so `#stk_weight` addresses the Stroke weight
   field. Spec-addressed targets are immune to layout and theme churn. Confirm
   with `./scripts/gui_drive.sh --headed` and DevTools.
3. **Write it in `scripts/gui_checks.py`:**

```python
@check("dash_gap_renders", "a dashed stroke actually renders gaps")
def dash_gap_renders(ctx: Ctx):
    p = ctx.p
    draw_probe_line(ctx, "5")
    p.click("stk_dashed")
    ctx.inject("no_dashes")                       # your fault hook
    span = p.ink_span(SCAN_X, LINE_Y - 2, 200, axis="h")
    ctx.note(f"along the stroke: {span['pattern']}")
    ctx.want("0" in span["pattern"].strip("0"),
             f"the stroke has gaps along it (pattern {span['pattern']})")
```

   * `ctx.want(cond, msg)` — the message states the fact in the affirmative and
     carries the numbers, so a failure is self-diagnosing.
   * `ctx.note(...)` — evidence, always printed.
   * `ctx.shot(name, target)` — a PNG when `--shot-dir` is set.
   * `p.heartbeat()` after anything risky, so a wedged app is a named result in
     6 seconds instead of a mystery 30-second timeout inside an unrelated probe.
4. **Add the matching `--regress` fault, owning this one check, with a marker.**
   Register it in `FAULTS` as `Fault(apply_fn, "your_check", "marker")`, where
   `marker` is a stable fragment of the `ctx.want` message the fault will trip.
   Then run `--regress your_mode` and watch it report `TEETH ok` (exit 0). If it
   reports `HARNESS ERROR`, the fault tripped a *different* assertion than the
   marker names — fix the marker or the fault so the red is attributable. If the
   fault must land in a probe other than the check's primary (as the liveness
   sweep does, per widget), pass it explicitly: `ctx.inject(mode, probe=p)`.
5. **Mind determinism.** Fixed 1400x1300 window, `--force-device-scale-factor=1`,
   `--hide-scrollbars`, a fresh Chrome profile, and a document created through
   the app's own Ctrl+N. Never `element.click()` — always a trusted click at a
   rect centre, so the event travels the production hit-test path.

### Traps already paid for

* **A target below the fold silently swallows clicks.** Chrome drops mouse
  events dispatched outside the viewport, so an unclickable widget reads as
  merely inert. `ensure_visible()` scrolls first and `center()` raises if the
  point is still unreachable. `stk_link_arrowhead_scale` sits at y≈1030.
* **`captureBeyondViewport` breaks subsequent clicks.** It installs a viewport
  override that leaves `Input.dispatchMouseEvent` coordinates mis-mapped — a
  screenshot taken *before* a click stopped the click from landing. Not used.
* **Ctrl+A and Backspace never reach a text field.** The app claims both at the
  document level (Select All / Delete), so they append instead of replacing,
  yielding values like `"1 pt5"`. `set_field()` triple-clicks to select the
  value inside the input, then types — which is also what a user does.
* **A key dispatched without its `text` can storm the browser.** `Enter` and
  `Escape` carry a legacy control character (`\r`, `\x1b`). Sent through
  `Input.dispatchKeyEvent` with a virtual key code but no `text`, Chrome
  re-queues them without limit — one Enter measured 8757 further trusted
  `key="Unidentified"` keydowns, one Escape 10589, **on a blank page with no app
  loaded**. Nothing else in `VK` (Backspace, Tab, Delete) does this. Beyond
  burning the main thread, a textless Enter produces no `keypress`, so it never
  triggers the browser default that fires an input's `change` — the field the
  driver "committed" quietly did not commit until something later blurred it.
  `gui_probe.KEY_TEXT` supplies the text; see §Findings 1 for what believing the
  storm cost.
* **A key's default action belongs to whatever element has focus.** A root
  handler that calls `preventDefault` on Enter because "no text field is
  focused" also kills the NATIVE Enter activation of every `<button>` in its
  subtree — measured on this app: File ▸ Document Setup with OK focused reported
  `defaultPrevented=true`, fired no click, and the dialog would not close from
  the keyboard, while Space on the same button still worked. Suppress a default
  only where the focused element has no default of its own (`keyboard.rs` gates
  on an allowlist of the app's own surfaces); `button_enter_activates` is the
  gate, `--regress enter_default_stolen` its teeth.
* **Use `hit_target()`** to confirm the widget is really the topmost element at
  its own centre before believing a click did nothing.
* **Never let mutation noise evict mutation signal.** The liveness observer
  filters decoration *in the page, ahead of its cap*, and only counts it. An
  earlier version stored the first 200 raw records and filtered afterwards; a
  `data-input-modality` storm then filled the cap with focus decoration and
  crowded out the meaningful records behind it, so a demonstrably live widget
  intermittently reported `201 raw, 0 meaningful` and the check failed. If you
  add a capped buffer anywhere in a check, make sure noise cannot fill it.

---

## Swift lane — partial, and the blocker

**Working:** the pixel half, in `scripts/gui_probe_swift.py`, using the same
measurement vocabulary as the Rust lane so the numbers are comparable —
`find_window` (exact `kCGWindowName`), `capture` (`screencapture -x -o -l<id>`,
which succeeds for background and occluded windows, so the app is never raised
and focus is never stolen), `region_stats`, `stats_distance`, `ink_span`.
Verified end to end by `gui_probe_swift.py selftest`, which needs no Swift build:
window lookup, a 646 KB / 5120x2880px capture at correctly-derived retina scale
2.0, PNG decode, two distinguishable crops (distance 25.83), a scanline
measurement, and a byte-stable repeat digest.

`./swift.sh --title JasHarness --test-fifo /tmp/jas-harness.fifo` now launches a
drivable instance — the launcher forwards arguments as of this wave, where
before it swallowed them and there was no way to start a targetable window. The
app already parsed both flags. Input injection is `jas_gui_harness.py` (pyobjc
Quartz `CGEventPost`) plus the fifo verbs `tool <id>` / `action <name> [json]`.

> **UNBLOCKED 2026-08-04 (`PROBEIDENTITY`).** `.accessibilityIdentifier` is now
> attached in `YamlPanelBodyView.swift` — at the ONE seam every widget kind
> passes through (`var body`), not at the twenty `render*` arms this note
> suggested, so a kind added tomorrow is addressable without anyone remembering
> to tag it. The stated reason for deferring — *"that file is owned by a
> parallel wave"* — expired when that wave landed.
>
> What that buys and what it does not: every YAML widget id is now visible to
> the Accessibility API, so an out-of-process probe can resolve an id to a
> screen rect and read its role/value. **The probe half is NOT written**, so no
> pair assertion is ported yet and this lane is still partial — the blocker has
> moved from "impossible" to "unbuilt", which is a different queue.
>
> The paragraph below is kept as written; it is the record of why this sat.

**Blocked: READ-BACK.** Swift has no equivalent of `Runtime.evaluate`, so the
*declared* half of every pair assertion is unavailable — nothing can ask the
running app "is this widget checked?", and no YAML widget id can be resolved to
a screen rect. Therefore `chain_visible` cannot be ported (with pixels only it
degrades to the image-diff we set out to avoid) and neither can the liveness
sweep.

The unblock is one line per widget site —
`.accessibilityIdentifier(widget.id)` in
`JasSwift/Sources/Interpreter/YamlPanelBodyView.swift` — after which the
already-granted Accessibility API gives Swift the same id-addressed reflection
CDP gives Rust (`osascript` System Events can already read another app's
UI-element roles and names). **That file is owned by a parallel wave, so it is
deliberately untouched here.** The alternative unblock is a `dump <what> <path>`
fifo verb; the OCaml fifo's third verb (`open_dialog`) is the precedent that
this vocabulary is meant to grow.

### Permissions AND an unlocked, awake display

Two grants, plus a runtime condition the grants do not cover.

**The two grants.** Screen Recording and Accessibility are **already granted**,
verified with non-prompting APIs. The grant follows the terminal that launches
Claude Code — currently **iTerm**. From Terminal.app, VS Code, or the desktop
app, that host needs the same two toggles. Preflight:

```sh
.venv/bin/python -c "import Quartz; print(Quartz.CGPreflightScreenCaptureAccess())"
.venv/bin/python -c "import ctypes,ctypes.util; l=ctypes.cdll.LoadLibrary(ctypes.util.find_library('ApplicationServices')); l.AXIsProcessTrusted.restype=ctypes.c_bool; print(l.AXIsProcessTrusted())"
```

Both must print `True`. **Never call `CGRequestScreenCaptureAccess()`** — it
prompts. The Rust lane needs neither permission.

**The runtime condition — an UNLOCKED, AWAKE display on the console.** This is
NOT covered by the two toggles and matters for unattended use. `screencapture`
returns exit 0 but writes a **blank frame** when the screen is locked
(`CGSSessionScreenIsLocked`) or the display is asleep — verified on this host:
permissions read `True`, capture came back black. So a locked machine would
have produced a green-looking capture of nothing. The Swift lane now preflights
this (`require_capturable_display()`) and stops with a **named** message
(exit 3) rather than measuring a black rectangle; check the current state with:

```sh
.venv/bin/python scripts/gui_probe_swift.py session   # locked/asleep/on_console
```

It also filters the window list to **real, layer-0 app windows**, so the
lock-screen `Display N Shield` pseudo-windows the Window Server puts up can
never be selected as a capture target. For unattended runs, keep the display
unlocked and awake (disable display sleep, or use `caffeinate`).

---

## Limits — what this harness does NOT check

It checks **correctness, not feel**. Staying on JYH's manual floor:

* **Taste.** Whether a highlight reads as *pleasant*, whether spacing looks
  right, whether an icon is legible. The harness proves the checked state is
  measurably different by 140.73 mean-distance; it cannot say it looks good.
* **Motion.** Animation smoothness, transition timing, drag latency, whether a
  gesture feels responsive.
* **Cursors and native chrome.** No cursor glyph is captured; menus, sheets and
  window furniture are outside it.
* **ANY PANEL THAT IS NOT OPEN BY DEFAULT.** Measured 2026-08-04 against the
  live DOM: the reachable id prefixes are `cp_` (60), `stk_` (33), `ch_` (24),
  `align_`/`distribute_` (9 each), `ap_` (9) and `btn_` (13) — and **every
  `btn_` is a TOOL button** (`btn_pen_slot`, `btn_lasso`, …), not a panel
  toggle. There is no menu in the DOM and no dock handle, so **a check cannot
  open Layers, Swatches, Gradient, Symbols, Concepts or Boolean.** Zero
  `lp_*` ids are present in a default document.

  This is sharper than "menus are outside it" above, and it is what actually
  bites: it puts every closed-by-default panel out of reach, not just the menu
  bar. Anything needing one waits on a handle — a `toggle_panel` verb the probe
  can drive, or a test-only dock button.
* **Retina fidelity.** The Rust lane runs headless at
  `--force-device-scale-factor=1`; it is not a subpixel or hairline oracle.
* **Anything a mouse cannot reach.** Flyout long-press, IME, real focus/tab
  comfort.
* **Cross-app parity.** This is not a parity gate. Equivalence across the active
  ports is pinned by the shared corpora; a `region_stats` mean is not portable
  between a browser canvas and a Core Graphics one.

---

## Findings from building it

What the harness reported while being validated, kept honest: a finding stays
here after it is retracted, with the evidence that retracted it.

1. ~~**A second Stroke-panel weight commit made while an object is selected
   wedges the app.**~~ **RETRACTED 2026-07-25 — the wedge was this harness's,
   not the app's.** The finding was real as an observation (latency 0.0s →
   2.8s → 19.2s → no response) and wrong as a diagnosis. `set_field` committed
   with an Enter dispatched through `Input.dispatchKeyEvent` *without* its
   control-character `text`; Chrome never completes such a key and re-queues it,
   so one Enter became **8757 trusted `key="Unidentified"` keydowns** — which
   saturates any app on the page. Proof that no app is involved: the same
   dispatch on a blank `data:text/html,<input>` page with nothing loaded
   produced **11543** of them, and supplying the text produces exactly one
   keydown WHEREVER SOMETHING CONSUMES OR PREVENTS THE KEY (an input, a button,
   or a handler calling preventDefault); on a bare focusable div with no
   consumer Chrome still re-queues (13k+ trusted `key='Unidentified'`
   measured), so the `text` is necessary, not sufficient — no path this
   harness drives is such a surface. Fixed in `gui_probe.KEY_TEXT`; the same
   `--regress width_reset` scenario now runs with a **0.0s heartbeat**.

   Two WEDGESTORM diagnosis attempts were sent chasing this ghost. The real
   defect behind JYH's receding-artboard cascade was a leaked `ctx.save()` in
   the brushed-path render (fixed at `e4622b87`, pinned by
   `canvas_transform_balance`). **Lesson: a driver artifact and an app defect
   are indistinguishable from inside the driver.** Before believing the app is
   wedged, reproduce the input on a page the app does not own.
2. **Serial clicking degenerates.** Clicking ~5 declared-clickable widgets in one
   instance took `align_to_key_object_button` from 3 DOM mutations to a
   200-record storm and a 1.35s heartbeat. In a pristine instance that widget is
   healthy. Whether a user could reach this state is unknown; the accumulation
   itself is the finding. (An unresponsive instance followed it; that part was
   never root-caused, and after finding 1 no unresponsiveness observed *through*
   this driver should be attributed to the app without independent evidence.)
3. **16 of 21 `cp_` widgets report DEAD in the stock scene** and need triage.
   Most look like correct identity operations (empty recent-colour slots, an
   already-active mode), but `cp_gradient_btn`, `cp_none_btn` and
   `cp_none_swatch` are genuine suspects — switching to gradient mode ought to
   change something. Triage with `--sweep-scope cp_`.
