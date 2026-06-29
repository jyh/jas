# Path B — Shared Widget-Layout Pass + Canonical Box Model (design)

**Status:** SHIPPED — DEFAULT-ON in all five apps (2026-06-29). The shared `layout_panel`
(Appendix A) is implemented byte-exact in all four native apps (Python
`workspace_interpreter/panel_layout.py` — shared, both Python apps import it; Rust
`jas_dioxus/src/interpreter/panel_layout.rs`; OCaml
`jas_ocaml/lib/interpreter/panel_layout.{ml,mli}`; Swift
`JasSwift/Sources/Interpreter/PanelLayout.swift`), each gated in-suite against the pinned
golden `test_fixtures/algorithms/panel_layout.json` (16 panel cases; seed panels `symbols` +
`opacity`; regen via `scripts/gen_panel_layout_fixture.py`). Flask renders from the pass but
does **not** gate the golden — it runs behavioral HTML tests only and is a non-gating
reference renderer (`TESTING_STRATEGY.md` §6), so the **byte-gate is the four native apps**.
The §6 five-app box-model review is RATIFIED (`PATH_B_BOXMODEL_REVIEW.md`; `char_width=10`).

Path B is **default-ON in all five apps** (commit `ffbe3e1a` dropped the `JAS_PATH_B` opt-in
flag; opt OUT with `JAS_PATH_B=0`, or `?path_b=0` in the Rust wasm build). It renders the **12
declarative panels** (align, artboards, boolean, brushes, character, concepts, magic_wand,
opacity, paragraph, properties, stroke, symbols). The **4 composite panels — color, gradient,
layers, swatches — are DECIDED permanently native** (2026-06-29): their interactivity is
panel-level wiring that the generic absolute renderer bypasses, and they depend on
`visible_when` conditional visibility the pass does not evaluate (an all-in attempt to put
color/gradient on Path B broke both — "interactivity dead, all sliders shown at once" — and
was reverted). The byte-gate still covers all **16** panels (the pass sizes the composites
identically as fixed boxes — A.5 v1.2); those 4 are *gated-but-rendered-native by choice*, not
a coverage gap. Behavior parity for the native composites is better served by a panel-behavior
seam corpus (resolved state + visibility), which is independent of Path B.

**Remaining in-scope capability gap:** `visible_when` / `bind.visible` (and `enabled_when`)
expression evaluation is not wired into the layout pass or render swap — `_visible_children`
honors only a literal `visible: false`, never an expression. So the three *rendered* panels
that use it (opacity, artboards, concepts) lay out and render their conditional widgets
unconditionally. This is **latent**: the default panel state mostly matches what gets shown,
which is why it passed the five-app visual sign-off; it surfaces only in non-default states
(toggled opacity thumbnails, artboard rename-in-place, a selected concept). The other
once-deferred algorithm bits are either DONE (foreach row/wrap + vertical flex-grow ship in
`_foreach`/`_column`) or composites-only and thus out of scope (2-D `type:grid` → swatches;
`max_width`/`max_height` clamps).

Design draft below; decisions locked 2026-06-27 (Template A; /12;
integer-px; Phase 0 + Rust render swap). Implements `TESTING_STRATEGY.md` §3
(Decision B) + §7 items #8 (panel computed-geometry byte-gate) and #9 (the
canonical box-model choice, gated behind a five-app golden-diff review). This is
the prerequisite for §7 item #7 (the Flask flex→absolute swap). Naming note: this
is a **vector illustration application**; no commercial product is named.

---

## 1. The problem, stated precisely

Panels render differently across apps **despite identical YAML** because the
interpreter computes *no* widget geometry — each app delegates intra-panel layout
to its own GUI framework. A survey of all five renderers found this is not a
cosmetic drift but **genuinely different layout algorithms** reading the same
fields:

