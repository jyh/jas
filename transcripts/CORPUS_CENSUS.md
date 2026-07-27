# THE CORPUS CENSUS

**Equivalence blind spots between the two active ports.**
Rust `jas_dioxus/` ↔ Swift `JasSwift/`, with `workspace_interpreter/` as the live blocking reference.

Compiled 2026-07-26 from six domain sweeps, **then re-verified against `HEAD = cd8723a0`.**
Read-only: nothing under `/Users/jyh/projects/claude/jas` was modified, added, or committed.

---

## 0. READ THIS FIRST — the sweeps' baseline is 89 commits stale, and it changes the headline

Every one of the six domain sweeps censused `284fdca1` (or, for the boolean sweep, a worktree).
`git rev-list 284fdca1..HEAD --count` = **89**. Two whole waves landed in between — **COLORTIERS**
(23 commits) and **FILLRULE** (18 commits, now merged, no longer in a worktree).

**The brief's own premise is now false, and it is the most important correction in this document.**

The brief says: *"it survived because `test_fixtures/algorithms/` has 25 families and not one for
colour."* The colour sweep repeated it: *"25 families. NONE is colour. Confirmed by listing."*
That was true at the baseline and is **not true at HEAD**:

| | baseline `284fdca1` | HEAD `cd8723a0` |
|---|---|---|
| files in `test_fixtures/algorithms/` | 25 (`git ls-tree --name-only … \| wc -l`) | **26** (`ls \| wc -l`) |
| colour-named families | **0** | **1 — `color_convert.json`** |
| vectors in that family | — | **58** — the largest family in the repo |

`color_convert.json` is wired into **both** roundtrip binaries — `algorithm_roundtrip.rs:72`
→ `run_color_convert` (`:234`) and `AlgorithmRoundtrip.swift:51` → `runColorConvert` — is registered
in the runner at `scripts/cross_language_algorithms.py` under the **`exact`** strategy (no tolerance
to hide in), and its goldens are **derived from the spec formulas** by
`scripts/derive_color_convert_goldens.py`, not captured from a port. Its `_doc` names the triggering
bug by number: *"COLORTIERS, 2026-07-26: Swift committed 664040 where Rust committed 664141."*

So: **the specific hole that triggered this census has been closed, by the wave named after it.**
Anyone planning work off the sweep JSON alone would have re-fixed a fixed bug. Four rounds of this
feature shipped claims wider than the code; this document's first duty is not to be the fifth.

### The honest size of the blind spot

Not "colour is unpinned" — that is last week's finding. The blind spot at HEAD is **narrower,
better-shaped, and still large**, and it has three distinguishable parts:

1. **A live, verified, corpus-green divergence cluster in booleans** (options default × collapse
   formula × `CommonProps` rebuild) that changes the *committed document* on one click, plus
   **Swift's generic dispatcher registering 4 of 9 boolean verbs.**
2. **A whole subsystem — view state — with literally zero coverage**: no fixture anywhere in
   `test_fixtures/` sets `zoom_level` or `view_offset`, so every harness runs at the identity view
   where screen↔doc is algebraically the identity. Three verified divergences already live there.
3. **Two vacuous families and one misleading one.** `flatten.json` (3 vectors, **zero** curve
   commands — counted below) and `fit_curve.json` (7 vectors, all degenerate names) are registered,
   green, and cover their functions' degenerate skirt only. `hit_test` gates 7 scalar predicates
   while the element-level predicates that decide what the marquee selects are in **neither**
   roundtrip binary. **A vacuous family is worse than a missing one, because the manifest reads as
   covered** — and `scripts/corpus_manifest.json`'s `known_gaps` is `[]` (verified), so the manifest
   currently asserts no gaps at all.

Mechanically: **26 family files, 334 total vectors, 16 families driven by the cross-language runner**
(both roundtrip binaries dispatch the same 16 — symmetric, verified by extracting and sorting both
dispatch tables). The other 10 files are gated by in-port unit tests over the shared fixture, which
is a legitimate Rust==Swift gate by a different mechanism — `panel_layout`, `panel_widget_tree`,
`pane_geometry`, `menu_state`, and the six `tspan_*` families. **Method for every count in this
document is shown inline; nothing is estimated.**

### How to read the evidence markers

- **`[V-HEAD]`** — I opened the code at `HEAD = cd8723a0` during this compilation and confirmed it.
  Trust these.
- **`[V-BASE]`** — verified by a sweep at `284fdca1` with file:line, **not re-verified at HEAD.**
  89 commits landed; line numbers have certainly moved and some rows may be closed. Treat as a
  strong lead requiring a 5-minute re-check before work is scheduled.
- **`[SUSPECT]`** — reasoned from reading but not executed, or explicitly flagged unconfirmed.
- **`[MEASURED]`** — a sweep compiled and ran both languages to produce the number quoted.

---

## 1. THE RANKED TABLE

Ranked by **(likelihood of silent divergence) × (user-visible consequence)**. A latent divergence in
an unreachable path ranks below a live one in a common gesture. Consequence weighting: *committed
document* > *committed selection/state* > *view* > *crash* (loud) > *latent*.

