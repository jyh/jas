# Smoke tests — post tool-activation fix

Branch: `smoke-tests-post-activation` (off `main` @ `5fc91a61`).
Date: 2026-06-24.
Driver: `jas_gui_harness.py` (Quartz synthetic input + `screencapture`).

## Scope

Sanity-check that all four native/desktop apps launch and the core interactive
path works after merging the tool-activation fix (`5fc91a61`) — with explicit
coverage of the paths that were broken/crashing in the Rust app:

- **S1 Launch** — window appears with a document + artboard.
- **S2 Draw** — select Rectangle (`M`) + mouse drag → a rectangle is created and
  auto-selected.
- **S3 Tool-switch no-crash** — select Scale (`S`) with a shape selected, then Pen
  (`P`). These are the exact triggers that produced the Rust `RefCell already
  borrowed` panic before the fix.
- **S4 File▸New** (Rust only — it was broken there) — creates a new tab/document.

## Harness pattern (carried over from the per-app drag checks)

- Select tools by **keyboard shortcut** (`M`/`S`/`P`/`V`), not the toolbar icon —
  a synthetic icon click can register as hover, not select.
- Draw with the **button-held `dragbegin`/`dragpath`/`dragend`** sequence with
  short sleeps, not a single-shot `drag` — GTK/Qt/web canvases need the motion
  spread over time or it reads as a click.
- Launch each app with `--title <X>` and match with `JAS_TITLE=<X>`. Note `JAS_TITLE`
  is a substring match, so close other `Jas*`-titled windows first (e.g. `JasSwift`
  matches a bare `Jas` query).

## Results — ALL PASS

| App | Framework | S1 Launch | S2 Draw (drag) | S3 Scale/Pen no-crash | S4 File▸New |
|-----|-----------|-----------|----------------|-----------------------|-------------|
| Rust / Dioxus | web/wasm (chromeless Chrome) | PASS | PASS | **PASS** (scale `+` ref-cross drawn; no panic) | PASS |
| Swift | AppKit | PASS | PASS | PASS | n/a (was fine) |
| OCaml | lablgtk3 | PASS | PASS | PASS | n/a (was fine) |
| Python | PySide6/Qt | PASS | PASS | PASS | n/a (was fine) |

