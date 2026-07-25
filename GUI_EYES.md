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
./scripts/gui_drive.sh --regress dead_tile    # prove the checks can go red
```

`gui_drive.sh` starts a wasm dev server on **:8097** if nothing is serving there
(a private port, so a running `./dxserve.sh` on :8080 is never disturbed), runs
the checks, and exits nonzero if any failed. Needs Chrome, `dx`, and
`websocket-client` (already in `.venv`). **No macOS permission is required** for
the Rust lane — everything goes through the DevTools protocol — so it runs
unattended, on an unprivileged host, and in CI.

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

### The generic sweep is the one that scales

`behavior_liveness` derives its target list from `workspace/workspace.json`
(214 `behavior` blocks / 198 `event: click`), so it **grows with the YAML**
instead of needing a hand-written check per widget. For each declared-clickable
widget that the scene renders, is enabled, and is unoccluded, it dispatches a
trusted click and requires a meaningful DOM mutation.

It runs **one pristine app instance per widget**. That is not paranoia: clicking
widgets serially in a shared instance accumulates document and panel state, and
during development that accumulation produced a 200-record mutation storm and
then a wedge — which the sweep then blamed on the *next* widget. Isolation makes
every verdict attributable.

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

## Fault injection — a green check proves nothing until it goes red

`--regress MODE` reproduces a real defect at the layer it escaped from and
**inverts the verdict**: a check that fails is reported `TEETH ok` and the run
exits 0; a check that still passes is `TEETH MISSING` and the run exits nonzero.

| Mode | What it breaks | Which check must catch it |
|------|----------------|---------------------------|
| `invisible_highlight` | a stylesheet override neutralises the checked highlight — `data-checked` still flips, nothing paints | `chain_visible` |
| `dead_tile` | strips the tile's `data-dioxus-id`, so Dioxus's delegated dispatch can no longer resolve the handler: declared, rendered, unwired | `tile_click_responds`, `behavior_liveness` |
| `thin_stroke` | draws the probe stroke at 1pt when the check asked for 5pt | `stroke_width_invariance` |
| `width_reset` | commits a second Stroke-panel weight edit while an object is selected | `stroke_width_invariance` |

**Add a fault whenever you add a check.** A check nobody has seen fail is a
check nobody should trust.

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
4. **Add the matching `--regress` fault and watch it go red.**
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
* **Use `hit_target()`** to confirm the widget is really the topmost element at
  its own centre before believing a click did nothing.

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

### Permissions (nothing for JYH to click)

Screen Recording and Accessibility are **already granted**, verified with
non-prompting APIs. The grant follows the terminal that launches Claude Code —
currently **iTerm**. From Terminal.app, VS Code, or the desktop app, that host
needs the same two toggles. Preflight:

```sh
.venv/bin/python -c "import Quartz; print(Quartz.CGPreflightScreenCaptureAccess())"
.venv/bin/python -c "import ctypes,ctypes.util; l=ctypes.cdll.LoadLibrary(ctypes.util.find_library('ApplicationServices')); l.AXIsProcessTrusted.restype=ctypes.c_bool; print(l.AXIsProcessTrusted())"
```

Both must print `True`. **Never call `CGRequestScreenCaptureAccess()`** — it
prompts. The Rust lane needs neither permission.

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
* **Retina fidelity.** The Rust lane runs headless at
  `--force-device-scale-factor=1`; it is not a subpixel or hairline oracle.
* **Anything a mouse cannot reach.** Flyout long-press, IME, real focus/tab
  comfort.
* **Cross-app parity.** This is not a parity gate. Equivalence across the active
  ports is pinned by the shared corpora; a `region_stats` mean is not portable
  between a browser canvas and a Core Graphics one.

---

## Findings from building it

The harness found these while being validated. **None is fixed here** — this
wave built tooling, and two of the three touch files owned by a parallel wave.

1. **A second Stroke-panel weight commit made while an object is selected wedges
   the app.** Repro: set `stk_weight` (nothing selected) → draw a line → select
   it → set `stk_weight` again. No JS or wasm exception is raised and the window
   does not blank; the main thread's latency escalates 0.0s → 2.8s → 19.2s → no
   response, which is a **livelock, not a panic** — the signature of an unbounded
   panel↔selection binding feedback loop. Direction is irrelevant (5→1 and 5→9
   both wedge). A *single* weight edit with a selection is fine, so the trigger
   needs the panel's own state dirtied by a prior explicit edit. This is
   plausibly the same defect family as the 5pt→1pt complaint that motivated the
   wave. Reproduce with
   `./scripts/gui_drive.sh --check stroke_width_invariance --regress width_reset`.
2. **Serial clicking degenerates.** Clicking ~5 declared-clickable widgets in one
   instance took `align_to_key_object_button` from 3 DOM mutations to a
   200-record storm and a 1.35s heartbeat, then a wedge on the next click. In a
   pristine instance that widget is healthy. Whether a user could reach this
   state is unknown; the accumulation itself is the finding.
3. **16 of 21 `cp_` widgets report DEAD in the stock scene** and need triage.
   Most look like correct identity operations (empty recent-colour slots, an
   already-active mode), but `cp_gradient_btn`, `cp_none_btn` and
   `cp_none_swatch` are genuine suspects — switching to gradient mode ought to
   change something. Triage with `--sweep-scope cp_`.