| Field | Python / Qt | Rust / Dioxus | Swift / SwiftUI | OCaml / GTK3 | Flask / Bootstrap |
|---|---|---|---|---|---|
| **`col: N`** | raw Qt **stretch weights** (proportional, normalized by Qt — *not* /12) | Bootstrap **N/12** % | `usable·N/12`, **no overflow wrap** | GtkGrid `col_homogeneous`, span=N of 12 + filler | Bootstrap **N/12** % |
| **`flex: N`** | **binary** `Expanding` (N **ignored**) | CSS `flex:N` | only via a `fillsParent` flag | none — natural size | CSS `flex:N` |
| **gap default** | 0 | 0 | 0 | 0 (toolbar 2) | 0 (grid 2) |
| **container padding** | 0 | 0 | 0, but panel-wide `.padding(4)` | 0 | 0, `.app-panel` margin 4/2 |
| **min / max** | min only, **no max** | full min+max | absent (ad-hoc `.frame` literals) | min via `size_request` | CSS pass-through |
| **text width** | real Qt metrics | webview metrics | SwiftUI metrics | GTK metrics | browser metrics |
| **panel width** | dock 240, −12px scrollbar fudge | model | natural (hint ignored) | natural (hint ignored) | model |

The headline defects: **`col:N` means two different things** (Python proportional
weights vs everyone-else's /12), **`flex:N`'s magnitude is honored in 2 of 5
apps**, **overflow-wrap and min-width clamping exist in some apps and not others**,
and **all five measure text with framework fonts** — the single largest hidden
divergence. "Same YAML, four followers" was never true; there were five framework
layout engines that merely look similar. A spec exists (`transcripts/LAYOUT.md`,
Bootstrap-12 semantics) but the apps diverge from it and from each other.

---

## 2. The canonical box model (the decision surface for the five-app review gate)

Path B introduces a **single, language-neutral layout algorithm** that computes
widget rects `(x, y, w, h)` from the compiled panel tree. Because re-pinning to
one box model shifts already-shipped panels in **all five** apps, every choice
below went through the §7 #9 golden-diff review (`PATH_B_BOXMODEL_REVIEW.md`).

**RATIFIED 2026-06-28:** decisions 1, 2, 4, 6, 7, 8 LOCKED as written; **decision 5
LOCKED at `char_width = 10`** (one stub shared with `text_layout.json`; text overflow
is treated as authoring signal). Decision 3 (per-kind min-col floor) is deferred to a
v2 (not in the algorithm yet). Canonical values:

1. **Columns = Bootstrap-12 (`N/12`), not proportional weights.** 4 of 5 apps and
   `LAYOUT.md` already use /12; only Python uses raw Qt weights. Canonicalize on
   `col_w = round((avail − gap·(cols−1)) · N / 12)`. **Python is the one that
   moves.** Unused tracks (Σspan < 12) stay empty (Bootstrap convention), matching
   Rust/Swift today; OCaml's filler-label becomes unnecessary.
2. **Overflow wraps.** When cumulative `col` span exceeds 12, the row wraps to a
   new line (per `LAYOUT.md` §108-110). **Swift moves** (it overflows horizontally
   today).
3. **Min-column-width floor.** Narrow rows clamp columns to a per-kind minimum
   rather than shrinking to zero (`LAYOUT.md` §112-114). Swift/Python gain a floor.
4. **`flex: N` is weighted.** Leftover horizontal space (after fixed + intrinsic +
   col widths) distributes in proportion to `flex` weights. **Python moves** (drops
   binary `Expanding`); OCaml gains real distribution.
5. **Text/intrinsic width uses the deterministic stub measure**
   `width = len(text) · char_width`, **`char_width = 10.0`** — identical to
   `text_layout.json`. This is what makes rects portable without font metrics.
   Every text-bearing kind (`text`, `button`, label, `number_input` value, tabs)
   sizes through the stub. **All five apps move** here; it is the biggest visual
   shift and the reason the review gate exists.
6. **Integer-pixel arithmetic, round-half-up, at every step.** Forces byte-exact
   agreement across languages (no float tolerance needed — see §4).
7. **Defaults:** container `gap = 0`, container `padding = 0`, **panel outer inset
   = 4px** (formalizes Swift's `.padding(4)` / Flask's `.app-panel` margin), min/max
   honored with clamp order `intrinsic → min → max → flex-grow`.
8. **Canonical content width** `= dock.width − scrollbar_reserve` (propose
   `dock.width = 240`, `scrollbar_reserve = 12`, from Python's existing constants).

A companion **widget-kind → intrinsic-size table** gives every kind in
`CANONICAL_WIDGET_KINDS` a default `(w, h)` or a fill rule (e.g. `slider 100×12`,
`icon 20×20`, `number_input 45×W`, `separator ·×1`). The candidate numbers are the
per-app literals the survey already catalogued; pinning them is part of the gate.

---

## 3. The layout pass (pure function)

One pure function per language, authored in the style of `pane_edge_coord` /
`text_layout` and byte-gated:

```
layout_panel(node, avail_w, measure) -> [(path, rect)]
    # node    : a compiled panel/dialog subtree from workspace.json
    # avail_w : canonical content width (int px)
    # measure : the stub  len(s) -> len(s) * 10.0
    # path    : the element's tree path (the existing identity, e.g. [0,2,1])
    # rect    : {x, y, w, h} in int px, panel-relative
```

Recursive shape:

- **column container** — stack children vertically at `avail_w − padding`; `y +=
  child.h + gap`. Container height = Σ children + gaps + padding.
- **row container (no `col:`)** — place children left-to-right at intrinsic/fixed
  width; distribute leftover by `flex` weights; `gap` between; row height = tallest.
- **row with `col:N`** — the 12-column grid of §2.1–2.3 (width, wrap, min-floor).
- **grid** — `cols` equal columns of `round((avail_w − gap·(cols−1))/cols)`.
- **leaf widget** — `(w,h)` from the widget-kind table, text sized via `measure`;
  honor explicit `style.width/height/min/max`.

`visible: false` siblings occupy **zero** space (matches Python's
`_set_min_height_from_children` skip; otherwise the Color panel's mode-variant
rows inflate height ~5×). The function is total and deterministic: same
`(node, avail_w)` → identical `[(path, rect)]` in every language.

---

## 4. The corpus (recommended shape: Template A, pinned vectors)

Two shipping templates exist. **Recommend Template A** (the `pane_geometry.json`
pattern): a JSON array of cases asserted **in-suite** in each native app's own test
job, byte-exact against a pinned golden. It is simpler, needs no new CLI/driver
wiring, and — because §2.6 makes the math integer-exact — needs **no float
tolerance**. (Template B, the `text_layout.json` roundtrip-differential via
`scripts/cross_language_algorithms.py`, is the fallback *only* if fractional widths
prove unavoidable; it costs five files in lockstep and a 1e-4 tolerance.)

Fixture `test_fixtures/algorithms/panel_layout.json`:

```json
[
  { "name": "stroke_panel@240",
    "function": "layout_panel",
    "args": { "panel": "stroke", "avail_w": 228, "char_width": 10.0 },
    "expected": [ { "path": [0],     "rect": {"x":0,"y":0,"w":228,"h":24} },
                  { "path": [0,0],   "rect": {"x":0,"y":0,"w":80, "h":20} } ] }
]
```

- **Source of truth = `workspace/workspace.json`** (compiled), not the YAML — regen
  with `python -m workspace_interpreter.compile workspace/ workspace/workspace.json`
  before pinning, or the corpus freezes stale layout.
- Keep an `expected` golden **and** a Python unit test asserting against it, so the
  pin is a true anchor (not just app-0-vs-app-N agreement).
- Wire the in-suite consumer into all four `cross_language_test` modules exactly
  where `pane_geometry` is consumed (Python `:1989`, Rust `:4053`, OCaml `:2991`,
  Swift `:1599`); mirror the explicit dispatch — avoid the silent `_`/default
  catch-all that the survey flagged.

This also subsumes §7 #8 (the panel computed-geometry byte-gate *is* this corpus)
and composes with §7 #1/#4: the widget-kind → size table is the same vocabulary as
`CANONICAL_WIDGET_KINDS`, and a resolved-widget-tree snapshot is a projection of
`[(path, rect, kind)]`.

---

## 5. Rollout (gate-first, then migrate in dependency order)

**Phase 0 — spec + gate, no app consumes it yet.** Author the layout pass + the
`panel_layout.json` corpus + the widget-kind size table in all four native langs;
get the gate green. At this point the algorithm is *proven equivalent* but nothing
renders from it — zero visual risk. This is the safe foundation commit.

**Phase 1 — the five-app review gate (§7 #9).** Render each app from the pass
behind a flag; diff against current panels across all five; the box-model values in
§2 are ratified or adjusted here. Nothing ships until this review passes.

**Phase 2 — migrate, easiest first** (each app already has the hook noted):
1. **Rust** — `style.position:{x,y}` → `position:absolute` already works and
   parents auto-promote to `relative` (`renderer.rs:4723`, `:4852`). Suppress the
   flex/Bootstrap path; emit rects. Lowest effort.
2. **Flask** — already absolute-positions panes + `style.position` children; pure
   consumer, non-gating visual reference (this *is* §7 #7).
3. **Swift** — drop-in `CanonicalRectsLayout: Layout` (the `Layout` protocol is
   already used by `Bootstrap12Layout`); force each leaf `.frame(w,h)`.
4. **OCaml** — `GPack.fixed` + `#put ~x ~y` already proven for fill/stroke +
   color markers; build the panel as one fixed and place leaves.
5. **Python** — hardest: must abandon Qt layouts for panel internals
   (`setGeometry` per widget, disable `setWidgetResizable`). Do last.

Each migration is verified by the existing per-app manual suites at the panel level
plus the (now-green) byte-gate; once a panel's layout is byte-gated, retire its
manual cross-app parity row (the ritual just added to `MANUAL_TESTING.md`).

---

## 6. Open decisions (need sign-off before Phase 0)

1. **Corpus template** — Template A (pinned, in-suite, integer-exact) as
   recommended, or Template B (roundtrip differential, tolerance)?
2. **`col:N` canonicalization** — Bootstrap /12 (recommended; Python moves) vs
   keep proportional weights (everyone-else moves)?
3. **Box-model values** (§2.5–2.8: `char_width=10`, panel inset 4, dock 240,
   scrollbar reserve 12, gap 0) — ratify as the starting point for the Phase-1
   review, or pre-adjust any?
4. **Scope of the first commit** — Phase 0 only (spec + gate, no rendering change),
   or Phase 0 + the Rust render swap together?

---

## 7. Dependencies / sequencing

- **Unblocks:** §7 #7 (Flask swap = Phase 2.2), §7 #8 (= the corpus in §4).
- **Composes with:** §7 #1 (widget-kind vocabulary → the intrinsic-size table) and
  §7 #4 (resolved-widget-tree snapshot → a projection of the rect list). Doing the
  compile-time widget-kind validator (#1) first gives the size table a validated
  key space.
- **Does not touch** the document model, op-log, or tool seams — purely additive at
  the panel-render layer.

---

## Appendix A — `layout_panel` algorithm contract (v1)

This is the **byte-exact contract** every language implements. **All arithmetic is
integer**; there is no float anywhere, so the four outputs are byte-identical and
the corpus needs no tolerance. Decisions locked 2026-06-27 (Template A; Bootstrap
/12; integer-px).

### A.1 Inputs / outputs

```
layout_panel(panel_node, avail_w: int) -> [ {path: [int], rect: {x,y,w,h: int}} ]
```

- `panel_node` is a compiled panel object from `workspace.json`: `{type:"panel",
  content: <root>}`. Layout starts at `panel_node.content`, which has **path `[]`**;
  its `children[i]` has path `[i]`, recursively. A `text` node's string `content`
  is **not** a child and does not advance the path.
- `avail_w` is the panel content width in px (canonical `dock.width − 12`).
- Output is the node list in **pre-order** (parent before children), each node's
  rect **panel-relative** (absolute within the panel, not parent-relative).

### A.2 Node classes

- **Container** = `type ∈ {container, row, col, panel}`. `layout` defaults to
  `column`, except `type:"row"` defaults to `row` and `type:"col"`/`panel` to
  `column`.
- **Leaf** = everything else (sized by the widget-kind table, A.5).
- A child with `visible == false` (literal) occupies **zero** space and is omitted
  from output. `visible_when` expressions are treated as visible in v1 (deferred).

### A.3 Box reads (per node)

- `gap = int(style.gap or 0)`.
- `padding` → `(top,right,bottom,left)` via CSS 1/2/4-value shorthand, each `int`,
  default 0. (1 val → all; `"v h"` → t=v,r=h,b=v,l=h; 4 vals → CSS t,r,b,l.)
- `inner_x = x + pad.left`, `inner_y = y + pad.top`, `inner_w = avail_w − pad.left − pad.right`.

### A.4 Container layout

Dispatch on resolved `layout` and whether any child carries `col`:

**Column** — block stack at `inner_w`:
```
cy = inner_y
for each visible child c at path+[i]:
    (cw, ch) = layout_node(c, inner_x, cy, inner_w)   # child fills width: avail = inner_w
    cy += ch + gap
content_h = cy - gap - inner_y   (if any child else 0)
```
A child's rect width = the avail it was given (`inner_w`) for containers and
**fill-leaves** (separator, placeholder, slider, inputs); intrinsic width for
**inline-leaves** (text, button, icon, icon_button, checkbox), left-aligned at
`inner_x`. (See A.5 `fill` column.)

**Flow row** (no child has `col`) — left-to-right:
```
fixed = Σ child intrinsic widths (+ gaps);  leftover = inner_w − fixed
distribute leftover to children with style.flex>0 in proportion to weight:
    share_k = (leftover * w_k) / Σw   (integer floor); give remainder px to the
    earliest flex children, one each, left to right.
row_h = max child height
place each child at cx (running), vy = inner_y + (row_h − child_h)/2  (int floor);
cx += child_w + gap
content_h = row_h
```

**Grid row** (≥1 child has `col`) — Bootstrap-12, flush (gutter 0):
```
for each child: span = int(col or 1)
wrap into lines so each line's Σspan ≤ 12 (a child whose span would overflow
    starts a new line)
for each line:
    cx = inner_x
    for each child with span N:
        cell_w = round_half_up(inner_w * N / 12)
                = (2*inner_w*N + 12) / 24      # integer division — byte-exact
        layout child into the cell at avail = cell_w (child fills cell: w = cell_w)
        place child at cx; cx += cell_w + gap
    line_h = max child height in line;  vy per child = line_y + (line_h-child_h)/2
    line_y += line_h + gap
content_h = Σ line_h + gaps
```

`round_half_up(inner_w*N/12)` via the integer form `(2·inner_w·N + 12) / 24`
(truncating division) is mandatory and identical in all four languages.

### A.5 Widget-kind intrinsic-size table (v1 — the kinds in the seed corpus)

`text_w(s) = len(s) * 10` (the `char_width=10.0` stub, exact). `label` text uses
the same. Heights and fixed widths are canonical px:

| kind | width | height | fill in column? |
|---|---|---|---|
| `text` | `text_w(content)` | 20 | no (inline) |
| `button` | `text_w(label)+16` | 24 | no (inline) |
| `checkbox` | `16 + 4 + text_w(label)` | 20 | no (inline) |
| `icon_button` | 24 | 24 | no (inline) |
| `icon` | 20 | 20 | no (inline) |
| `select` | given avail (fill) | 20 | yes |
| `number_input` | given avail (fill), else 45 | 20 | yes |
| `text_input` / `length_input` | given avail (fill) | 20 | yes |
| `slider` | given avail (fill), else 100 | 12 | yes |
| `placeholder` | given avail (fill) | 40 | yes |
| `separator` | given avail (fill) | 1 | yes |

`fill` leaves take the avail width handed to them (so in a grid cell they = cell_w,
in a column they = inner_w). Inline leaves take intrinsic width, left-aligned. The
leaf's resolved width is used directly (so `style.width` applies even to fill kinds).

**v1.1 broadening (2026-06-28)** — added kinds so the corpus covers all 13 panels that
use no composite/data-driven widget (everything except color / gradient / layers):

| kind | width | height | fill? |
|---|---|---|---|
| `toggle` | `16 + 4 + text_w(label)` | 20 | no (inline) |
| `color_swatch` | 16 | 16 | no (inline) |
| `combo_box` | given avail (fill), else 80 | 20 | yes |
| `icon_select` | given avail (fill), else 80 | 20 | yes |
| `spacer` | given avail (fill), else 0 | 0 | yes |

`spacer` additionally gets an **implicit `flex` weight of 1** in a flow row when it has
no explicit `style.flex`, so it consumes leftover space.

**Dimension resolution** — `style.width` / `style.height` / `style.min_width` resolve via
`resolve_dim(value, avail)`: a number truncates toward zero; `"N%"` is `(avail*N)//100`
(integer; ignored when `avail <= 0`, e.g. heights, which have no reference); a bare
numeric string is that int; anything else (`"auto"`, junk) is ignored (falls back to the
kind default / intrinsic). `width`/`min_width` resolve against the leaf's avail width;
`height` resolves with `avail = 0` so `"%"` heights are ignored.

**v1.2 broadening (2026-06-28) — composite/data-driven widgets, to reach 16/16 panels.**
The remaining three panels (color / gradient / layers) are added by placing each composite
widget as a **canonical fixed box** (fill width); the widget renders its own internals, and
its **data-driven rows are a separate concern** (a `foreach` expansion or a `tree_view`'s
document rows need a data fixture, not the static panel YAML). Added as fill kinds:

| kind | height | fallback width |
|---|---|---|
| `color_bar` | 24 | 0 (fill) |
| `fill_stroke_widget` | 44 | 50 |
| `gradient_slider` | 24 | 0 (fill) |
| `gradient_tile` | 24 | 32 |
| `dropdown` | 20 | 80 |
| `tree_view` | 200 | 0 (fill) |

A `foreach` node is a container with a `do` template and no static `children`. The pass now
expands it with a data scope (Appendix B) — an empty/absent source lays out empty (the no-data
state), deterministic.

**Correction (2026-06-29):** an earlier draft claimed these composite panels have "no
`visible_when`". That is wrong — color and layers use `bind: { visible: <expr> }`, and the
in-scope opacity/artboards/concepts panels do too. The pass does **not** evaluate those
expressions (it lays out every child), so conditional visibility is a real deferred capability,
not an absent one (see A.6 and the Status block).

**Coverage note (updated 2026-06-29):** the cross-app byte-**gate** covers **16/16 panels**
(four native apps; Flask non-gating). Path B *rendering* is default-on and covers the **12
declarative panels**; the 4 composite panels (color/gradient/layers/swatches) are permanently
native by decision (Status), so they are gated-but-rendered-native. `foreach` row/wrap +
column data expansion now render live in all apps. Genuinely deferred: `visible_when` eval
(in-scope — opacity/artboards/concepts), and the composites-only 2-D `type:grid` and `max_*`
clamps.

---

## Appendix B — `foreach` data-expansion + vertical flex (v2 contract)

The path to **default-on**: lay out the data-driven lists (7 panels use `foreach`)
and let them fill the dock. This couples the layout pass to the **expression
evaluator + a data scope** — each language uses *its own* expr evaluator, whose
agreement is already guaranteed by the expression conformance corpus, so the
byte-gate holds.

### B.1 Signature

```
layout_panel(panel_node, avail_w, avail_h=0, ctx={}) -> [...]
```

- `ctx` is the data scope (`state` / `panel` / `data` / `active_document`
  namespaces) — a plain dict, the same shape the expr evaluator consumes. The
  corpus carries `ctx` per case (a deterministic data fixture).
- `avail_h` drives vertical flex; `0` = content-height (no vertical flex).

### B.2 Text bindings

A `text` `content` (and `button`/`checkbox`/`toggle` `label`) is resolved with
`evaluate_text(value, ctx)` before measuring: `width = len(resolved) * 10`. A
literal (no `{{}}`) passes through unchanged, so non-bound panels are
byte-identical; a bound `"{{sym.name}}"` is measured at its resolved value.

### B.3 `foreach`

A container with `foreach: {source, as}` + a `do` template expands:
`items = evaluate(source, ctx)` (take `.value` if the result wraps one; non-list
→ empty). For each item `i`: child scope `= ctx + { as: {…item, _index: i} }`;
lay out `do` at path `[…foreach_path, i]`. **v1 stacks column-wise** (the layout
every foreach list uses); row/wrap foreach is deferred. An empty/absent source →
zero rows (the no-data state) — deterministic.

### B.4 Container height + vertical flex

A container's explicit `style.height` (via `resolve_dim`) overrides the
content-derived height (so a `height: 24` row is exactly 24). A **column**
distributes `avail_h − natural_height` to children by `flex` weight (integer
floor + earliest-child remainder), bumping the flex child's rect height; a
`spacer` gets an implicit `flex` weight of 1. This makes a `foreach` list
(`flex: 1`) grow to fill and pins a trailing footer to the bottom.

### A.6 Deferred in v1 — status updated 2026-06-29

**Now implemented** (were deferred when this section was written): `foreach` row/wrap layout
(`_foreach`) and vertical `flex` grow (`_column` distributes `avail_h − natural` to
flex-weighted children when `avail_h > 0`).

**Still deferred:** `visible_when`/`bind.visible`/`enabled_when` expression evaluation
(`_visible_children` honors only a literal `visible: false`); `max_width`/`max_height` clamps;
2-D `grid` (`type:"grid"` with `cols`, distinct from the Bootstrap col-span the row grid
already handles). Of these, only `visible_when` is **in-scope** — it is used by the rendered
opacity/artboards/concepts panels (see Status); `max_*` and 2-D grid are needed only by the
now-permanently-native composite panels, so they are out of scope unless that decision is
revisited.