The Rust S3 is the key result: selecting Scale on a selected shape draws the
reference-point cross overlay and selecting Pen switches cleanly — both formerly
panicked (`js-sys QueueState::run_all` `RefCell already borrowed`, the red-herring
surfacing of an un-activated tool's uninitialized state). Confirms `5fc91a61`.

## All-tools smoke pass (every tool, every app)

The bundle defines **27 YAML tools** (Type / TypeOnPath are permanent-native, out of
scope for the YAML activation path). Of the 27, **19 are reachable by keyboard
shortcut** and **8 are flyout-only alternates** of a tested group.

### Method

Per app: launch fresh, draw a rectangle (so a selection exists), then cycle every
shortcut tool and confirm the app does not crash (native: process stays alive;
Rust/web: no "App panicked" overlay). The harness `key`-code table was extended to
cover `\`, digits, and a few symbols so `\` (line) is reachable.

### The 19 shortcut tools

`V` selection · `A` partial_selection · `Y` magic_wand · `Q` lasso · `P` pen ·
`C` anchor_point · `N` pencil · `B` paintbrush · `Shift+B` blob_brush ·
`Shift+E` path_eraser · `M` rect · `L` ellipse · `\` line · `S` scale · `R` rotate ·
`H` hand · `Z` zoom · `O` artboard · `I` eyedropper.

| App | All 19 select w/o crash | Draw gesture |
|-----|:----------------------:|:------------:|
| Rust / Dioxus | **PASS** (no panic) | PASS |
| Swift / AppKit | **PASS** (alive) | PASS |
| OCaml / lablgtk3 | **PASS** (alive) | PASS |
| Python / PySide6 | **PASS** (alive) | PASS |

Every tool group — selection, pen/anchor, freehand, shape/line, transform, view,
eyedropper/artboard — selects cleanly in all four apps.

### The 8 flyout-only tools

`rounded_rect` `polygon` `star` (shape flyout) · `shear` (transform flyout) ·
`smooth` (pencil flyout) · `add_anchor_point` `delete_anchor_point` (pen flyout) ·
`interior_selection` (selection flyout).

These are NOT independently drivable by the Quartz harness: opening a toolbar
flyout needs a real long-press, and a synthetic held-button does not trip the
native long-press gesture detectors (GTK/Qt/AppKit/web). They are covered
indirectly and with high confidence: each is selected through the **same**
`select_tool` → `set: active_tool` → `set_tool`+`activate` path as its group's
primary tool (which passed), so its crash surface is identical; and the
flyout-selection wiring was separately verified at the code level (see
[[project_tool_activation_lifecycle]]). **Status: covered-by-shared-path (not
independently GUI-driven).**

## Minor observations (not blockers)

- ~~Rust File▸New labels the new tab `Untitled-1` again (duplicate) rather than
  advancing to `Untitled-2`, when the session already restored an `Untitled-1`.~~
  **RESOLVED (72459a07)** — the untitled counter is now advanced past restored
  docs on session restore in Rust and Swift (OCaml/Python already did this);
  File▸New gives a unique `Untitled-N`. GUI-verified in the Rust app.
- All four native apps restore the previous session's document, so rectangles drawn
  in earlier smoke runs accumulate across launches. Expected (persistence), not a bug.
- Harness/window-management notes: `JAS_TITLE` is a substring match (`JasSwift`
  matches a bare `Jas`), so drive one app at a time and close others first; the Rust
  chromeless Chrome window is reliably drivable only right after it is opened
  (frontmost) — once other apps churn focus, synthetic clicks miss it. The user's
  own Chrome windows (e.g. WhatsApp) are correctly ignored by the `Jas` title match.

---

# Smoke test — Shift-constrain + one round kind (2026-07-30)

Branch: `main` @ `715944d0`. Driver: **JYH, by hand, in JasSwift.**

Hand-driven on purpose. Everything below is reachable only by drawing and
clicking, and the two changes it covers landed the same afternoon with 20 gates
and ~4100 tests green between them. Both were found or shaped by JYH clicking,
which is the third time this week a defect arrived that way and the zeroth time
one arrived from the suite.

## What was checked, and why the suite cannot

| # | check | result |
|---|---|---|
| 1 | Shift + ellipse drag draws a **circle**; Shift + rect draws a **square**; the dashed preview stays constrained *during* the drag | PASS |
| 2 | Layers labels the Shift shape `<Circle>` and the dragged one `<Ellipse>`; the **Circle** filter keeps the round one and drops the other; **Ellipse** is the mirror | PASS |
| 3 | Both shapes select by click and by rubber band (hit-test lost its circle arm) | PASS |
| 4 | A circle scaled non-uniformly **looks** like an ellipse but **still answers `circle`** | PASS — accepted |
| 5 | Save emits `<circle cx cy r/>` for the round shape; reopen keeps it round and labelled `<Circle>` | PASS |
| 6 | An ellipse nudged toward equal radii starts answering `<Circle>` | not reproducible by hand |

Item 1 is where the drag-preview seam is actually observable: the constraint is
applied where the cursor state is WRITTEN, so the overlay and the committed
element are computed from the same point and cannot disagree. Nothing in the
corpus watches the preview — it is drawn, never serialized.

## Two rulings that came out of the clicking

**#4 is the honest limit, and JYH accepted it as drawn.** The token reads the
radii AS AUTHORED and ignores `common.transform`, so a squashed circle still
answers `circle`. That is deliberate and consistent: no type token accounts for
transforms — a sheared rect is still `rectangle` — and making this the one token
that consults the matrix would be a second rule nobody could predict from the
first. Recorded here because it looks like a bug on screen and is not.

**#6 turned out to be better news than the check was designed to find.** JYH
could not reach exact radius equality by dragging. Since the token ignores
transforms, *scaling can never flip it either* — so the ONLY way an element
becomes a `<Circle>` is a deliberate Shift-draw. The float-equality edge the
derived token appeared to expose is therefore essentially unreachable in
practice, and the token is far more stable than its `rx == ry` spelling suggests.
That is a property nobody would have predicted from reading the code; it took a
hand on the mouse failing to do something.

---

# Judgment smokes, 2026-08-05 (JasSwift native, release build, `82186880`)

Driver: JYH at the canvas. Scenes: `smoke/`. Recorded the same day, because
three separate firings had re-asked whether ARROWTRIM was ever re-smoked.

## S1 — ARROWTRIM re-smoke: **PASS**

`smoke/01-arrowtrim.svg` — curved path, arrowheads both ends, arrowhead scale
200. This is JYH's original screenshot case of 2026-07-24 rebuilt.

> "Looks great" — JYH

Both heads sit on the path's true end tangents (start head down-left, end head
down-right, matching where the curve arrives). **No poke-through at either
head.** The two symptoms the ARROWTRIM stone was raised for — orientation flip
at scale 200, and the curve protruding past the head — are both gone.

## S1a — banked question 1: **NOT ASKED. The scene was wrong.**

The scene was supposed to pose "stroke wider than its arrowhead, so the butt-cut
shoulders show at the sides". The ratio was authored backwards: the red path's
head is far WIDER than its 18pt stroke, so there are no shoulders to see. The
question is still open and still unasked; a corrected scene needs a head
narrower than the stroke.

## S1b — banked question 2: **CONFIRMED, and worse than documented**

> "In the stroke panel it is round, but it comes up a square. Clicking on a
> different cap does not do anything." — JYH

Measured immediately, and the first two links are INNOCENT: the importer parses
`stroke-linecap` (svg.rs:1488) and it survives a round trip, so the model
genuinely holds `LineCap::Round`; the Stroke panel correctly displays round.
Only the render disagrees.

So this is not merely "a single-arrow path loses the round cap on its free end",
which is how it was banked. **The cap control appears inert to the artist** —
all three buttons look like they do nothing — which is a live interaction defect,
not a documented simplification. Under diagnosis in both ports; the owner rules
on the fix, because per-end caps may require stroke splitting.

## S1c — INCIDENTAL FINDING, ruled the same hour

> "although there is no artboard" — JYH

Artboards are parsed ONLY from `<inkscape:page>` inside `<sodipodi:namedview>`,
so a jas-authored file round-trips but ANY foreign SVG imports with no page at
all — despite its `viewBox` stating the page exactly. **RULED by JYH the same
hour: the viewBox becomes an artboard on import, always** (an unwanted artboard
is visible and deletable; a missing one is silent). An `<inkscape:page>` still
wins where present.

**Found thirty seconds into the first smoke in weeks** — which is the empirical
argument for human contact with the product that the phase-end discussion had
just made in the abstract.

## S2 — BRUSHSAVE round trip: **PASS**

`smoke/02-brushsave.svg`, JYH at the canvas.

> "the round trip (with the simple stroke) passes" — JYH

Open, File>Save, reopen: **the brush id and the variable-width profile both
survive**. That is precisely the BRUSHSAVE claim, and precisely what every save
silently discarded until 2026-08-05. The variable-width path also rendered
correctly on the way in ("the green one has variable width").

**Scope, stated so this is not over-read:** BRUSHSAVE was a PERSISTENCE fix,
never a rendering one. What is proven is that the attributes survive the codec.

## S2a — TWO SCENE DEFECTS, both mine, and the second is the instructive one

The blue path rendered as a plain stroke. Cause: I authored
`default_brushes/flat_10`, which **does not exist** — the library holds
`basic, round_3pt, round_7pt, flat_5pt, oval_5pt, round_10pt, art_tapered,
pattern_diamonds, bristle_round`. The renderer falls back to a plain stroke for
an unresolvable brush. Second invalid id I authored today, after
`jas:start-arrow="triangle"`.

**The instructive part is that my verification passed it.** I round-tripped this
scene through the real codec before committing, exactly to avoid wasting the
smoke hour — and it went green, because `jas:stroke-brush="default_brushes/flat_10"`
survives the codec perfectly AS A STRING. My check asked *does the attribute
survive?* when the question was *does the value resolve to a real brush?*
**Round-trip fidelity is not referential validity.** The subject-list class
again, this time inside the step built to prevent it.

Scenes now validated for RESOLUTION, not just survival: every `jas:stroke-brush`
and every arrowhead name in `smoke/` is checked against
`workspace.json`'s actual libraries.

## S2b — OPEN QUESTION raised by that accident

An unresolvable brush id renders as a plain stroke with **no complaint anywhere**
— no panel warning, no log line. A document referencing a brush from a library
you do not have therefore opens looking *fine and wrong*: the artwork is not
lost, it is silently downgraded. Graceful fallback is defensible in a renderer;
silence about it may not be. For the council queue, beside the other spec
silences.
