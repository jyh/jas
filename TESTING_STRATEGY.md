# UI Verification Strategy

**Status:** decisions locked 2026-06-21. **Relationship to other docs:** this is the
umbrella over `CROSS_LANGUAGE_TESTING.md` (the byte-gate machinery + canonical JSON),
`MANUAL_TESTING.md` (the per-component manual procedure), `OP_LOG.md` (the operation
spine), and `ARCH.md` (the MVC seams). Where those describe *mechanisms*, this describes
*what gets verified at which layer, and why.* A naming note (as everywhere): this is a
**vector illustration application**; we never name a commercial product.

---

## 1. The doctrine

> **The shared *executable artifact* is the byte-truth, gated cross-app. The
> GUI-framework layer is verified per-app or by reference rendering — never as
> cross-app pixels. Only the irreducible residue — anti-aliasing / fonts / gamma,
> framework layout pixels, focus / IME, OS-native chrome, and key→action binding —
> falls to per-app goldens or manual testing.**

Every decision below is the same move: take something currently "verified by eyeballing
five framework renderings" and push it down to a shared, deterministic, byte-comparable
artifact — the way `document_to_test_json` and the operations corpus already work. A
GUI framework (Qt / GTK / AppKit / Dioxus / browser) is treated as an untrusted
*renderer* of a trusted *artifact*, not as a source of truth.

### The layered verification model

| Layer | Instrument | Cross-app byte-gate? | Status |
|---|---|---|---|
| Document model | `document_to_test_json` | yes | exists |
| Operations | `op_apply` + `checkpoint_equivalence` | yes | exists |
| Expression evaluation | conformance corpus | yes | exists |
| Tool gestures / input | gesture fixture corpus @ the `CanvasTool` seam | yes | **new — §5** |
| Panel / menu / dialog actions | action corpus @ `dispatch_action` / `run_effects` | yes | **new/generalize — §5** |
| Canvas drawing | canonical **display list** | yes | **new — §2** |
| Panel widget layout | **Path B** shared layout pass | yes | **new — §3** |
| Chrome structure | workspace / menu / toolbar / widget-tree JSON | yes | mostly exists — §4 |
| Per-app pixel residue | per-app raster goldens / geometry introspection | no (intra-app only) | new, gated behind a real bug |
| Irreducible | manual (focus, IME, OS chrome, key binding, visual) | — | the manual floor — §5 |

A property is verified at the **lowest deterministic layer that can express it**. A
screenshot is the instrument of last resort, used only for what no shared artifact can
encode, and then only **per-app** (an app vs. its own past), never cross-app.

---

## 2. Decision A — Canvas sameness = display-list equivalence

**"The canvas drawings look the same" is formally defined as: all apps emit the same
canonical display list — NOT the same pixels.**