| # | Primitive | Rust site | Swift site | Cov. | Risks | Reach | Evidence |
|---|---|---|---|---|---|---|---|
| **1** | `BooleanOptions.remove_redundant_points` default: **`false` vs `true`** | `document/controller.rs:129` (`false`) | `Geometry/LiveElement.swift:91` (`= true`) | PARTIAL | R6 R4 | 1 click; also Swift journal replay | **[V-HEAD]** both lines read at HEAD; `workspace/state.yaml` spec default is `false`, so Swift contradicts the spec |
| **2** | `collapse_collinear_points` — same algebra, cancellation-prone Swift form | `document/controller.rs:70` (diff-of-differences) | `Geometry/LiveElement.swift:103` (5 raw-coord products) | NONE | R1 R4 | every Swift boolean output ring today | **[V-BASE]** expanded by hand; decides KEEP/DROP of a vertex at tol 0.0283 |
| **3** | Boolean output rebuild drops `CommonProps` | `controller.rs:1766` `common: common.clone()` | `Document/Controller.swift:1288` field-by-field | PARTIAL | R8 R6 | set any operand's opacity <100%, then union | **[V-BASE]** opacity forced 1.0, `locked` forced false, blend/mask/name/id/`tool_origin` dropped |
| **4** | Eyedropper appearance cache: **float enum vs hex string** | `interpreter/effects.rs:5177` serde over `Color` | `Algorithms/Eyedropper.swift:459` `colorToString → c.toHex()` | NONE | R1 R6 R8 | Eyedropper click → Alt+click | **[V-HEAD]** `colorToString` still `c.toHex()` at `:459-460`; loses **alpha + colour-space variant**, and `state.eyedropper_cache.fill.color` is an **object** in Rust, a **string** in Swift |
| **5** | `segmentsOfElement` has **no `.live` case**; filled polyline goes bbox-only | `algorithms/hit_test.rs:232` (Live arm at `:268`, evaluates rings) | `Algorithms/HitTest.swift:88`, `default:` at **`:115`** | NOT_IN_ROUNDTRIP | R6 R3 | marquee / lasso — everyday | **[V-HEAD]** dispatch arms at HEAD are `.line .rect .polyline .polygon .path default` — no `.live`. Lasso across a donut hole: **selects in Swift, not in Rust**. **CLOSED — both legs; see §9.1(b)** |
| **6** | `doc.zoom.apply` — the `anchor = -1` "viewport centre" default | `interpreter/effects.rs:1752` (uses `viewport_w/2`) | `Tools/YamlToolEffects.swift:764` `anchorXRaw < 0 ? px : anchorXRaw` | NONE | R6 | any zoom action with default anchors | **[V-HEAD]** line 764 read at HEAD — **no viewport-centre branch**; Swift carries `viewportW` and does not use it |
| **7** | `doc.zoom.set` — Rust recomputes pan, Swift does not | `effects.rs:1786` | `YamlToolEffects.swift:777` ("pan unchanged") | NONE | R6 R8 | Cmd-1 from 4× | **[V-BASE]** Rust has the fix; Swift is the pre-fix version; **`workspace/actions.yaml:343` still documents the OLD behaviour**, so the reference cannot arbitrate |
| **8** | Six view actions **bypass the YAML pipeline** in Swift (native `Model` methods, hardcoded constants) | `workspace/keyboard.rs:500`, `menu_bar.rs:422` → actions | `Canvas/ContentView.swift:540`, `Menu/JasCommands.swift:352` → `Model.swift:530-583` | NONE | R6 R8 | View menu, Cmd-+/−/0/1 | **[V-BASE]** `pad = 20.0`, clamp `0.1…64.0` hardcoded; `preferences.viewport.*` moves Rust only; `fitActiveArtboard` uses `artboards.first` vs Rust's `current_artboard`; **the correct Swift effects are dead on the user path** |
| **9** | Swift boolean generic dispatcher registers **4 of 9 verbs** | `interpreter/renderer.rs:3094` — all 9 | `Panels/LayersPanel.swift:839` — union, subtract_front, intersection, exclude | NONE | R6 | menu → Pathfinder → Divide/Trim/Merge/Crop | **[V-HEAD]** the 4-pair list read at HEAD `:839-846`; the action corpus drives **this** dispatcher and holds exactly those 4 verbs — gap invisible **by construction** |
| **10** | `hypot` — libm vs naive `sqrt(dx²+dy²)` | `interpreter/expr_eval.rs:891` `dx.hypot(dy)` | `Interpreter/ExprEval.swift:1361` `(dx*dx+dy*dy).squareRoot()` | PARTIAL | R1 R5 | **every drag** (Line min-length, Pen click-vs-drag) | **[V-HEAD]** both bodies read at HEAD. **[MEASURED]** 1-ULP apart on 423 / 779,961 pairs; `hypot(1e200,1e200)` = 1.41e200 vs **+inf**. Corpus has one case, `hypot(3,4)==5` — the one input that cannot fail |
| **11** | `grayscale()` / `cmyk()` — saturating cast vs **trapping initialiser** | `expr_eval.rs:600` `.round() as u8` (saturates) | `ExprEval.swift:1148` `UInt8(((1-k/100)*255).rounded())` — **no clamp** | NONE | R7 | panel-driven `k` outside 0–100 | **[V-HEAD]** line 1148 read at HEAD. `grayscale(101)` → `UInt8(-3.0)` → **Swift fatal error**; Rust returns `#000000`. Not a value difference — a **crash vs a clamp** |
| **12** | `GradientStop.color` — **`Color` enum vs `String` hex** | `geometry/element.rs:391` `pub color: Color` | `Geometry/Element.swift:379` `public let color: String` | NONE | R1 R6 | Gradient panel → edit a stop → save/reload | **[V-HEAD]** both struct declarations read at HEAD. Quantisation is **baked into the type** — not fixable at a call site. `Fill.color`/`Stroke.color` are float `Color` in both, so the asymmetry is gradient-specific |
| **13** | `flatten.json` is **registered, green, and vacuous** | `element.rs:2007` (curve arms) | `Element.swift:3840` | PARTIAL | R1 R6 | any curved path | **[V-HEAD]** counted: 3 vectors; `"C"`=0, `"Q"`=0, `"CurveTo"`=0, `"QuadTo"`=0, `curve`=0, `quad`=0 occurrences in the whole file. Gates the Z-bookkeeping, **nothing** about subdivision |
| **14** | `fit_curve.json` — every vector returns before the Schneider recursion | `algorithms/fit_curve.rs:186-323` | `Algorithms/FitCurve.swift:177-248` | PARTIAL | R1 R4 | Pencil/Paintbrush, Object > Simplify | **[V-HEAD]** all 7 names listed: `empty_returns_empty, single_point_returns_empty, two_points_one_segment, collinear_points_one_segment, horizontal_line, vertical_line, two_coincident_points`. **[MEASURED]** hypot/sqrt split (reversed vs path_ops) feeds `computeMaxError`'s **split index** |
| **15** | Rust `PanelColorState` — a **second** Rust colour reader, off the converged path | `workspace/color_panel_view.rs:106` `sync_from_color` (float `to_hsba`/`to_cmyka`), `:127` `to_color` → `Color::cmyk` | (Swift's converged reader is `ColorPanelSync.swift:81` `panelChannels(for:)`) | NONE | R1 R6 R8 | live Dioxus component | **[V-HEAD]** live: `use_signal(PanelColorState::default)` at `:280`, `sync_from_color` called at `:315,566,625,692,727`. It derives h/s/b from the **float** colour — the original bug's mechanism, now on the Rust side — while the corpus-gated `panel_channels` (`color_util.rs:145`) quantises first |
| **16** | Swift `seedSliders` grayscale uses **luma**, Rust uses `1 − max(r,g,b)` | `color_panel_view.rs:117` via `to_cmyka` | `Panels/ColorPanel.swift:235` `0.2126r+0.7152g+0.0722b` | NONE | R1 | Color panel → Grayscale, any non-gray colour | **[V-HEAD]** line 235 read at HEAD and **still called** (`ColorPanel.swift:47`). Pure red: Rust k=0, Swift k≈78.74 — a **different formula**, not a rounding gap |
| **17** | Swift tspan clipboard is **hand-enumerated**, Rust is **serde-derived** | `geometry/tspan.rs:237` `serde_json::to_value(t)` | `Geometry/TspanPrimitives.swift:146` `transform: nil,  // …not part of the clipboard payload` | NONE | R6 R8 | copy/paste a styled range | **[V-HEAD]** Rust `Tspan` has `pub transform: Option<Transform>` (`tspan.rs:145`) and the payload is auto-complete; Swift's omission is now **commented** but still one-sided. Mechanism guarantees the next field too |
| **18** | msgpack codec drops fields no fixture populates | `geometry/binary.rs:351` (`pack_common` 6 of 9), `:744-838` (gradients/brush/mode/mask/tool_origin hardcoded) | `Geometry/Binary.swift:564,830,619` (same omissions) | NONE | R6 R8 | apply a brush / set a blend mode, relaunch | **[V-BASE]** grep of all 25 `test_fixtures/expected/*.json` for `mode, mask, fill_gradient, stroke_gradient, fill_rule, tool_origin, dash_align_anchors, width_points` → **0 hits**. Currently symmetric-but-lossy; **this is where a one-port slot lands silently** |
| **19** | `Document` codec packs **4 of 8** fields | `binary.rs:518` | `Binary.swift:728` | NONE | R6 | one relaunch | **[V-BASE]** `artboard_options`, `document_setup`, `print_preferences` dropped with no comment and no repair; `artboards` repaired only by **re-seeding a default** in each port independently |
| **20** | SVG writer attribute-set asymmetry | `geometry/svg.rs:1283` reads `jas:tool-origin`, **never writes it**; writes `fill-rule` | `Geometry/Svg.swift:322` **writes** `jas:tool-origin`; no `fill-rule` | NONE | R6 | blob-brush art → save SVG → reopen | **[V-BASE]** set-diff of write-position attribute names = exactly 2 entries. After a round-trip Swift still merges blob strokes, Rust starts a new element |
| **21** | Transform kernel ungated (`multiply`, `inverse`, `around_point`, `apply_point`) | `geometry/element.rs:559-674` | `Geometry/Element.swift:590-667` | NONE | R1 R5 R6 | every transform in the app | **[V-BASE]** bodies match today; no `transform` family, no roundtrip arm. `det.abs() < 1e-12` is a bare literal duplicated in two files. R6: Swift `scale(_ sx:, _ sy: Double? = nil)` defaults `sy = sx`; Rust requires both |
| **22** | Properties-panel transform decomposition: display **and** commit on one primitive | `interpreter/renderer.rs:1584`, `workspace/dock_panel.rs:663` | `Interpreter/PropertiesPanelSync.swift:83,105` | NONE | R1 R5 R7 | W/H/rotation/shear fields | **[V-BASE]** the colour bug's exact shape. Note the asymmetry in investment: `stroke_apply` and `character_apply` each got a panel-edit corpus; **the panel that writes matrices got none** |
| **23** | `element_bounds` covers only **untransformed** geometry | `canvas/render.rs:2498` evaluated bbox | `Interpreter/PropertiesPanelSync.swift:29` | INDIRECT | R5 R8 | select anything with a transform | **[V-BASE]** all 17 vectors carry `"transform": null`; the evaluated (ancestor-folded) variant is in neither roundtrip binary, yet it is what the panel shows and the selection box is drawn from |
| **24** | Text index unit: Rust **scalar** vs Swift **grapheme** — and Swift disagrees with itself | `algorithms/text_layout.rs:288` `chars()`; `tspan.rs:581` | `TextLayout.swift:75` `Array(content)`; `TspanPrimitives.swift:609` `content.count` (grapheme) vs `:651,693,811` `unicodeScalars` | PARTIAL | R7 R6 | type any accent/emoji; import CRLF text | **[V-BASE]** all 34 vectors across the 3 layout families are pure ASCII, where the units coincide. Swift's caret resolver counts graphemes and Swift's own splitter counts scalars → a split **inside** a grapheme |
| **25** | Font metrics / advance widths reachable from **neither** roundtrip binary | `tools/text_measure.rs:25` | `Tools/TextMeasure.swift:11` | NOT_IN_ROUNDTRIP | R1 R7 | every text element | **[V-BASE]** the layout **math** is gated; every **number fed into it** is not. Different rasterizers (Canvas2D vs NSAttributedString) — cannot be bit-equal in the current shape |
| **26** | The text harness injects a **different** measure fn per port | `bin/algorithm_roundtrip.rs:564` `chars().count()` | `AlgorithmRoundtrip.swift:367` `s.count` | PARTIAL | R7 | gate integrity, not the app | **[V-BASE]** invisible while vectors are ASCII. **The first non-ASCII vector will fail for a reason in the driver and be triaged to `layoutText`** — fix the harness *before* adding vectors |
| **27** | `shape_recognize` final ranking: `sort_by` (stable) vs `sort` (**unstable**, no tiebreaker) | `algorithms/shape_recognize.rs:273` | `Algorithms/ShapeRecognize.swift:204` | PARTIAL | R2 R4 | draw a deliberately straight freehand stroke | **[V-BASE]** exact ties are reachable (straight open polyline ⇒ `fitLine` 0.0 **and** `fitScribble` 0.0). Flips the **kind** of the committed element. Agrees today only because Swift insertion-sorts at small *n* |
| **28** | `flatten_path_to_rings` — the boolean operand flattener, in neither binary | `geometry/element.rs:1934` (`FLATTEN_STEPS`) | `Geometry/LiveElement.swift:1033` (**hardcodes `steps = 20`**) | NOT_IN_ROUNDTRIP | R1 R4 R6 | any curved boolean operand | **[V-BASE]** distinct from the `flatten` family's function. **[MEASURED]** Bernstein **association** differs → 48,244/200,000 vertices differ, max 1.7e-13; `PARAM_EPS` is 1e-9 on the *normalized* param, so short segments amplify it to the snap threshold |
| **29** | `element_to_polygon_set` — 1 of 9 arms has a vector | `geometry/live.rs:1013` `(i/n)*TAU` | `Geometry/LiveElement.swift:904` `2π*i/n` | PARTIAL | R1 R4 R5 R7 | select a **circle** + a rect → Union | **[V-BASE]** all element-level boolean vectors set up from `overlapping_rects.svg`/`two_rects.svg`. `segmentsForArc`: Rust saturates on inf/NaN, Swift `Int(n.rounded(.up))` **traps** |
| **30** | `apply_simplify_after_op` exists in **Rust only** | `workspace/app_state.rs:2642` | **ABSENT** from `BooleanOptions` | NONE | R6 | Boolean Options → "Simplify after operation" | **[V-BASE]** `workspace/state.yaml:720,728` declares both keys; Swift's `booleanOptionsFromStore` reads neither. Also changes **undo granularity** |
| **31** | `path_ops` closest-point: `hypot` vs `sqrt` → a different **cmd_idx** | `geometry/path_ops.rs:498,520,596` (6 hypot sites) | `Geometry/PathOps.swift:131,152,188` (6 sqrt sites) | NOT_IN_ROUNDTRIP | R1 R7 | Pen "Add Anchor Point" on a path | **[V-BASE]** **[MEASURED]** 33,496/200,000 differ at the last bit. Feeds two **discrete** decisions: a 50-sample `d < best` scan (moves `best_t` by 0.02) and a cross-segment `dist < best_dist` (different segment **split**) |
| **32** | 24 mirrored `PathOps` insert/delete/split fns, none in either binary | `path_ops.rs:657,734,564,376,273,293,205` | `PathOps.swift:365,280,219,608,575,591,549` | NOT_IN_ROUNDTRIP | R1 R8 R6 | Pen add/delete anchor; Path Eraser | **[V-BASE]** branch-heavy **rebuild** functions producing committed command lists; consume the possibly-divergent `seg_idx`/`t` from #31 |
| **33** | `to_radians()` vs `* .pi / 180` — 4 paired sites | `algorithms/transform_apply.rs:52`, `element.rs:598`, `calligraphic_outline.rs:42` | `TransformApply.swift:46`, `Element.swift:605`, `CalligraphicOutline.swift:48` | NONE | R1 R6 | Rotate/Shear at any **whole-degree** angle | **[V-BASE]** **[MEASURED]** differ on **192 of 721** integer degrees (27%). Absorbed at `element.rs:1656` (arc x_rotation) because `element_bounds` pins it at 1e-4; the other three are not |
| **34** | `dash_renderer` — ~470 lines, 8 epsilon comparisons, mirror unit tests only | `algorithms/dash_renderer.rs:26` | `Algorithms/DashRenderer.swift:20` | NONE | R4 R1 | Stroke panel dash + align-anchors | **[V-BASE]** Rust↔Swift faithful line-for-line. The **verified** divergence is against the **blocking reference**: `workspace_interpreter/dash_renderer.py:270` uses Python `round()` = **banker's**, both apps use half-away-from-zero → pattern `[4,2]` on length 15 gives m=2 (ref) vs m=3 (apps) — a different dash layout |
| **35** | Boolean sweep's `eventLess` sort ties in the Martinez sweep | `algorithms/boolean.rs:699` `sort_by` (stable) | `Algorithms/Boolean.swift:456,678` `sort` (unstable) | PARTIAL | R2 R4 | a Group holding two identical shapes as one operand | **[V-BASE]** the R2 tiebreak was fixed in `BooleanNormalize.swift:314,395` and `Planar.swift:229,305` **but not in `Boolean.swift`**. `compare_exact_boolean` **would** catch it — no vector produces the tie |
| **36** | Roundtrip harness geometry helpers, duplicated and **never compared** | `bin/algorithm_roundtrip.rs:843` | `AlgorithmRoundtrip.swift:551` | PARTIAL | R1 R4 | harness only | **[V-BASE]** `compare_exact_boolean` compares only `rings`; the oracle runs `ref_lang = rust` alone. **`polygon_set_area` signs rings by nesting depth**, so two partially-overlapping rings both get depth 0 → reports A1+A2 instead of A1+A2−2·overlap. See §5 |
| **37** | SVG XML layer: hand parser vs `XMLDocument` | `geometry/svg.rs:816` `unescape_xml` (5 named entities, **no numeric refs**, attrs never unescaped) | `Geometry/Svg.swift:1530` `XMLDocument` | NONE | R7 R8 | name an element `A & B`, save, reopen | **[V-BASE]** Rust **writes** `escape_xml`'d `inkscape:label` and never unescapes attributes → grows one `amp;` per round-trip. `&amp;` replaced **first** ⇒ `&amp;lt;` double-unescapes. Byte-scan of `test_fixtures/svg` + `expected`: **zero** bytes >127, zero char refs |
| **38** | SVG numeric parse: `parse::<f64>` vs `Double.init` | `svg.rs:1700` | `Svg.swift:1383` | NONE | R7 R5 | import any third-party SVG | **[V-BASE]** **[MEASURED]** Swift accepts C hex floats (`"0x1p3"`→8.0); Rust returns None. Both accept `inf`/`nan` → **non-finite geometry from an untrusted boundary in both ports**. `trim_end_matches('%')` vs `dropLast()`: `"50%%"` → 50 vs 0 |
| **39** | `doc.symbols` sort — key **ties by construction** | `binary.rs:525` `sort_by` (stable) | `Binary.swift:735` `sorted(by:)` (unstable) | INDIRECT | R2 R3 | many id-less symbol masters, save+restore | **[V-BASE]** key is `id ?? ""`, and `id` is optional ⇒ ties are structural. Latent until ~21 symbols (Swift insertion-sorts below that) — **so it will surface much later as a mystery** |
| **40** | SVG functional-notation colour import (`rgb()`/`rgba()`, hex, named) | `svg.rs:1143` | `Svg.swift:762` | PARTIAL | R6 R7 | File > Open any non-native SVG | **[V-BASE]** `test_fixtures/svg` **is** a gated 44-file glob family, and the only colour literals in it are `rgb(int,int,int)` and `none`. 4 confirmed divergences in the unexercised arms (`rgba()` with 3 parts; `rgb()` with 4; `255.0`; unterminated `rgb(1,2,3`) |
| **41** | SVG export out-of-gamut clamp | `svg.rs:31` `(rv*255).round() as u8` (**saturates**) | `Svg.swift:25` `Int(round(cr*255))` (**no clamp**) | PARTIAL | R1 R5 | needs an out-of-gamut colour first | **[V-BASE]** Rust `rgb(255,0,0)` vs Swift `rgb(306,0,0)` — **invalid SVG**. Mirror of `to_hex`, which clamps in both |
| **42** | Swift hex-parser proliferation: **7+** decoders vs Rust's 3, with different contracts | `color_util.rs:4`, `element.rs:170`, `svg.rs:1113` | 7 sites incl. **two** private `cgColorFromHex` in one file: `CanvasSubwindow.swift:354` (accepts bare `aabbcc`) and `:2234` (**requires** `#`, rejects it) | NONE | R6 R7 | every gradient-filled element | **[V-BASE]** the `:354` variant parses gradient-stop hex and falls back to opaque **black**; Rust's stop holds a parsed `Color` and cannot be in that state. Compounds #12 |
| **43** | `radial` gradient radius: Rust floors at `.max(0.01)`, Swift does not | `painter/element_render.rs:756` | `Canvas/CanvasSubwindow.swift:416` | NOT_IN_ROUNDTRIP | R4 R6 | Gradient → Radial → aspect-ratio 0 or negative | **[V-BASE]** Swift radius exactly 0 (paints nothing) / **negative** (undefined in CoreGraphics). The Rust golden `ref_gradients.json` is claimed by `element_render/tests.rs:274` **alone** — a Rust-only pin, invisible to this |
| **44** | Dialog `<-` assignment: string surgery vs real parser | `interpreter/dialog_view.rs:93` (requires literal `"fun "`, splits on first `->`, applies **after**) | `Interpreter/StateStore.swift:246` (parses, requires `.closure`, writes **during**) | NONE | R8 R6 | Scale/Shear/Artboard-Options reference point | **[V-BASE]** `workspace/tests/expressions.yaml:599` says out loud this is **excluded by design**. `fun(x)->…` (no space) is a **silent no-op in Rust**, works in Swift. Write timing differs (batched vs immediate) |
| **45** | `bind.*` values, dynamic `visible`/`disabled`, `{{ }}` content | `interpreter/widget_tree.rs:73`, `panel_layout.rs:206` | `Interpreter/WidgetTree.swift:119`, `PanelLayout.swift:224` | INDIRECT | R1 R3 | every panel render | **[V-BASE]** `panel_widget_tree` records **sorted key names** of `bind`/`style` and nothing about values; `widget_tree.rs:102` collapses a dynamic `visible` to a `dyn_visible: true` flag "so the snapshot stays eval-free". `panel_layout` pins only `codepoint_count(text)*10` — **so `"664040"` vs `"664141"` would pass**, literally the colour bug's byte pattern |
| **46** | `calligraphic_outline` — 3 stacked formula asymmetries | `algorithms/calligraphic_outline.rs:34,42,48,132` | `Algorithms/CalligraphicOutline.swift:41,48,56,108` | NONE | R1 R7 | Brushes → apply a Calligraphic brush | **[V-BASE]** `to_radians` (#33), `powi(2)` vs `pow(_,2)`, `hypot` vs `sqrt`. **[MEASURED]** the sample-count flip was stress-tested over 500,000 segments and **never** fired — so rate this as vertex drift, not a count flip |
| **47** | Arrowhead `ArrowShape` table — two hand-maintained data tables | `canvas/arrowheads.rs:35-120` | `Canvas/Arrowheads.swift:26-71` | NONE | R6 | every rendered arrowhead | **[V-BASE]** diffed shape-by-shape: **identical today** (14 names, same `back` values, same 0.5522847498). But `arrow_trim` supplies setbacks as **numbers**, so the table→setback map is never compared — retune `back` in one port and the family stays green |
| **48** | `offset_path` variable-width profiles | `algorithms/offset_path.rs:23,86,93` | `Canvas/OffsetPath.swift:17,58,63` | NONE | R1 R4 | Stroke panel width profile | **[V-BASE]** pure functions of (width points, path) — **trivially corpus-shaped**, in no family. Arithmetic matches; exposure is epsilon-free `t` boundaries. **[SUSPECT]** cap arcs use `anticlockwise: true` (Rust) and `clockwise: true` (Swift) — *not confirmed either way*, worth an eyeball |
| **49** | `simplify_polyline` / `detect_corners` | `algorithms/simplify.rs:50,107` | `Algorithms/Simplify.swift:51,108` | NONE | R4 R1 | Object > Simplify; boolean output | **[V-BASE]** unusually clean — **both** ports use sqrt-of-squares, same 1e-12 guard. Listed only because it **calls `fit_curve`**, inheriting #14 wholesale, plus an epsilon-free `d < cos_threshold` tie at the 30° default |
| **50** | Object→JSON-string materialization key order | `interpreter/expr_types.rs:84` (`serde_json`, **BTreeMap ⇒ sorted**) | `Interpreter/ExprTypes.swift:95` (`JSONSerialization`, **no `.sortedKeys`**) | NONE | R3 | not reached by today's bundle | **[V-BASE]** **[MEASURED]** the same 5-key dict serialized in **3 different orders across 3 runs of one binary** (per-process hash seed) — so not merely different from Rust, **not stable within Swift**. Becomes reachable the moment a panel compares whole records |
| **51** | Number→string coercion above `i64::MAX` | `expr_types.rs:108` (`as i64` **saturates** ⇒ falls to shortest-round-trip) | `ExprTypes.swift:254` (`rounded(.towardZero)` ⇒ always `%.0f` = **exact expansion**) | PARTIAL | R1 R7 | a `{{ }}` value > ~9.22e18 | **[V-BASE]** **[MEASURED]** `1e23` → `"100000000000000000000000"` vs `"99999999999999991611392"`. The corpus's one big case is `1e20` — **the one magnitude where the two agree**. Strings compare **byte-exactly**, so this is the only exact-comparison surface in the expression gate |
| **52** | String `.length` — 3 different answers in 3 ports | `expr_eval.rs:245` `s.len()` (**bytes**) | `ExprEval.swift:897` `s.count` (**graphemes**) | NONE | R7 | not reached today | **[V-BASE]** reference returns **scalars** — three-way split. All ~40 `.length` uses in `workspace/*.yaml` are on **lists**, where all three agree. **Exactly the pre-bug colour profile**: divergent shared primitive, no consumer yet |
| **53** | Closure capture when the bound name collides with a namespace key | `expr_eval.rs:1249` (separate `Scope`, consulted **first**) | `ExprEval.swift:1043` (same ctx dict; refresh **clobbers**) | PARTIAL | R6 R8 | `let node = …` inside an applied closure | **[V-BASE]** 3 lexical-capture cases exist and **every one names the binding `x`**. `node`/`param` are the names an author is most likely to pick, because they are the surrounding YAML's vocabulary |
| **54** | `min`/`max` with NaN | `expr_eval.rs:838` `f64::min` (**returns the non-NaN operand**) | `ExprEval.swift:1333` `Swift.min` (**propagates**, order-dependent) | PARTIAL | R5 | needs a NaN (inf−inf) | **[V-BASE]** **[MEASURED]**. Low reachability — the language returns `null` for div-by-zero, `sqrt` of negative, non-finite `pow` — but the result then feeds the **trapping** `Int(Double)` sites of #11 |
| **55** | Lexer character classes: ASCII vs Unicode | `interpreter/expr_lexer.rs:71,108,124` | `ExprEval.swift:158,195,208` | NONE | R7 | authoring-time only | **[V-BASE]** **[MEASURED]** `U+0663`, `U+00BD` satisfy `isNumber` ⇒ Swift lexes a Number, `Double(…)` is nil, `?? 0.0` ⇒ a **silent literal zero**; Rust rejects to null. Reference is Unicode too, so **Rust is the odd port out** |
| **56** | Test-JSON escapes only `\` and `"` | `geometry/test_json.rs:61` | `Geometry/TestJson.swift:31` | NONE | R7 | press Enter in a text element | **[V-BASE]** **fails loudly**, not silently — both parsers reject. Ranked here only because it **caps** what the corpus can ever gate: the byte oracle behind all three codec gates **structurally cannot represent multi-line text** |
| **57** | `NaN` prints `"NaN"` (Rust) vs `"nan"` (Swift) in both formatters | `svg.rs:24`, `test_json.rs:33` | `Svg.swift:12`, `TestJson.swift:13` | NONE | R5 | needs a NaN coordinate | **[V-BASE]** **[MEASURED]** — and the negative result matters more: `format!("{:.4}")` and `%.4f` agree **byte-for-byte** on every finite case tested (0.00005/0.00015/0.00025/0.00035/1.00005, ±0.0, 1e21, 1e−7) and both infinities. NaN is the **sole** exception. Reachable via #38's `x="nan"` |
| **58** | Letter spacing / baseline shift / h-v scale: serialized, gated as **data only** | `binary.rs:221,232`; `test_json.rs:278` | `TspanPrimitives.swift:31,71`; `Svg.swift:380` | NONE | R1 R6 | Character panel | **[V-BASE]** `layoutText` accepts none of them as parameters in **either** port — the arithmetic combining them with advance widths lives only in two independent renderers |
| **59** | `path_from_id` negative index | `expr_eval.rs:697` `parse::<usize>` (**rejects `-1`**) | `ExprEval.swift:1239` `Int(p)` (**accepts**) | NONE | R6 R7 | a malformed stored/imported path id | **[V-BASE]** types encode it: `Vec<usize>` vs `[Int]`. **No fixture family exists for `path`/`path_child`/`path_from_id`/`element_at`/`.depth`/`.parent`/`.id`/`.indices` in either port** |
| **60** | `.fun`/`.let` in Swift's dot-accessor whitelist only | `interpreter/expr_parser.rs:351` | `ExprEval.swift:601,626,629` | NONE | R6 | a field literally named `fun`/`let` | **[V-BASE]** `state.fun` → **null** in Rust, resolves in Swift. Latent authoring trap |
| **61** | `fun (5) -> x` recovery: nullary closure vs null | `expr_parser.rs:472` (advances, no error ⇒ **callable**) | `ExprEval.swift:702` (returns, no error ⇒ **null**) | NONE | R6 | malformed YAML only | **[V-BASE]** matters because the corpus family built **specifically** to pin recovery symmetry (3 cases) is one case short of this class |
| **62** | `PlanarGraph.face_outer_area` / `top_level_faces` | `algorithms/planar.rs:522` | `Algorithms/Planar.swift:106` | NOT_IN_ROUNDTRIP | R1 | **not reachable from production** | **[V-BASE]** `PlanarGraph` has **zero** production call sites in either port — roundtrip + unit tests only. Pre-wired for a future Live-Paint consumer. Lowest rank, and listed **only** because that is the colour bug's precondition verbatim: a shared primitive with a partial family awaiting its first real consumer |
| **63** | `CanvasCull` — Swift only | **ABSENT** (`grep -i cull` over `jas_dioxus/src` → nothing) | `Canvas/CanvasCull.swift:14` | NONE | R4 R5 | every Swift repaint | **[V-BASE]** not a symmetric primitive, so not a parity row in the strict sense — but a **false skip drops visible content**, which is a display-list divergence under Option A. Nothing gates `margin` against real stroke/arrowhead bleed (ARROWTRIM is an open stone) |

---

## 2. THE TOP SIX, ARGUED

For each: the concrete thing a user sees, and the **smallest** family that would gate it.

### #1–#3 — The boolean cluster. One interlocking defect, three rows.

**What the user sees.** Two overlapping circles, each at 50% opacity, one named "left" in the Layers
panel. Boolean → Union. **Rust** produces a shape at 50% opacity, named, with the back operand's
fill, whose ring keeps every flattened curve vertex. **Swift** produces a shape at **100% opacity**,
**unnamed**, **unlocked**, with `tool_origin` gone, whose ring has had collinear vertices collapsed
by a formula that loses ~5 significant digits when the artwork sits far from the origin. Then save
both and diff: different vertex **counts**, different opacity, different names. **The corpus is
green.** [V-HEAD for the default; V-BASE for the formula and the rebuild]

**Why it survived.** Every element-level boolean vector in the repository sets up from
`overlapping_rects.svg` or `two_rects.svg`. Axis-aligned rects have no collapsible vertices (all 90°
corners), no flattened curves, no opacity, no name, no id, no blend mode. And because Rust's default
is `false` while Swift's is `true`, the collapse function **executes in exactly one port** during a
corpus run — there is not even an accidental comparison.

**Smallest family that gates it.** Extend `test_fixtures/actions/boolean.json` with **two** vectors,
no new machinery:
1. `union_curved_operands` — two **circles** (or one circle + one path with a `C`), so the output ring
   has collinear-ish vertices. Assert the emitted ring's **vertex count** and the vertices.
2. `union_preserves_common_props` — two rects with `opacity: 0.5`, `name: "left"`, `locked: true`,
   a blend `mode`, and `tool_origin: "blob_brush"` on one. Assert those fields on the output.
   Vector 2 alone red-lights #3, #18 and #20 simultaneously.

Vector 1 will fail immediately on the default mismatch, which is the point: the fixture's job is to
force the ruling on **which** default is spec (`workspace/state.yaml` says `false`).

### #4 — The eyedropper cache is the proven bug at a second site, and worse.

**What the user sees.** Eyedropper a shape whose fill is 60%-alpha `Color::cmyk(...)`, then Alt+click
a target. **Rust** applies the colour with its alpha and its CMYK variant intact. **Swift** applies
`664040` — 8-bit, gamut-clamped, **alpha silently dropped to opaque, variant gone**. Worse than a
value difference: `state.eyedropper_cache` is a workspace-visible state key (`effects.rs:5179`), so
`state.eyedropper_cache.fill.color` evaluates to a **JSON object** in Rust and a **string** in Swift.
Any YAML expression reading it diverges **structurally**, not numerically. [V-HEAD: `colorToString`
is still `c.toHex()` at `Eyedropper.swift:459-460`]

**Smallest family.** `test_fixtures/algorithms/eyedropper_cache.json`, driven by a new `eyedropper`
arm in both roundtrip binaries: input = an `Appearance` with a fill whose colour is each of the three
`Color` variants × {alpha 1.0, alpha 0.6} × {in-gamut, out-of-gamut}; output = **the cache payload
itself**, compared with the `exact` strategy. 12 vectors. The `exact` strategy is essential — this is
a **shape and lossiness** bug, and any tolerance-based comparison of parsed numbers would miss the
object-vs-string difference entirely.

### #5 — Marquee selection is categorical, not numeric.

**What the user sees.** Object > Pathfinder → Subtract, producing a donut-shaped compound shape.
Drag a selection marquee (or lasso) across the **hole**. **Swift selects the element; Rust does
not.** Selection state is committed and drives every subsequent edit, so from that gesture on the two
ports are editing different things. Same for a V-shaped **filled polyline**: Swift's explicit
`.polyline` case returns `rectsIntersect(bounds…)` — a whole-bbox test — where Rust tests real
segments. [V-HEAD: `segmentsOfElement`'s dispatch arms at HEAD are `.line .rect .polyline .polygon
.path default` — **no `.live`**, `default:` at `HitTest.swift:115`]

**This is the one row here whose fix is a missing `case`, not an epsilon.** It is also the clearest
instance of the **coverage trap** in §5: the family is named `hit_test`.

**Smallest family.** Add **three** `function` arms to the existing `hit_test` dispatch in both
roundtrip binaries — `element_intersects_rect`, `element_intersects_polygon`, `segments_of_element` —
and 5 vectors to `hit_test.json` under the existing `exact` strategy: a marquee in the **hole** of a
Live CompoundShape; a marquee in the empty corner of a V-shaped filled polyline's bbox; a lasso over
each of the same two; and one control case (marquee fully enclosing a rect) proving the arm is wired.
`hit_test.json` already has 34 vectors and the `exact` strategy — **no new comparison strategy, no
new golden format.** Cheapest high-value move in this document.

> **ROW CLOSED** — `.live` leg in batch 1, filled-polyline leg in batch 2. But note that the
> paragraph above gets the polyline direction backwards: it reads Swift's bbox arm as the
> defect and "Rust tests real segments" as correct. A filled polyline closes implicitly, so
> the bbox arm is the one that matches the reference, and **Rust** was the port that needed
> the fix. §9.1(b) has the corrected account and the two follow-on findings.

### #6–#8 — View state: three live divergences over a subsystem with literally zero coverage.

**What the user sees.** Zoom in twice with the keyboard, then Cmd-1. The two ports show **different
regions of the document** — Rust recentres, Swift leaves the pan where it was. Zoom via a default-anchor
action and Rust anchors at the viewport centre while Swift anchors at the **document origin's screen
position**. Edit `preferences.viewport.zoom_step` and only Rust changes. Panel-select the **second**
artboard and Fit Artboard fits artboard #1 in Swift. [V-HEAD for the `anchorXRaw < 0 ? px :
anchorXRaw` fallback at `YamlToolEffects.swift:764`; V-BASE for the rest]

**Why nothing catches it.** No fixture in `test_fixtures/` sets `zoom_level` or `view_offset`. Both
runners build the model at the identity view — `Model::new(doc, None)` — and Swift's `Model.init`
carries an explicit comment that it starts at the identity "so a bare Model is screen==doc for the
gesture / action / artboard test seams." **At the identity view, screen↔doc conversion is
algebraically the identity**, so the multiply/divide-by-zoom half of every tool is ungated. That is
precisely why the three historical coordinate-space bugs (path eraser, type-on-path, paintbrush) were
all found by hand in the live app.

**Smallest family.** `test_fixtures/actions/view_state.json`: each vector = an initial
`{zoom_level, view_offset_x, view_offset_y, viewport_w, viewport_h}` plus one dispatched view action,
asserting the resulting triple. 8 vectors covers it: `zoom_in` at default anchor, `zoom_in` at an
explicit anchor, `zoom_to_actual_size` **from 4×** (that one vector alone catches #7),
`fit_in_window` on an off-origin document, `fit_active_artboard` with artboard **2** panel-selected,
and one non-default `zoom_step`. This requires the action runner to **seed view state**, which is the
real work — and it retires the identity-view blind spot for every future tool fixture too.

**A policy item, not just a bug.** #8 is one architectural breach with six symptoms: Swift's
`ContentView`/`JasCommands` intercept the view actions **before** the dispatcher, so the correctly
written `doc.zoom.*` effects in `YamlToolEffects.swift:849-929` are **dead on the user path**. A fix
applied to the effect will pass any test that drives the effect and change nothing in the app. That
contradicts the house law that native code is discouraged and behaviour comes from `workspace/*.yaml`.
Worth a council ruling.

**And a stale-prose hazard.** `workspace/actions.yaml:343` still says `zoom_to_actual_size` should
"leave pan unchanged" — so on this primitive **the spec text agrees with the port that is behind.**
Whichever way it is resolved, the YAML English must change in the same commit or the next reader will
"fix" Rust back.

> **ROWS RE-VERIFIED AND RECORDED — VIEWSEED, 2026-07-27.** All three re-measured at
> `arc2-edit-semantics` with probe vectors run through both action corpora, and each is now a
> coverage-gap row carrying its seed, its spec-derived triple and both ports' observed output:
> `view-anchor-default-divergence` (#6), `view-zoom-set-pan-divergence` (#7),
> `view-actions-bypass-yaml-in-swift` (#8). Three corrections to the account above:
>
> - **#6 has TWO causes, and Swift's anchor is the canvas top-left, not the document origin** —
>   Swift never merges the action's declared `default: -1`, so the `< 0` branch this row cites is
>   never reached (see the ROW NARROWED note at §5.7).
> - **#7: the spec is not merely stale, it is doubled.** `transcripts/ZOOM_TOOL.md` says "pan
>   unchanged" in BOTH its shortcut table and its prose, and `actions.yaml` a third time. Rust's
>   `doc.zoom.set` comment cites a ZOOM_TOOL.md sentence that is **not in that file** (grep for
>   "approximately" returns nothing). So this is not "Swift is behind" — by every written rule
>   **Swift is right and Rust diverges**, and the row needs a ruling, not a port fix.
> - **#8's fix has an ORDER dependency this row does not state.** Routing Swift's menu/keyboard
>   through the YAML pipeline today would REGRESS the menu: native `zoomIn` anchors at the viewport
>   centre (correct), the YAML path in Swift anchors at the top-left corner. #6 first, then #8.

---

## 3. WHAT IS GENUINELY COVERED

This document must not be read as "nothing is gated." Several things the sweeps went looking for
turned out genuinely closed, and re-auditing them would waste the budget.

**`color_convert` — 58 vectors, the largest family in the repo, and it is new. [V-HEAD]**
`rgb_to_hsb` (19), `panel_channels` (16), `hsb_to_rgb` (15), `rgb_to_cmyk` (8). Registered under the
**`exact`** strategy — the `_doc` explains why: the channels are integer-valued in the panel's units,
so "any tolerance would swallow" the one-unit miss the family exists to catch. Dispatched by **both**
roundtrip binaries. Goldens **derived from the spec formulas** by
`scripts/derive_color_convert_goldens.py`, not captured from a port — so a shared bug cannot compare
green. Two half-boundary vectors deliberately land on x.5 where both ports' rounding conventions
agree, so **no golden encodes a rounding the ports do not share**. `panel_channels` is the shared
reader that fixes the triggering bug: quantise to three u8s **first**, then derive h/s/b/CMYK/hex from
the integers. Swift's `ColorPanelSync.swift:81` calls it; Rust's live YAML panel path calls it at
`dock_panel.rs:157`.

**The Color-panel WRITE path has converged. [V-HEAD]** Rust's `compute_color_from_panel`
(`renderer.rs:5996-6026`) now returns `Color::rgb(...)` from its **CMYK** arm — it no longer stores
the `Color::cmyk` variant. Swift's `colorFromColorPanelScope` does the same, arm for arm, including
the `hsbToRgb` quantisation. **The colour sweep's "CMYK write-back variant" row is CLOSED** at HEAD;
only the legacy `PanelColorState::to_color` (row #15) still produces the variant.

**Boolean fill rule — the brief's premise here is also stale, and the closure is verified.** FILLRULE
has **merged** (18 commits, `56424ed1..3e5785c6`, all ancestors of HEAD). `a_fill_rule`/`b_fill_rule`
are parsed by both roundtrip runners; 2 of 13 `boolean.json` and 9 of 20 `boolean_normalize.json`
vectors declare a non-default rule, including the decisive same-geometry pairs
(`nested_co_oriented_rings_evenodd_hole` 300 vs `..._nonzero_solid` 400). The shared test-JSON parser
no longer hardcodes nonzero.

**`normalize` / `canonicalize` — 20 vectors, well gated.** `canonicalize` **is**
`normalize(rings, rule)`, so the document-boundary canonicalization inherits all of them: T-junction,
pinch, collinear retrace, retrograde, spliced-loop, doubly-wound, each with hand-derived `_derivation`
prose. `boolean_union`/`intersect`/`subtract`/`exclude` delegate to the `*_ruled` twins, so coverage
transfers — **not** a gap.

**R2 sort stability, where it was fixed.** `BooleanNormalize.swift:314,395` and
`Planar.swift:229,305` all carry explicit tiebreaks **plus comments naming Rust's stable `sort_by` as
the reason**. `Planar.swift:218-252` additionally reproduces Rust's `BTreeSet` ordering with
insertion-order + an explicit `edges.sort` rather than iterating a `Set` — that is the **R3** hazard
handled correctly. (`Boolean.swift` is the one that was missed: row #35.)

**`arrow_trim` — 16 vectors, the strongest family in the geometry domain.** Arc-length setback trim
across lines, corners spanning two segments, cubics, quads,
`line_then_cubic_end_trim_stays_in_cubic`, setback-exceeds-total and overlapping-setback degenerates,
plus **6 `orient_*` vectors** pinning trim-chord head angles at scale 100 and 200 (including the two
live JYH repro cases). `head_angles` — the function the renderer actually calls — is driven directly.

**`element_bounds` — 17 vectors including true arc extrema.** `path_cubic_tight_bounds`,
`path_arc_large_semicircle`, `path_arc_quarter_ccw`, `path_arc_zero_radius_line`,
`path_arc_elliptical_rotated`, `path_arc_half_then_close`, plus a stroke-inflation case. The
arc-extrema stone landed and stayed pinned. This family also **absorbs** the `to_radians` asymmetry at
`element.rs:1656` (arc x_rotation) at tol 1e-4 — which is why that one instance of row #33 is safe.

**`align` — 14 ops, 16 vectors, oracle-checked.** Driven through both roundtrips at 1e-4 **and**
compared against pinned `translations`, so a shared bug cannot compare green. Reference mode
(selection / artboard / key_object) is parameterised. `Transform::translated` is covered transitively.

**Text layout algorithms — 34 vectors across 3 families, genuinely substantial (over ASCII).**
Soft wrap, long-word character break, hard newline, left/right/first-line indents,
centre/right/justify including last-line alignment, space-before/after, hanging punctuation both
sides, list markers and gap, word-spacing min/desired/max bands, hyphenation with bias; plus
arc-length glyph placement, start offset, per-glyph angle, overflow past the path end. **Do not
re-derive any of this** — the gap is the ASCII restriction (#24) and the synthetic advance (#25).

**Tspan primitives — 6 families, 28 vectors, a real gate by a different mechanism.** `tspan_split`,
`tspan_split_range`, `tspan_merge`, `tspan_concat_content`, `tspan_resolve_id`, `tspan_default`, read
by **both** ports as in-port unit gates over the shared fixture. `corpus_manifest.json` documents this
asymmetric registration honestly. **"Not in the roundtrip binary" does not mean uncovered here** — the
gate is real, the mechanism differs. Also verified: the two `Tspan` structs have **51 fields each with
no asymmetry** after snake-casing, and both `has_no_overrides` bodies check the **same 49 fields**.

**Path-B panel layout — the best-machined family in the repo.** `scripts/gen_panel_layout_fixture.py`
generates `panel_layout.json` **and** `panel_widget_tree.json` from the single canonical Python
implementation over all 16 panels, and both ports assert against the file. Its one limit is the single
pinned geometry (`avail_w = 228, avail_h = 600`).

**`hit_test` leaf predicates — 34 vectors, `exact` strategy, no tolerance slack.** `point_in_rect`,
`segments_intersect`, `segment_intersects_rect`, `rects_intersect`,
`circle`/`ellipse_intersects_rect` (filled and stroked), `point_in_polygon`, with edge/corner/tangent
degenerates. Genuinely good — it is the layer **above** it that is missing (#5).

**`length` / `measure` — 28 vectors.** Unit parse and format across px/pt/pc/in/mm, bare-with-default,
whitespace, negative, empty→null, garbage→null, unknown-unit→null; format per-unit, precision 0 and 2,
zero-trimming, `-0`→`0`. A sweep additionally **compiled and ran** the tie-rounding case the fixture
names but does not actually test: `format!("{:.2}")` and `String(format:"%.2f")` agree bit-for-bit on
0.125, 0.375, 2.675, 0.005, 1.005, 0.25, 8.835.

**Verified-equal-and-therefore-not-listed, so nobody re-opens them:**
the **48-entry named-colour table** (all keys and RGB triples diffed identical, both `gray`/`grey`
alias pairs present in both); **magic-wand colour matching** (arm-for-arm identical, float `to_rgba`
in both, same inclusive `<= tolerance`, same (None,None)-matches rule); **`snap_grid`/`snap_round`**
(`.round()`/`.rounded()` both half-away-from-zero, `powi` and `pow` both exact on powers of two, and
the single-`pop()` vs `while removeLast()` wrap-around provably equivalent because consecutive-dedup
bounds the loop at one iteration); **`arrangement.rs`** (all four epsilons match by value **and** role
— 1e-9/1e-9/1e-12/1e-9 — and `split_points` matches branch for branch; **does not need its own
family**); **`apply_operation`** (mirrors exactly, all four ops, including the SubtractFront fold);
**`xml:space` emission** (checked expecting a divergence — both emit it on the same predicate);
**the two 4-decimal formatters** (byte-identical on every finite case measured, both infinities);
**gradient-stop sort order** (**neither** port sorts stops, so R2 is not in play);
**RGB↔HSL** (absent from both — not a gap); **`WebSafeRgb`** (a pure alias for Rgb in both — parity
by mutual omission); **`midpoint_to_next`** (honoured by neither render path); **`%`, exponent
literals, div-by-zero→null, `-0.0`→`"0"`, NaN/inf string forms, the 11 namespace keys** (all
symmetric in the expression language); **`Transform::rotate`'s radian conversion** (bit-identical on
8 sampled angles — clean by luck rather than by gate, hence row #33 for its three unabsorbed twins).

**The oracle machinery itself is sound.** The per-golden-key holdout is self-policing in both
directions: a listed key absent from `expected`, **or one the port now reproduces**, is reported as a
FAILURE telling you to delete the holdout. `boolean.json`, `boolean_normalize.json` and `planar.json`
currently declare **zero** `_known_gap` holdouts — every pinned key is live.
`check_corpus_manifest.py` enforces required consumers, active-port symmetry where declared, and
orphan detection, **and is candid about its own blind spot** (it states outright that
`test_fixtures/svg` orphan detection is vacuous because Rust globs the directory).

---

## 4. THE EXPRESSION CORPUS — a real gate whose boundary must be understood before extending it

157 cases in `workspace/tests/expressions.yaml`, compiled by `scripts/compile_expr_corpus.py` into
`test_fixtures/expressions/conformance.json` (freshness enforced by `check_expr_corpus.sh`), driven in
**both** ports by structurally identical drivers, with the Python reference running the source YAML
directly. Genuinely pinned: `&&`/`||` as synonyms with correct precedence, short-circuit **and
value-returning** semantics (13 cases); `!` with `!=` winning by greedy lexing; **strict
trailing-token rejection**; three structural parse-error shapes; truthiness; strict typed `==`
including 3-digit colour normalization; `<`/`>` including the wrong-type arm; ternary; let/nested/
shadowing; lambdas of 0/1/2 params with **lexical** capture and an anti-dynamic-scope guard;
map/filter/fold/all/any with the uniform null-on-misuse convention; trig in **degrees** across 6
`atan2` quadrants; floored `mod` with mod-by-zero→null; end-exclusive `range`; `;` sequencing;
`mem`; numeric dot-index; dynamic `[...]` indexing.

**Two boundary facts that govern how any new fixture here must be written:**

1. **The gate's number tolerance is 1e-9 ABSOLUTE.** Every divergence smaller than that is invisible
   to the expression corpus — **which is the colour bug's exact mechanism**: a sub-tolerance float
   difference that becomes a different committed byte after rounding. A 1-ULP `hypot` difference at
   magnitude 1e3 is ~2e-13 and would pass **even if a case existed**. Any new float-primitive fixture
   must therefore phrase the difference into a **string** (via `"" + expr`) or a **colour**, both of
   which compare byte-exactly.
2. **Both drivers contain a content-free `type: "list"` branch that passes on any list regardless of
   contents.** Zero of the 157 cases use it today (70 number / 46 bool / 16 null / 13 string / 12
   colour), so it is latent — but **the first list-returning fixture added would be unasserted in both
   ports simultaneously.**

**Colour scope correction.** The claim "colour has no family" is **too strong for the expression
layer even at the baseline**: the expression corpus already touched `hsb_h`/`rgb_r`/`invert`/
`complement`/`hsb` at three colour points. What was true is that every input was a **fully saturated
primary** (`#ff0000`, `hsb(120,100,100)`) — exactly the inputs where rounding order **cannot** bite,
because every intermediate is 0.0 or 1.0. The proven bug lived at r=0.4, the mid-range the corpus
never visits. `color_convert` now covers that mid-range for the four conversion primitives; the
**expression builtins** `cmyk()`, `grayscale()`, `cmyk_c/m/y/k()`, `hsb_s()`, `hsb_b()`, `rgb_r/g/b()`
still have **zero** cases (rows #11 and, one-port-only, `rgb_r/g/b` — **[SUSPECT]** the colour sweep
could not find `rgb_r/g/b` in Swift's decompose switch and explicitly flagged it as needing a
five-minute confirmation; I did not re-check it).

---

## 5. STRUCTURAL GAPS IN THE MACHINERY

**These cap what the corpus can ever gate, and are worth more than any single family.**

**5.1 — Family names create false coverage. The single most useful lesson here.**
`hit_test` gates 7 scalar predicates while the two functions that decide what the marquee selects —
carrying the per-element-kind dispatch and the transform inverse-mapping, i.e. **all the branching** —
are in **neither** roundtrip binary. `element_bounds` has the same shape one level down: 17 vectors,
**every one** with `"transform": null`, so the name says bounds are gated while the transform-aware
variant the Properties panel actually shows is not. `flatten` gates a **different function**
(`flatten_path_commands`) than the one the boolean pipeline calls (`flatten_path_to_rings`). A
family-name-level audit reports all three as covered. **Only the brief's rule — a primitive absent
from the roundtrip binaries is uncovered even if a fixture mentions it — catches them.**

**5.2 — Two registered families are vacuous. [V-HEAD, counted]**
`flatten.json`: 3 vectors, and a literal-count over the whole file gives `"C"`=0, `"Q"`=0,
`"CurveTo"`=0, `"QuadTo"`=0 — **not one curve command anywhere**, so it gates the subpath-close
bookkeeping and **nothing** about subdivision, which is the part that differs.
`fit_curve.json`: 7 vectors, all named for their degeneracy — every one returns at the `n_pts == 2`
early exit or through the collinear fallback; **none** reaches `generate_bezier`, `reparameterize`,
`newton_raphson`, or the recursive split. **The gate is registered, driven, and vacuous for the actual
Schneider algorithm.** These are cheaper to arm than anything else in this document: the families,
registration and comparison strategies already exist, so it is **fixture-only work**.

**5.3 — `polygon_set_area` misreports, and the harness's own instruments are ungated.**
`algorithm_roundtrip.rs:869-880` signs each ring by **nesting depth** (count of other rings containing
`ring[0]`; even→+, odd→−). Correct only for a **canonical** set: for two **partially overlapping**
rings both get depth 0, so it reports A1+A2 instead of A1+A2−2·overlap. Meanwhile `is_ring_simple`
checks self-intersection **within one ring only**. Therefore **no harness predicate detects inter-ring
partial overlap at all**, and a normalizer regression that left such an overlap in the output could
still satisfy both the `area` and the `all_rings_simple` goldens. Compounding it: these three helpers
are **hand-duplicated** in the two roundtrip binaries and **nothing compares the two copies** —
`compare_exact_boolean` compares only `rings`, and the oracle runs against `ref_lang = rust` alone. So
Swift's copies are computed on every run, emitted into the payload, and **read by nobody**. That is
the same class of thing as an overlay deriving h/s/b differently from the conforming function beside
it: **the measuring instruments can drift silently.**

> **RESOLVED 2026-07-26 (POLYAREA).** Both halves. The metric is now an exact even-odd net area
> computed by a y-band scanline (`jas_dioxus/src/algorithms/polygon_metrics.rs`,
> `JasSwift/Sources/Algorithms/PolygonMetrics.swift`), correct for partially overlapping and
> self-crossing rings and independent of which vertex a ring is listed from. Measured on two
> 10x10 squares overlapping in a 4x4 corner: the depth heuristic answered **200.0** when the
> second ring was listed from a vertex outside the first and **0.0** when it was listed from a
> vertex inside — one region, two answers — against the true 168.0. The instruments themselves
> moved from hand-copies in five files (three Rust, two Swift) to one copy per port, and the new
> `polygon_metrics` corpus family drives them directly — no boolean operation in the loop — with
> every expectation derived independently (shoelace, exact rectilinear cell decomposition, and a
> dense-grid Riemann sum). **No existing golden changed**: all 33 pinned `area` values in
> `boolean.json` and `boolean_normalize.json` are reproduced bit-for-bit by the new metric, which
> also says every one of today's outputs is canonical. `is_ring_simple` is still intra-ring only,
> by design; inter-ring overlap is now the `area`'s job.

**5.4 — The codec gate's real coverage is "the field subset some fixture happens to populate."**
Every codec gate is a canonical-JSON before/after comparison, which catches a dropped field
perfectly — **but only for fields a fixture sets.** A grep of all 25 `test_fixtures/expected/*.json`
for the eight most divergence-prone keys (`mode`, `mask`, `fill_gradient`, `stroke_gradient`,
`fill_rule`, `tool_origin`, `dash_align_anchors`, `width_points`) returns **zero hits**. The gate
**passes loudly and says nothing about what it did not exercise**, which is exactly the region where
`CommonProps` loses 3 of 9 fields, both gradients and the stroke brush are hardcoded to `None`, and
`Document` loses 4 of 8. **The highest-leverage single repair in the serialization domain is not a new
family — it is ONE maximal fixture per element type with every optional field set to a non-default
value.** That one file red-lights rows #3, #18, #19, #20 and Swift's `transform: nil` at once.

**5.5 — The canonical test-JSON cannot represent multi-line text.**
Neither writer escapes control characters U+0000–U+001F (`test_json.rs:61`, `TestJson.swift:31`), so a
text element containing a newline serializes to **structurally invalid JSON in both ports**. It fails
**loudly** (both parsers reject), so it is not a silent divergence — but it is a hard ceiling: the byte
oracle behind all three codec gates structurally cannot express multi-line text, so **no fixture can
be added for it until the writer is fixed.** Verified: no `\n`, `\t` or `\u` anywhere in
`test_fixtures/expected/`.

**5.6 — Swift has two effect dispatchers that disagree, and the corpus drives the wrong one.**
`Effects.swift` registers the full verb set and reads panel state; `LayersPanel.swift:839` registers
**4** boolean verbs and hardcodes defaults. The Swift action-corpus arm goes through **the second**, so
the corpus gates the menu/test-fifo dispatcher while the user's Boolean-panel clicks go through the
other. Whatever the corpus proves about Swift booleans, **it proves about a path the panel does not
take.** This is the same defect class as the Colour-panel overlay calling past its own conforming
`rgbToHsb` — and `LayersPanel.swift:800-812` **already carries a comment describing CPTRIAGE catching
this exact two-dispatcher divergence for colour writes.** It has now recurred in the boolean domain,
which argues for a **shared registration** rather than a third per-domain patch. **[V-HEAD]** And row
#15 shows the pattern is not even confined to Swift: Rust has a second Color-panel reader
(`PanelColorState`) deriving from the float colour, off the corpus-gated `panel_channels` path.

**5.7 — The identity-view blind spot.** No fixture sets `zoom_level` or `view_offset`; both runners
build the model at the identity view where screen↔doc is algebraically the identity. **The
multiply/divide-by-zoom half of every tool is ungated**, and no fixture can currently express
otherwise — the runners would need a view-state seed. This is a machinery limit, not a missing family.

> **ROW NARROWED — VIEWSEED, 2026-07-27.** The machinery limit is gone: both runners in both ports
> take an optional `view` seed, and the action runner an `expected_view` assertion. `test_fixtures/
> actions/view_state.json` (7 vectors, spec-derived from ZOOM_TOOL.md's anchor/clamp block via
> CPython) and `test_fixtures/gestures/draw_rect_zoomed.json` (1 vector) are the first fixtures
> anywhere that set the view. **9 of the 72 action/gesture driver cases now run off the identity;
> 63 still do not**, so the row is narrowed, not closed — see the re-measured `identity-view-only`
> row in `scripts/corpus_manifest.json` for what remains and for the per-family unblock.
>
> The family found **two Swift bugs neither this section nor row #8 predicted**, both fixed:
> `LayersPanel.dispatchYamlAction` registered **no `doc.zoom.*` handler at all** (so all six View
> verbs were silent no-ops through the generic dispatcher, while the Zoom *tool* could zoom), and
> its eval ctx carried **no `preferences` namespace** (so `factor: preferences.viewport.zoom_step`
> evaluated to 0 and a zoom-IN clamped the canvas to `min_zoom` — a zoom-in that zooms all the way
> out). Rust had both.
>
> **Correction to this section's own account of #6.** It says Swift anchors at "the document
> origin's screen position". Measured through the action dispatcher it anchors at **screen (0, 0)**,
> the canvas top-left, because Swift also fails to merge an action's declared param **defaults**, so
> `param.anchor_x` arrives as null→0 rather than the declared −1. The `< 0 ? px` fallback the row
> cites is real but is never reached. Two causes, not one; both recorded in
> `view-anchor-default-divergence`.

**5.8 — The `bind.*` value surface is unpinned in both ports.** `panel_widget_tree` records the
**sorted key names** of `bind`/`style` and nothing about their values, and deliberately does not
evaluate dynamic visibility (`widget_tree.rs:102` collapses it to a `dyn_visible: true` flag "so the
snapshot stays eval-free"). `panel_layout` resolves `{{ }}` but pins only
`codepoint_count(text) * 10`, so **any two strings of equal scalar length are indistinguishable to the
gate — `"664040"` vs `"664141"` would pass.** That is the colour bug's byte pattern, in the gate.
Panel `visible`/`enabled_when` booleans are gated only for **menus** (`menu_state`, 4 vectors).

**5.8 — PARTLY CLOSED 2026-07-26** (`BINDVALUE`). The stated unblock — "a value-level panel
snapshot family that resolves `bind.*` expressions and pins the resulting strings, not their
lengths" — is built, as a THIRD pass rather than a widening of `panel_widget_tree`: that family's
key-names-only contract is what makes it stable, and widening it would rewrite every record it
emits. `bind_values(panel, ctx)` emits one `{path, id, key, type, value}` record per resolved
binding, pre-order, on `widget_tree`'s path scheme; values come only from each port's existing
`{{ }}` interpolation coercion, so no new number-formatting surface appears. Landed in all three
LIVE implementations (reference, Rust, Swift), pinned by
`test_fixtures/algorithms/panel_bind_values.json` — **4 vectors, 225 rows**, seeded by expression
SHAPE (a colour swatch, length_input numerics, the five conditional `bind.visible` containers, two
nested `foreach` levels including a `{{ }}` label). Both ports matched the reference-generated
golden on their **first** run.

**The claim in this section is now a test, not a sentence.** Each of the three implementations
asserts it directly: the two data scopes differing only in `panel.hex` — `"664040"` vs `"664141"` —
give byte-identical `widget_tree` output *and* byte-identical `layout_panel` rects, and differ in
exactly one `bind_values` row (`cp_hex`, `bind.value`). Re-injecting the defect (canonicalizing a
string to `len=N`) turns that assertion red in both ports, with the diff count falling to 0.

**What did NOT close, measured on the same commit:** 311 declared `bind` entries across the 16
panels, of which **136** are in the three seeded panels (color 82, stroke 36, swatches 18) and
**175** are not — paragraph (30) and character (24) are the largest uncovered. Panel
`enabled_when` is gated by nothing: **3** nodes carry it, all in `gradient_panel_content`, all with
the literal expression `false`; the arm was deliberately NOT added to the three passes, because
adding it without a seeded gradient vector would ship an unexercised branch. And `panel_layout`
itself is untouched — still `chars().count() * 10` / `unicodeScalars.count * charWidth`. The
`panel-text-width-scalar-count-only` `coverage_gaps` row carries all of that residue.

**5.9 — Two harness self-inconsistencies to fix before extending, or the first new vector is
mis-triaged.** (a) The text harness injects `chars().count()` in Rust and `s.count` in Swift (#26) —
**fix the harness before adding any non-ASCII vector**, or the failure will be attributed to
`layoutText` and possibly held out as a known gap. (b) `corpus_manifest.json`'s `known_gaps` is
**`[]`** [V-HEAD] — the manifest currently asserts no gaps while §5.1–5.8 stand. Every row in this
census that survives triage belongs there.

**5.9 — CLOSED 2026-07-26** (`HARNESSUNIT`, `CORPUSGAPS`). Both legs, with three of this
document's own figures corrected in the process.

**(a) The harness half is fixed; the product half it was hiding is now recorded.** The unit was
decided from the reference, not from either port: `jas/tools/algorithm_roundtrip.py` injects
`len(s) * char_width`, and `len` on a Python `str` counts **scalars** — so Rust was already right.
Each port now has one named, unit-tested helper (`fixed_char_width_measure` /
`fixedCharWidthMeasure`) and all **three** call sites per port route through it, enforced by a
preflight in `cross_language_algorithms.py` that names the offending `file:line` (three inline
copies per port is the shape that drifted once). Effect, measured at `char_width` 10: total line
advance now **agrees** — 40 for `"a" + "e" + U+0301 + "b"` (4 scalars, 3 clusters) and 50 for
the ZWJ family emoji `U+1F468 U+200D U+1F469 U+200D U+1F467` (5 scalars, 1 cluster), where Swift
previously gave 30 and 10. **The residual is a PRODUCT divergence, not a harness one**: Swift's
TWO layout files index `Array(content)`, i.e. grapheme clusters (TextLayout.swift and PathTextLayout.swift; TextLayoutParagraph.swift was cited here in error and contains no `Array(` at all), so `char_count` is 3 and 1 where
Rust and the reference give 4 and 5. A non-ASCII vector still cannot be added — the rust-vs-swift
comparison has no oracle-holdout mechanism (only `property_planar` and `exact_boolean` do), so the
vector would simply red the gate. Recorded as coverage gap `text-index-unit`, whose unblock is the
point: closing it means moving `TextEditSession`/`TypeTool`/`TypeOnPathTool` onto scalar indices in
the **same** sweep, since they do cursor arithmetic in `Character` counts. `TextLayout.swift`'s
"mirrors `text_layout.rs`/`.py`" header no longer claims more than it does.

**(b) `known_gaps` was empty for a STRUCTURAL reason, and the fix is a second list.** `known_gaps`
is a *suppressor* keyed to one mechanical check on one family/file, so it can only speak about a
check the script already runs — **no row in §5.1–5.8 is of that shape**, which is why populating it
was never actually possible. The manifest now carries `coverage_gaps`: declarative, suppressing
nothing, shape-validated (`id`/`title`/`evidence`/`blocks`/`unblock` required; unknown keys,
duplicate ids and an *absent* key are all errors), and **printed on every run before the verdict**.
`known_gaps` became self-policing in the same pass — a row that suppressed nothing is reported
`stale-known-gap`. Nine rows landed: `text-index-unit`, `element-bounds-untransformed`,
`flatten-wrong-flattener`, `flatten-no-curves`, `fit-curve-first-pass-only`,
`codec-optional-fields-unset`, `codec-no-control-chars`, `identity-view-only`,
`panel-text-width-scalar-count-only`.

**Three figures above did not survive re-measurement, and this is the argument for §0's warning
applying to §5 too:**
- **§5.2** — `fit_curve` **does** reach `generate_bezier`: probe instrumentation of `fit_cubic`
  driven by the fixture shows **3 of 7** vectors reach it (the three with `n_pts > 2`). What it
  reaches **zero** times is `reparameterize`, `newton_raphson` and the recursive split, because
  every one of those three fits inside tolerance on the first pass. The row's conclusion stands;
  its mechanism did not.
- **§5.4** — `test_fixtures/expected/` holds **39** `.json` files, not 25. The eight-key claim
  itself holds: zero of the 39 set any of them.
- **§5.1** — the `hit_test`/marquee leg has **CLOSED**. `element_intersects_rect` and
  `element_intersects_polygon` are now driven by **both** roundtrip binaries over **6** of that
  family's **40** vectors, so the family gates 9 predicates, not 7. Not recorded as a gap. The
  `element_bounds` leg (17 of 17 vectors at `transform: null`) and the `flatten` leg both stand.

§5.3, §5.6, §5.10 and §5.11 are deliberately **not** in `coverage_gaps`: they are real, but this
pass did not re-verify them, and an unverified row there would be the same false assurance the
empty list was.

**5.10 — A forward-looking hazard needing a ruling.**
`binary_read_python_fixtures` (`cross_language_test.rs:167`) pins `.bin` **bytes** against blobs
generated by the **frozen** Python Qt port. The moment an active port adds a slot, that generator
cannot be re-run at HEAD, so the byte pin must be hand-regenerated or it **silently narrows** to "the
fields that existed at the `five-port-parity` tag." FILLRULE has now added a `TAG_PATH` slot, so this
needs an explicit ruling rather than a quiet regeneration.

**5.11 — A shared-bug class no app-vs-app gate can ever see.** Two confirmed instances, both
**identically wrong in both ports** and therefore invisible to a Rust==Swift comparison, catchable
only by a **pinned golden**: `pattern_along_path.rs:64` / `PatternAlongPath.swift:52` take
`n = max(1, floor(total/step))` with no epsilon, so an accumulated total of 99.999999999999986 yields
3 copies instead of 4; and `fit_curve` compares the **squared** `max_error` against the **linear**
`error` (Schneider's original quirk) in both ports. This is the argument for the oracle-holdout
mechanism existing at all, and for extending it rather than relying on port-vs-port alone.

---

## 6. DELIBERATE NON-GOALS

- **`jas_ocaml/` and `jas/` (the Python Qt app) — FROZEN** at `five-port-parity` (POLICY.md §1).
  Not censused, not counted, not edited. They honour the tag, not new corpora; their CI lanes are
  tag-pinned toolchain canaries. The one place they still matter is §5.10, where the frozen Python
  port is the **generator** of a live byte pin — that is a machinery hazard, not a parity target.
- **`jas_flask/` — non-gating** reference renderer (TESTING_STRATEGY.md §6). Not a source of truth,
  not an interactive-parity target, out of scope.
- **`workspace_interpreter/` (Python) is IN scope as the blocking reference**, but only for *spec
  meaning*, not as a parity party. Two rows turn on it and are reported as reference divergences
  rather than port divergences: `dash_renderer`'s banker's-vs-away-from-zero rounding (#34), and
  string `.length` returning **scalars** where Rust returns bytes and Swift graphemes (#52).
- **Not blind spots, so deliberately not ranked** — recorded so nobody re-opens them:
  `preferences.yaml:18-25` declares `smart_guides.snap_threshold_px` and `grid.spacing_px/
  subdivisions` and **neither port implements them** (grep for `smart_guides`/`smartGuides` over both
  trees returns nothing; there is no snapping, ruler or grid code) — a **future** family, not a gap.
  `shorten_path`/`shortenPath` carries a real divergence (Rust's end-setback loop matches `QuadTo`,
  Swift's omits it) but has **zero callers in either port** and `arrow_trim.rs:3` calls it "legacy" —
  a **cleanup** item; flagged only because re-wiring it would ship the divergence.
  `incremental_add_stroke` is `#[ignore]`/`.disabled` in both ports with **empty bodies** — a named
  future, not a blind spot (the same empty-shell pattern the boolean-degenerates round caught five
  of). `PlanarGraph` has **zero production call sites** (#62). The ~70 print-preferences attributes
  Rust reads and Swift does not are a **known deliberate deferral** (Rust Phase 1A/1B landed,
  cross-app propagation pending), not a census row.
- **`RecordingPainter` exists only in Rust** (`painter/recording.rs`) and is not in
  `corpus_manifest.json`, so the display-list gate is Rust-only. Relevant to the
  display-list-equivalence doctrine (Option A) and to #43, but it is a **rendering-architecture**
  question — Swift's gradient resolution would have to be lifted behind a Painter before a
  `RecordingPainter` golden could be **shared** rather than Rust-only. Out of scope as a census row;
  in scope for the Painter roadmap.
- **Blend-mode math** is delegated to `globalCompositeOperation` and `CGContext` in the two ports —
  **no shared numeric primitive exists to gate.** Likewise gradient-stop interpolation (CanvasGradient
  vs CGGradient) and pad/clamp spread: **parity by delegation.** If a spread mode is ever added to the
  model it becomes a first-class gap immediately.

---

## 7. R9 — SATURATING CAST vs TRAPPING INITIALISER (PROMOTED, and largely repaired)

**Status 2026-07-26: promoted into the taxonomy and repaired across the sites five read-only sweeps
enumerated.** JYH ratified the repair the same day ("do it now, nothing is gained by waiting"). Read
this section as the taxonomy entry plus the repair's record; §7.1 below lists what is banked.

The repair's own commits are the reference for what the rule now is:

- `R9: clamp colour-channel INPUTS in cmyk / grayscale / hsb, all three ports`
- `R9: the Swift-side trap sites the sweep found reachable, with Rust's saturation`
- `R9: the sites where a guard does not reject NaN, and one guard asymmetry`
- `R9: clamp a dialog number_input's commit to its declared bounds`

**The two rules the repair established.** Where a value has a DOCUMENTED range, clamp the INPUT before
any arithmetic (`color_util::clamp_channel` in Rust, `clampChannel` in Swift, `clamp_channel` in the
Python reference). Where a conversion merely mirrors a Rust `as` cast with no range to appeal to, route
it through a function that spells that cast out (`Sources/SaturatingCast.swift`: `saturatingInt`,
`saturatingUInt32AsInt`, `intIfIntegral`; plus `saturatingUInt8` and the pre-existing `quantise8` in
`Interpreter/ColorUtil.swift`).

Input-clamping is not interchangeable with output-saturation, and the colour primitives are the proof.
The formulas are monotonic per channel, so for ONE out-of-range channel the two agree. They diverge
when two channels overflow with signs that multiply back positive: unclamped, `cmyk(150, 0, 0, 150)`
is `(1-1.5)*(1-1.5)*255 = +63.75`, i.e. `#400000` — a bogus mid-grey that looks like a real colour —
and `cmyk(200, 0, 0, 200)` is a fully saturated `#ff0000`. Clamping the inputs gives black. It is also
the only form in which no saturating-cast asymmetry survives to disagree about. Both are now
corpus-pinned (`workspace/tests/expressions.yaml`, 13 new cases, run by Rust, Swift and the Python
reference).

The class also had **three members that are not crashes**, which is the reason a fix pass must not
simply re-spell every cast: `colorStr` wrote `rgb(510,0,0)` into a saved SVG (not valid CSS colour
syntax) where Rust wrote `rgb(255,0,0)`; `Svg.swift`'s inline-size line count was
`Int(x) + 1` against Rust's `ceil(x)`, an extra line of height at every exact integer; and
`segments_for_arc`'s guards were not mirror images, so a NaN radius gave 32 ring segments in Swift and
8 in Rust with no crash on either side.

The original proposal, kept verbatim:

> **R9 — SATURATING CAST vs TRAPPING INITIALISER.** Rust's `as u8` / `as i64` casts **saturate**

> **R9 — SATURATING CAST vs TRAPPING INITIALISER.** Rust's `as u8` / `as i64` casts **saturate**
> (guaranteed since 1.45) and map NaN to 0. Swift's `UInt8(Double)` / `Int(Double)` initialisers
> **trap**. This is not R1 (a value differing) — it is *one port returns a clamped value, the other
> **crashes***.

Confirmed sites: `grayscale()` and `cmyk()` (`ExprEval.swift:1148` — **no clamp at all** [V-HEAD]);
`hsbToRgb` (`ColorUtil.swift:77-79`); `valToUInt8` (`UInt8(clamping: Int(n))` — the clamping applies
**after** the trapping cast); `hsbToRgbComponents` (`Int(floor(nan/60))`); `colorStr` in SVG export;
`segmentsForArc` (`Int(n.rounded(.up))` on a non-finite radius); the parser's numeric dot-index; and
`Value.toAny()`, which **every** `let` binding, lambda-parameter bind and `foreach` item bind flows
through. Rust's paired `.max(0.01)` / clamping habits mean **Rust reaches these functions with values
Swift cannot survive.**

Every site in that list is repaired. The class was enumerated by five read-only sweeps over
`JasSwift/Sources/{Interpreter,Geometry,Algorithms,Canvas,Panels,Tools,Document,Workspace}`, each
judging its rows against the `jas_dioxus` twin.

### 7.1 What is BANKED — the rows deliberately not repaired

These survived the pass. Each is listed with its file:line and the reason, so a later pass does not
have to re-derive it.

1. **`JasSwift/Sources/Document/Document.swift:37, :42, :61** — `SortedCps` narrows a control-point
   index with `UInt16(i)`, which TRAPS at 65536, where Rust's `i as u16` **wraps** and silently
   selects control point 0 instead (`document.rs:61, :67, :70, :84`). This is int→int, not
   float→int, and neither port is CORRECT: mirroring the wrap would trade a crash for a silently
   wrong selection, which is a product decision and not a cast fix. Needs ≥65536 control points on
   one path (a machine-traced SVG, not hand drawing).
2. **`YamlPanelBodyView.swift` `renderComboBox`** — the TRAP is fixed (it routes through
   `saturatingInt`), but a DIFFERENT_VALUE remains: Rust keeps the bound value an `f64` and renders
   `12.5`, where this port renders the truncated `12`. Closing it means changing what the widget
   DISPLAYS, which no unit test reaches.
   **`renderNumberInput` was the other half of this row and is CLOSED** (NUMBERINPUT, 2026-07-26):
   its bound value is a `Double` rendered with `numberToCanonicalString`, the same rule the
   expression corpus already gates. Two corrections to what this row used to say — the panel
   widget-tree goldens do **not** cover a widget's displayed value (`WidgetTree.swift` records the
   sorted `bind` / `style` KEY SETS, not values, and `scripts/check_panel_goldens.sh` still passed
   unchanged after the display change), and the number field's COMMIT was a second, larger
   divergence in the same function: `Int(newVal)` dropped every non-integer entry silently. Both
   ports now share one commit rule, pinned by `test_fixtures/algorithms/number_commit.json`.
3. **`Geometry/Binary.swift:468-481` (`asInt` / `asF64`)** — the trap is fixed, but the decoder's
   CONTRACT still differs: Rust's `as_i64` REJECTS a float outright and returns `Err` so a corrupted
   blob cannot abort the module (its comment at `binary.rs:551-559` says why, and
   `malformed_but_decodable_blob_errors_not_panics` pins it), while this port truncates a float and
   uses `fatalError` for every other type mismatch. That is a decode-recoverability gap, wider than
   R9, and it touches 12 call sites plus error propagation.
4. **`Tools/YamlToolEffects.swift:151` (`data.list_remove`)** — a NEGATIVE index no-ops here and
   removes element 0 in Rust (`effects.rs:816`, `as usize` maps -1 to 0). Which behaviour is right is
   a semantics call, not a cast fix; the effect has zero YAML callers repo-wide.
5. **`Workspace/LayoutApply.swift:213`, `Tools/YamlToolEffects.swift:3077`,
   `Interpreter/ExprTypes.swift:80`** — three places where this port ACCEPTS a value Rust rejects (a
   fractional or negative JSON number where Rust's `as_u64()` returns `None` and falls back to 0 or
   to a string). All three are latent: on Darwin the `NSNumber` branch wins for every `Double`, and
   the markers are only ever produced by the ports' own serialisation.
6. **`Algorithms/CalligraphicOutline.swift:113`, `PatternAlongPath.swift:52`,
   `Tools/YamlToolEffects.swift:2237/:2246`, `Geometry/LiveElement.swift:1040`** — the traps are
   fixed and the ports now agree, but for an INFINITE input both ports agree on a saturated segment /
   tile / sides count and then attempt an astronomically large allocation. A shared OOM is not a
   divergence, so it is out of this class; capping either port alone would create one.
7. **`fmtNum` / `_fmtNum` NaN spelling** — `String(format: "%.4f", .nan)` gives `nan` here where
   Rust's `format!("{:.4}", f64::NAN)` gives `NaN`. Not a cast; a formatting difference, and the same
   one `Geometry/TestJson.swift` has for a NaN coordinate.
8. **Rust's own saturating casts that make RUST the diverging port** —
   `jas_dioxus/src/algorithms/dash_renderer.rs:259` round-trips a dash multiple through `i64` where
   JasSwift stays in `f64`. Needs a value above roughly 1.8e19 × the base period; no gesture found.

### 7.2 The mechanical closure check

Two greps over `JasSwift/Sources`, with labelled initialisers (`clamping:`, `exactly:`,
`truncatingIfNeeded:`, `bitPattern:`, `radix:`, `utf16Offset:`) and comment-only lines filtered out.

**(a) Lines carrying an integer initialiser AND float-producing syntax** — the pattern is
`\b(UInt8|Int|UInt32|Int32|UInt|Int64|UInt16|Int16)\(` piped through
`\.rounded\(|floor\(|ceil\(|round\(|Double\(|CGFloat|\.nan|\* 255|/ ` (two stages, because a
single regex cannot span the nested parens these expressions use). **19 hits, and every one is
accounted for.** 7 are the colour primitives whose INPUTS are now clamped, so their products are in
range by construction (`ExprEval.swift:1151-1153, :1160`; `ColorUtil.swift:119-121`). 6 take a `UInt8`
or an already-guarded value (`ColorUtil.swift:51-52, :199-202` — `rgb_to_cmyk`'s `r==g==b==0` early
return is exactly the case that would otherwise make its divisor zero). 1 is `Int.init?(String)`
(`Svg.swift:778`). 2 are `Element.swift:164`, now behind the non-finite-hue sanitise, and
`Boolean.swift:321`, whose `if target <= 0.0 || !target.isFinite { return nil }` two lines above is
the exemplary form. The last 3 the sweeps re-verified as provably bounded and this pass left alone:
`WorkspaceIcon.swift:817` (|deltaTheta| <= 3pi, so `ceil` <= 5), `TextEditSession.swift:14`
(wall-clock ms / 530), `CanvasSubwindow.swift:545` (|dtheta| <= 3pi, proved by running the body).

**(b) An integer initialiser applied to a BARE identifier**, where grep cannot see the argument's
type: `\b(UInt8|Int|...)\([a-z_][A-Za-z0-9_]*\)`. **32 code lines, every one accounted for**: 3 are
inside `saturatingInt` / `saturatingUInt32AsInt` / `saturatingUInt8` themselves, immediately after
their own bounds tests; 12 are `Int.init?(String)` (failable, cannot trap); 14 are integer→integer
conversions whose argument is a loop index, a `UInt8` channel, or a value an adjacent explicit range
test has already bounded (the `Binary.swift` encoder's six are each preceded by their own
`n >= X && n <= Y`); and **3 are the banked `Document.swift` `UInt16` narrowings** of item 1 above.

**What that grep cannot see:** a conversion performed inside a generic helper or a protocol witness
(`BinaryInteger.init(_: some BinaryFloatingPoint)` reached indirectly — no `numericCast` exists in
the tree, but absence of that spelling is not proof); an `Int`-typed parameter whose float argument is
computed several frames up the call stack; integer OVERFLOW on `+` / `*` / `<<`, which traps in Swift
and wraps in Rust release builds and is a DIFFERENT class; and the SwiftUI / CoreGraphics entry points
called with a NaN from our code. The repair is also **not GUI-verified**: the trap semantics and the
call chains are proven by tests and by reading, but no site was reproduced in a running app.

---

## 8. IF THE NEXT STEP IS REPAIR — the order the evidence supports

1. **Re-verify before scheduling.** 89 commits landed under the sweeps. Every `[V-BASE]` row needs a
   5-minute re-check; the `color_convert` case proves an entire domain's headline can close between a
   sweep and its census.
2. **Arm the two vacuous families** (§5.2). Fixture-only work — registration, runner and comparison
   strategies already exist. Add curve vectors to `flatten.json` and non-degenerate vectors to
   `fit_curve.json`. Highest ratio of gate gained to work done in this document.
3. **Wire the three element-level `hit_test` arms** (#5). A missing `case`, not an epsilon; reuses the
   existing `exact` strategy and fixture file. Categorical consequence.
4. **The one maximal serialization fixture** (§5.4). One file per element type with every optional
   field non-default red-lights #3, #18, #19, #20 and Swift's tspan `transform: nil` together.
5. **The boolean cluster ruling** (#1–#3), fixed as one item: Swift's default contradicts
   `workspace/state.yaml`, the collapse function it thereby runs has the numerically weaker formula,
   and the rebuild consuming its output drops `CommonProps`.
6. **Shared effect registration** (§5.6) rather than a third per-domain patch — this is the second
   recurrence of the two-dispatcher defect, and #15 shows Rust has its own instance.
7. **Seed view state in the action runner** (#6–#8, §5.7) — retires the identity-view blind spot for
   every future tool fixture, not just zoom.
8. **Fix the text harness before adding non-ASCII vectors** (§5.9a), or the first new vector is
   mis-triaged.
9. **Populate `known_gaps`** (§5.9b). The manifest currently asserts no gaps; every surviving row
   belongs there. **That is the durable output of this census** — a census that is not written into
   the machinery decays back into a blind spot in one wave, which is exactly what happened here.

---

*Read-only census. Nothing under `/Users/jyh/projects/claude/jas` was modified, added, or committed.
Scratch notes and the sweeps' throwaway verification programs are in the session scratchpad.*

---

## 9. RESIDUALS FROM THE OVERNIGHT QUEUE (2026-07-26, batch 1)

> **BOTH RESIDUALS CLOSED, batch 2 (2026-07-26).** Read §9.1 before acting on
> anything below: (b)'s stated conclusion — "Rust is right" — was **WRONG**, and
> the fix went the other way. The two subsections below are preserved as the
> evidence the lens actually drove, not as standing verdicts.

Batch 1 closed four census rows. Three landed clean; **row 5 and the hypot row are
NOT fully closed**, recorded here so closing the batch does not lose them.

**(a) TWO OF SIX HYPOT SITES ARE UNPINNED — production code is CORRECT, the pin is
missing.** `JasSwift/Sources/Geometry/PathOps.swift:171,182` (closestOnCubic's
coarse-scan `d` and `d2`) and `jas_dioxus/src/geometry/path_ops.rs:533,547`.
Reverting each INDIVIDUALLY leaves the full suite and the cross-language gate green;
the writer's mutation reverted all six at once, which masked it.
**The root cause is worth remembering: the overflow test puts the true answer at
t=0, which is exactly where both failure modes also land** — `best_t` starts at 0.0
so a saturating coarse scan never updates it, and the trisection collapses to lo=0,
so `t < 1e-5` passes either way. A test whose expected value coincides with the bug's
output is not a test. The lens supplied the discriminating vector:
`closest_on_cubic(0,0, 1e200/3,0, 2e200/3,0, 1e200,0, 5e199, 1e200)` -> expected
(1e200, t=0.5); observed with the naive form t=0.0199969927 (an 11% distance error)
at :533 and t=0.4800060146 at :547.

**(b) CENSUS ROW 5 IS HALF DONE — the filled-polyline leg still ships.** The row reads
"`segmentsOfElement` has no `.live` case; filled polyline goes bbox-only". Only the
`.live` leg was fixed. Driven by the lens: a FILLED polyline
`[[0,0],[0,100],[100,100],[100,0]]` (a 'U') with a marquee at (40,20,20,20) in the
concave opening gives **Rust `false`, Swift `true`** — Swift's filled-polyline arm
returns `rectsIntersect(bounds...)` while Rust falls into the segments-based
catch-all. Unfilled agrees, and the lasso variant agrees, so it is specifically
**filled + marquee** — everyday marquee-select behaviour. ~~Rust is right: the concave
opening of a filled U is outside the fill.~~ **STRUCK — see §9.1(b).**

### 9.1 How the two residuals actually closed (batch 2, 2026-07-26)

**(a) The hypot row is closed by a new corpus family, not by a production change.**
The production code was correct in both active ports all along; the TEST was blind.
`test_fixtures/algorithms/path_project.json` (7 vectors, registered in
`cross_language_algorithms.py`'s `ALGORITHMS` as `path_project`, tolerance 1e-9)
pins `closest_on_line` and `closest_on_cubic` across Rust and Swift, with a
fast-suite twin of the discriminating vector in each port. Distances are reported
divided by a per-vector `scale`, because an absolute tolerance against a raw 1e200
distance is meaningless — one ulp there is ~1.6e184.

Goldens derive from `jas/geometry/path_ops.py`, read-only. That file belongs to the
frozen Python port, but it is the ONLY reference implementation of these helpers —
`workspace_interpreter/` carries no geometry module — and its body is
line-for-line the same algorithm over `math.hypot`.

All twelve sites (six per port) were mutated to the naive squares-first form ONE AT
A TIME and individually caught. The two the old test missed are the coarse-scan `d`
and the trisection `d2`, and they are caught **only** by
`cubic_overflow_point_above_middle` — confirming §9(a)'s diagnosis exactly, down to
the predicted t values (0.0199969927 and 0.4800060146).

**(b) Row 5's filled-polyline leg is closed by fixing RUST, not Swift — the lens's
geometric premise was wrong.** A `<polyline>` carrying a fill paints as though its
last point were joined back to its first (a canvas fill closes every subpath), so
`[[0,0],[0,100],[100,100],[100,0]]` **strokes** as a U but **fills** as the full
100x100 square. There is no "concave opening" in the fill; the marquee at
(40,20,20,20) is inside it. Checked against the reference: it answers `true`, i.e.
it agrees with **Swift**. Rust had no `Element::Polyline` arm at all and fell into
the segments catch-all — an omission, not a decision. Rust now carries the arm.

Recorded so the semantics are a ruling and not a drift: this arm is the element's
**bounding box**, not a point-in-fill test. Vector
`polyline_filled_marquee_in_bbox_outside_closed_fill` pins that deliberately — an
open triangle's empty bbox corner answers `true` in the reference and in both ports.

**Two findings from the sweep this row asked for, REPORTED not fixed:**

1. **No other element kind splits bbox-vs-segments between the ports.** Both
   `Element` enums carry the same twelve variants (line, rect, circle, ellipse,
   polyline, polygon, path, text, textPath, group, layer, live). Walking
   `element_intersects_rect_local` against `elementIntersectsRectLocal` arm by arm
   after this fix: line / rect / circle / ellipse / polyline / text agree; polygon
   and path agree (Rust reaches them through its catch-all, whose endpoints-in-rect
   clause is the same point set as Swift's vertices-in-rect for a polygon);
   textPath, group and layer are bbox in both (Rust names them, Swift's `default:`
   reaches them); `.live` agrees since batch 1. Polyline was the last one.

2. **The marquee and the lasso disagree with each other for filled
   Polygon/Path/Live — in BOTH ports and in the reference.** The lasso catch-all
   has an "any lasso vertex inside `elem.bounds()`" clause; the marquee catch-all
   has no matching "marquee corner inside bounds" clause. Measured, all three
   agreeing, on a filled 100x100 square:

   | shape | marquee (40,20,20,20) | lasso with the identical outline |
   |---|---|---|
   | filled Polygon | `false` | `true` |
   | filled Path    | `false` | `true` |

   So dragging a small marquee inside a filled square does not select it, while
   drawing the same square with the lasso does. This is shared, pre-existing, and
   NOT a port divergence — which is why it was left alone. Deciding it is a spec
   question (which is the intended marquee rule: Rect/Circle/Ellipse/Polyline's
   area semantics, or Polygon/Path's outline semantics), and the reference is
   internally inconsistent about it, so it wants a ruling rather than a patch.

---

## 10. OPEN AFTER BATCH 3 (2026-07-27, banked at the merge)

Five lens findings that did not block the merge. Two are real defects; three are
records that claim more than the code.

**(a) `element_ids` misses ids inside LIVE elements — the mint avoid-set is
incomplete.** `Element::children()` returns `None` for `Element::Live` (Rust,
element.rs:1431-1433) and Swift's `.live` falls to `default: break`, but
`CompoundShape` holds `operands: Vec<Rc<Element>>` — real child elements carrying
their own `common.id`. So a compound shape's operand ids are invisible to the
collision check, and both walks' doc comments ("every `common.id` present in this
document") are false. NOT A REGRESSION: the five open-coded walks this consolidated
had the same blind spot. Collision probability is negligible (8-char base36 ~ 2.8e12),
which is why it did not block. Fix = walk all four `LiveVariant` payloads in both
ports, with a cross-port test; correct the two comments at the same time.

**(b) A LIVE, PRE-EXISTING, UNDECLARED cross-port divergence in flatten's ClosePath
arm.** Rust guards the close — `if !pts.is_empty() { pts.push((sx, sy)); }`
(element.rs:2093) — and Swift appends `firstPt` UNCONDITIONALLY. **A path whose first
command is `Z` therefore diverges.** The lens proved it live with a throwaway probe
(`d = [Z, L(5,5)]`): `FAIL: flatten/PROBE_leading_close [rust vs swift]`. Decide the
right answer from the reference, then fix and gate it.

**(c) The `bind_values` list contract is unpinned.** All 3 list rows in the 225-row
corpus are the single-element `[lib1:0]`, so the documented "bracketed and
comma-joined element-wise" behaviour survives a mutation: changing the separator to
`;` leaves both ports' tests green. Needs a multi-element and a nested-list vector.

**(d) FALSE ACCOUNTING IN A COMMIT MESSAGE (durable record).** Commit `64282375`
says the carried set is "the WHOLE non-paint set" and then accounts for only EIGHT of
`CommonProps`' NINE fields — `name` is silently dropped, and `name` IS non-paint.
Cannot be corrected in place without rewriting history; corrected here instead.

**(e) Half a census claim is vacuous for the OLDER gates.** `widget_tree` and
`layout_panel` for `color_panel_content` return identical output for `{}` and a full
ctx — they ignore ctx entirely for that panel — and `layout_panel` is also identical
for an 11-character hex versus a 6-character one. The new value-level family is real;
the claim that the older gates were the ones improved is not.
