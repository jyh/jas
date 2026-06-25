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

- Rust File▸New labels the new tab `Untitled-1` again (duplicate) rather than
  advancing to `Untitled-2`, when the session already restored an `Untitled-1`.
  The untitled counter is not advanced past the restored document's name. Cosmetic;
  the document itself is created correctly (fresh empty artboard, made active).
- All four native apps restore the previous session's document, so rectangles drawn
  in earlier smoke runs accumulate across launches. Expected (persistence), not a bug.
- Harness/window-management notes: `JAS_TITLE` is a substring match (`JasSwift`
  matches a bare `Jas`), so drive one app at a time and close others first; the Rust
  chromeless Chrome window is reliably drivable only right after it is opened
  (frontmost) — once other apps churn focus, synthetic clicks miss it. The user's
  own Chrome windows (e.g. WhatsApp) are correctly ignored by the `Jas` title match.