The display list is the painter analog of `document_to_test_json`: an ordered,
rasterizer-agnostic vector op stream — path ops (`move`/`line`/`curve` in model coords),
resolved `fill`/`stroke`/`cap`/`join`/`miter`/`dash`/**`fill-rule`**, opacity, a 6-float
affine transform from the shared `Transform` (never the framework matrix), plus
overlay/chrome primitives (selection box, handles, artboard fills/borders/labels/bleed,
tool previews). Every number routes through the existing `_fmt` (4-decimal) and every
color through `_color_json {r,g,b,a}`, so determinism is inherited, not re-earned.

- **Why a display list and not SVG-export diff:** SVG export is a *separate emitter* and
  draws none of the overlays/handles/chrome — it tests the emitter, not the painter. The
  display list captures exactly what the painter draws, including the chrome where
  "looks wrong" bugs live.
- **Why not pixels:** `ARCH.md` line 4-5 — "same observable semantics … not the same
  pixels." Qt / Cairo / CoreGraphics / browser differ in AA, font rasterization, and
  gamma; cross-app pixel parity is impossible *and* undesirable. The residual
  (AA / fonts / gamma) is the legitimate per-platform boundary (`NATIVE_BOUNDARY.md`).

**Build:** document arm reuses `document_to_test_json` (the genuinely byte-identical
serializer — **not** `document_to_svg`, whose existing gate compares parsed-back JSON,
not SVG bytes). Chrome/overlay arm is a thin data-extraction at each draw site (the
geometry — `control_points`, `bounds`, bleed rects — is already computed there). Flask's
canvas already *is* a display list (`engine/canvas.mjs` `renderDocumentLayer` /
`renderSelectionLayer` / `renderOverlayLayer` return SVG strings, incl. overlays).
Prototype the op vocabulary in Python (duck-typed `QPainter` recorder). Defer a true
painter-recorder (gradient/blend/mask pixel capture) until a real overlay bug needs it.

**Residual:** per-app raster goldens (intra-app, never cross-app), gated behind a proven
painter bug, cover the pixel residue.

---

## 3. Decision B — Panel layout via a shared layout pass (Path B)

**Panels render wrong despite identical YAML because the interpreter computes no
geometry** — every app delegates intra-panel widget layout to its framework
(Qt / GTK / AppKit / Dioxus / CSS), including 3+ independent Bootstrap-12
reimplementations. "Same YAML" therefore does not yield same layout; there was never one
layout truth and four followers, only five framework layout engines that happen to look
similar — the exact drift surface the prime directive exists to kill.

**Path B:** introduce a shared, language-neutral **layout pass** that computes widget
rects `(x, y, w, h)` from the panel YAML, consumed by all apps and byte-gated cross-app —
authored in the same style as the expression / `op_apply` / `text_layout` corpora, with a
**stub measure** (e.g. `char_width = 10.0`, exactly as `text_layout` already stubs it) so
it is deterministic. This makes all four panel-bug classes — *widget missing*, *widget
misplaced*, *panel too wide*, *text box too small* — catchable as cross-app DATA instead
of per-app pixels.

- **This is a five-app behavior change.** The canonical box model (padding / margin /
  gap / flex-grow / min-max resolution) becomes truth for Qt / GTK / AppKit / Dioxus
  too, so re-pinning may shift already-shipped panels everywhere. **Gate the box-model
  choice behind a golden-diff review across all five renderers.**
- The shared geometry pass today pins only **pane** edges
  (`test_fixtures/algorithms/pane_geometry.json`, `pane_edge_coord`). The **widget-level**
  pass is the new work; it is the prerequisite for the Flask swap (§6) and the panel
  computed-geometry byte-gate.

---

## 4. Chrome data gates (structure, not pixels)

Panels / menus / toolbar chrome is computed in shared hand-written code, so its *model*
is snapshot-able as data even where its *pixels* are framework-rendered.

- **Panel layout model** — `workspace_to_test_json` already gates resolved pane geometry
  cross-app (`default_layouts.yaml` declares pane rects + dock groups as data). Widen
  fixtures: load each named preset; assert snap targets.
- **Widget presence / kind** — add a **canonical widget-kind vocabulary** (today there is
  none — no panel/widget schema, the compiler never validates `type:`, and each app
  hardcodes its own dispatch table), a compile-time validator, and a **resolved-widget-tree
  snapshot** (`{type, id, binding, visible, dispatched_kind_or_placeholder, col,
  declared_style}` per panel) diffed cross-app. This closes the *widget-missing* class as
  data — the missing widget surfaces as a recorded `placeholder`, no pixels needed.
- **Menus / toolbar** — `menu_structure_json` and `toolbar_structure_json` gates exist but
  currently gate **stale mirrors** (see §7). Re-source them from the real menu/toolbar and
  from compiled `menubar.yaml`.

What still needs per-app pixels: final flow *position*, content *fit*, theming colors,
glyph rendering (checkmarks, icons), native popups. These are the layer where logic
regressions almost never originate.

---

## 5. Input injection + the manual floor

**Synthetic input for automated testing is feasible and largely already exists.** The
apps decouple the framework event from the logic, exposing two clean injection seams:

- **(A) the `CanvasTool` state machine** (`on_press` / `on_move` / `on_release` /
  `on_key`) with a stub `ToolContext` — already driven headlessly in every app.
- **(B) `dispatch_action` / `run_effects`** for panel / menu / dialog actions.

The existing operations corpus injects *below* both (at the op level).

**Recommendations, ranked:**

1. A shared cross-language **gesture fixture corpus** at seam A — *capture* real sessions
   rather than hand-author; build the document arm on `document_to_test_json`; eliminate
   float non-determinism by pre-resolving `doc_x`/`doc_y` or quantizing input coords.
2. A shared **action corpus** at seam B — generalize the existing eye-demo +
   `production_route` tests into a corpus.
3. Refactor keyboard / menubar resolution into pure `key→action` functions (today
   framework-fused, ~0 tests).
4. A deterministic hit-test fixture layer (unlocks selection-family gestures).
5. A handful of per-app raw-event smoke tests through a real run loop.

**The manual floor** — what injection (and any shared artifact) fundamentally cannot
verify, kept in the manual suite: raw event + coordinate conversion, real hit-testing
against rendered geometry, key→action / menu-id→command **binding**, focus / tab order /
responder chain, native value-commit semantics, IME / text editing, and visual / overlay /
cursor / theming output. `MANUAL_TESTING.md` should add an explicit "injection floor"
section and a ritual: once a behavior is byte-gated by a shared corpus, retire its manual
cross-app parity test.

---

## 6. Flask re-charter

Flask is **kept**, but **demoted from "the layout/look-and-feel source of truth" to the
thin, non-gating reference renderer of the shared artifacts, plus a render-time genericity
signal.** "Flask's CSS is the truth" was never byte-checkable (it emits flex/Bootstrap and
lets the browser decide rects), which is part of why it drifted.

- Flask becomes a **consumer** of the Path B rects — `renderer.py:474-540` swaps
  flex/Bootstrap emission for absolute-positioned divs at the shared pass's computed rects
  (it already does this for floating panes). **Fed the stub measure**, so the human
  reference and the byte-gate never diverge by browser fonts.
- Flask is **never a pixel/measure oracle** (browser CoreText/HarfBuzz differs from the
  stub and from Qt/Cairo) and **never an interactive-parity target** (the months-long
  `FLASK_PARITY.md` buildout is declined — every recent feature shipped "4 native apps
  only").
- Flask's genericity role is a **render-time signal that complements** the existing static
  lint (`scripts/genericity_check.py`, the `genericity:` job in `.github/workflows/test.yml`)
  — it is not "the enforcer."
- **Exit criterion:** if Path B's box model forces a `renderer.py` rewrite anyway,
  re-evaluate retiring Flask — a ~200-line SVG-from-rects viewer would give the same
  human-viewable reference at far lower maintenance. The reason to keep Flask is that its
  structural shell already exists, so marginal keep-cost is low.

**`develop-first` rule amended.** The old "develop new features in the flask app first"
rule is dead — even spec/structure lands as a shared foundation commit + conformance
corpus, with Flask getting a downstream reshape, because interactive features need the
native document model Flask lacks. Replacement: **author the generic spec and its
cross-language conformance corpus first (language-agnostic, golden-pinned); the native
apps implement against it; Flask consumes it for visual reference; interactive behavior
lands in the native apps.** Native propagation order is unchanged: Rust → Swift → OCaml →
Python. (Reflected in `CLAUDE.md`.)

---

## 7. Found issues + action items

Surfaced during this analysis; with sequencing.

**Status — verified 2026-06-27 (where each item stands):**
1 ◐ live bug fixed + widget-kind vocabulary gate on `main`; compile-time validator
+ per-app dispatch-coverage assert still open ·
2 ◐ toolbar golden re-sourced + live-gated (13 slots / 29 tools); dblclick
options-destination not yet captured ·
3 ✓ menu golden re-sourced (now includes View) ·
4 ○ not started ·
5 ◐ gesture corpus shipped; action corpus thin (1 action); modifier note re-scoped
(see item) ·
6 ✓ done ·
7 ○ unblocked (Path B pass now exists) but Flask swap not yet done ·
8 ◐ panel computed-geometry byte-gate **landed in all 4 native apps** (Path B Phase 0:
`layout_panel` + `test_fixtures/algorithms/panel_layout.json`, byte-exact; see
PATH_B_DESIGN.md) — broadening beyond the 2 seed panels (symbols, opacity) pending ·
9 ◐ canonical box model **drafted** (PATH_B_DESIGN.md §2) pending the five-app review ·
10 ✓ done.

**Ships now (no dependencies):**
1. **Widget-kind vocabulary + coverage gate** — fixes the live bug where `magic_wand.yaml`
   declares tolerance inputs as bare `type: number`, handled by **no app**, so all five
   render a placeholder instead of a number input. Add the vocabulary, the compiler
   validation, and the cross-app coverage assert.
2. **Re-source the stale `toolbar_structure.json` golden** — frozen at 18 tools ending at
   `lasso`; omits magic_wand / ellipse / paintbrush / blob_brush / scale / rotate / shear /
   hand / zoom / eyedropper / artboard. The gate is green only because every app mirrors
   the stale literal. Re-derive each serializer from the real toolbar; add
   `has_alternates`, icon-name id, and dblclick options-destination.
3. **Re-source the drifted `menu_structure.json` golden** — currently `[File, Edit, Object,
   Window]`, missing View, while `menubar.yaml` declares View and all apps build it.
   Re-point to compiled `menubar.yaml`.
4. **Resolved-widget-tree snapshot** + **Flask render-all-panels CI gate** (render every
   panel/dialog from `workspace.json`, fail on error/missing-kind).
5. **Input-injection gesture + action corpora** (§5 recs 1–2) — **gesture corpus shipped**
   (10 gestures, gated in all 4 native apps); **action corpus is a thin foundation** (1 of
   ~13 production actions). The `ctrl=meta=False` pointer-payload note was **mis-scoped**:
   **all four** native apps hardcode `ctrl`/`meta` to `false` on pointer events
   (`yaml_tool.py:304`, `yaml_tool.rs:245`, `YamlTool.swift:275`, `yaml_tool.ml:1344`), and
   all four carry the real flags on the *keyboard* path — so it is a consistent 4-app state,
   not a Python divergence, and no canvas-tool YAML reads pointer `ctrl`/`meta` yet (the only
   `event.meta` consumers are in `artboards.yaml`, a panel-list click at seam B, not the
   pointer seam). Completing the modifiers is therefore a forward-looking **4-app** increment
   (thread the real flags at each framework boundary + a per-app payload test), to do when a
   canvas tool first needs Cmd/Ctrl-click — not a Python-only one-liner. Half-fixing Python
   alone would *create* the cross-app divergence the prime directive exists to prevent.
6. **`MANUAL_TESTING.md` cleanup** — injection-floor section; distinguish key-binding from
   action-effect; single-source the Flask-inclusion rule; retire-manual-parity-when-gated
   ritual.

**Gated on Path B's widget-rect pass existing:**
7. The Flask flex→absolute-div swap (§6).
8. The panel computed-geometry byte-gate.

**Five-app review gate:**
9. The canonical box-model choice (§3) — re-pins shipped panels everywhere.

**Process / hygiene:**
10. The `project_flask_genericity_leaks` memory was a stale-reference false-confidence
    trap (it re-flagged an already-fixed `swatch_libraries` leak). Discipline: re-verify
    any "Flask does X" claim against current code before acting; Flask and its docs lag.

---

## 8. Open questions

- **Box model** — which padding / margin / gap / flex-grow / min-max resolution does Path
  B canonicalize, and how much do shipped panels shift when re-pinned?
- **Flask in CI** — formally drop the JS engine's interactive-parity claim (and correct
  `engine/README.md`), or wire Flask's canvas to the same SVG golden the natives gate on?
- **Per-widget rects** — the shared geometry pass pins only pane edges today; the
  widget-level pass + its corpus is unbuilt.
- **Gesture corpus determinism** — supply pre-resolved `doc_x`/`doc_y`, or quantize and
  rely on the 4-decimal `_fmt` rounding?
- **Hit-test fixtures** — a fixture-declared `(x,y)→path` table (portable, a model of
  hit-testing) vs. each app's real bounds-based `hit_test` (more faithful, must agree
  exactly).
- **Text overlay handles** — text selection-bbox / handle coords derive from
  framework-specific glyph metrics, so they are not cleanly portable; gate cross-app with
  tolerance, or fall to per-app?
