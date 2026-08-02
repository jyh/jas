# Geometry algorithm reference census — jas, HEAD, 2026-08-02

**Scope of the enumeration:** one row per module in `jas_dioxus/src/algorithms/` — 29 files, 28 modules plus `mod.rs`. The question each row answers is not "is this algorithm tested" but "if Rust and Swift disagreed tomorrow, is there a live thing that could say which one is wrong." Vector counts below were re-measured from the fixture files, not copied from the source notes.

---

## The count

**21 of 28 (75%) are reference-less** — 18 `frozen_only`, 3 `absent`. For three quarters of the geometry surface, the only Python that implements the algorithm is pinned at the `five-port-parity` tag (2026-07-22, out of default pytest discovery per `pytest.ini:10`, run `continue-on-error` off a tag checkout per `.github/workflows/test.yml:415-429`), or there is no Python at all.

Two other readings of the same table, because the boundary matters:

| Reading | Count |
|---|---|
| Literal status `frozen_only` or `absent` | **21 / 28** |
| No live Python *produces* the answer (adds `boolean`, `boolean_normalize`, and the producing half of `layers_filter`) | **24 / 28** |
| Nothing live can rule at all — no live producer *and* no registered analytic checker | **20 / 28** |

The gap between the second and third rows is the entire mitigation that exists today: `GEOMETRY_CHECKERS` at `scripts/cross_language_algorithms.py:813-817` holds exactly **three** keys — `gradient_remap`, `boolean`, `boolean_normalize`. Twenty-five of twenty-eight algorithms have no analytic law watching them.

For the 21 reference-less rows, a green corpus lane means Rust and Swift produced the same numbers. It does not mean the numbers are right. That is the `hit_test` condition, and `hit_test` is still on the list.

---

## The table

| Algorithm | Status | Corpus family (vectors) | Evidence |
|---|---|---|---|
| `hit_test` | frozen_only | hit_test (157) | Rust `hit_test.rs:505` `element_intersects_rect`, `:135` `element_intersects_polygon`. Only Python is frozen `jas/algorithms/hit_test.py:130,:234`, and it is **unreachable even at the tag**: `run_hit_test` dispatches 7 primitive names and `sys.exit(1)`s on anything else (`jas/tools/algorithm_roundtrip.py:160-186`). The interpreter's namesake is a different algorithm — a bbox scan (`workspace_interpreter/doc_primitives.py:92,108-111`) whose bounds come from frozen `jas/geometry/element.py` (`:79,:136`). Checker gap PHASE 3 (`cross_language_algorithms.py:877`). |
| `planar` | frozen_only | planar (12) | Rust `planar.rs:161` `build`, `:517-561` face queries. Frozen `jas/algorithms/planar.py:240`, wired at `jas/tools/algorithm_roundtrip.py:79,:323` but tag-pinned. Zero hits for planar/dcel/half-edge/face in `workspace_interpreter/`. Frozen Python defers T-junctions and collinear overlap (`planar.py:18-20`); Rust handles both (`planar.rs:44-53`) and 4 of the 12 vectors pin exactly that. Checker PHASE 3, blocked on an adapter, not the instrument (`cross_language_algorithms.py:883-888`). |
| `arrangement` | absent | arrangement (24) | Rust `arrangement.rs:153` `split_points`, `:76` `add_or_find_vertex`. No `jas/algorithms/arrangement.py`; no `arrangement` verb in the frozen runners dict (`algorithm_roundtrip.py:68-84`). Nothing in `workspace_interpreter/`. Nearest frozen code is the **superseded** predicate `jas/algorithms/planar.py:162 _intersect_proper`, which rejects the endpoint band outright at `:180-181` and has no collinear branch. `_add_or_find_vertex` (`planar.py:153`) does match line for line. |
| `offset_path` | frozen_only | offset_path (8) | Rust `offset_path.rs:193,:311`. Frozen `jas/canvas/offset_path.py` is a **rasteriser** — every entry point takes a `QPainter` and returns nothing (`:121,:201,:211`), so it cannot be driven as a reference in principle. No verb in the frozen 14-verb table (`algorithm_roundtrip.py:505-518`). Checker gap PHASE 4, two laws named and unwritten (`cross_language_algorithms.py:846-856`). |
| `calligraphic_outline` | frozen_only | calligraphic_outline (9) | Rust `calligraphic_outline.rs:34`; module header names its provenance as `jas_flask/static/js/engine/geometry.mjs`, i.e. JavaScript in the non-gating renderer. Frozen `jas/algorithms/calligraphic_outline.py:38`, and **not wired** — no key in the runners dict. The only `calligraphic` hits in the live interpreter are brush-type strings (`expr_eval.py:682`, `tests/test_loader.py:76`). Checker gap PHASE 2, ribbon law unwritten (`:843`). |
| `knuth_plass` | frozen_only | **none** | Rust `knuth_plass.rs:158` `compose`; Item Box/Glue/Penalty `:30-70`. Frozen `jas/algorithms/knuth_plass.py:70`. Zero hits in `workspace_interpreter/` for knuth/demerit/badness/glue/penalt. No fixture file, no ALGORITHMS row, no roundtrip verb in any port. Stated gap `scripts/corpus_manifest.json:778-781`. |
| `eyedropper` | frozen_only | **none** | Rust `eyedropper.rs:190,:228`. Frozen `jas/algorithms/eyedropper.py:166,:203`. The one interpreter hit says `eyedropper_cache` is deliberately absent from the bridge allowlist (`state_store.py:181`). No runner, no ALGORITHMS row. The 5 `test_fixtures` matches are toolbar vocabulary and a keyboard shortcut. |
| `magic_wand` | frozen_only | **none** | Rust `magic_wand.rs:69`, config `:19-45`, five tolerance literals `:49-59`. Frozen `jas/algorithms/magic_wand.py:108` with helpers `:73-104`. Zero hits in `workspace_interpreter/`. No fixture, no registry row, no verb. Gap reason at `corpus_manifest.json:779`: it takes a whole document plus a selection. |
| `shape_recognize` | frozen_only | shape_recognize (6) | Rust `shape_recognize.rs` (2283 lines), 10 `ShapeKind` variants `:31-41`. Frozen `jas/algorithms/shape_recognize.py:590`, wired at `algorithm_roundtrip.py:78,:267`, tag-pinned. Zero live hits (`loader.py:37,65` and `character_law.py:162,315` are unrelated word matches). Compare strategy "shape" at tol 0.5 (`cross_language_algorithms.py:122`). |
| `art_along_path` | frozen_only | art_along_path (9), art_flatten | Rust `art_along_path.rs` — warp plus the shared first-subpath `flatten` that `bristle_stroke.rs:13` imports. Frozen `jas/algorithms/art_along_path.py:29`, header line 1-4 "Port of jas_dioxus/…". **Not wired**: no verb, so `--lang python` exits 1 at `algorithm_roundtrip.py:86-88`. Zero hits in `workspace_interpreter/`. Checker PHASE 3 (`:920`). |
| `bristle_stroke` | frozen_only | bristle_stroke (6) | Rust `bristle_stroke.rs:27,:31,:37,:45`. Frozen `jas/algorithms/bristle_stroke.py:17-32,:35`, "Port of …" at `:1-8`, not wired. Latent divergence measured: frozen Python `round()` (banker's) at `:24` vs Rust `.round()` (half away from zero) at `:28`. Checker PHASE 3 (`:928`). |
| `pattern_along_path` | frozen_only | pattern_along_path (7) | Rust `pattern_along_path.rs:35`, delegates flattening to `art_along_path::{flatten, point_at_arclength}` (`:17`). Frozen `jas/algorithms/pattern_along_path.py:26`, no verb (`algorithm_roundtrip.py:505-518`). The interpreter carries brush **identity** only (`effects.py:673-715`, `expr_eval.py:678-703`, `loader.py:140-158`), never brush geometry. |
| `text_layout_paragraph` | frozen_only | paragraph_markers (22) | Rust `text_layout_paragraph.rs:20,:27,:46,:61,:90,:126`. Frozen impl folded into `jas/algorithms/text_layout.py:845-909,:708`. Zero live hits (`state_store.py:1072,1109` are `__path__` markers). **Name trap**: the `text_layout_paragraph` verb drives `text_layout::layout_with_paragraphs`, not this module (`jas_dioxus/src/bin/algorithm_roundtrip.rs:1603-1611`). `build_segments_from_text` (`:126`, called from `app_state.rs:4732,4813`) is in **no** family. |
| `text_layout` | frozen_only | text_layout (5) + text_layout_paragraph (24) | Rust `text_layout.rs` (2502 lines), pure over a `Measurer`. Frozen `jas/algorithms/text_layout.py:156,:482`, **wired** at `algorithm_roundtrip.py:80,:81` — stranded only by the tag pin. The interpreter's `CHAR_WIDTH` measures widget labels, not document text. No analytic law possible without a font oracle (`cross_language_algorithms.py:949-951`). |
| `path_text_layout` | frozen_only | path_text_layout (5) | Rust `path_text_layout.rs:40`. Frozen `jas/algorithms/path_text_layout.py:70,:94`, and it **does** carry the verb (`algorithm_roundtrip.py:82`) — the only one of the brush/text group that a tag checkout can run. Default lane is `rust,swift` (`cross_language_algorithms.py:2378-2382`). |
| `hyphenator` | frozen_only | hyphenator (19) | Rust `hyphenator.rs:31,:95`. Frozen `jas/algorithms/hyphenator.py:41,:22`. Exhaustive grep of `workspace_interpreter/` for hyphen/liang/break_at/min_before: zero. The frozen driver exposes 14 verbs and `hyphenator` is not among them (`algorithm_roundtrip.py:505-518`), so even a tag checkout cannot run this family without writing code in a frozen tree. |
| `simplify` | frozen_only | simplify (11) | Rust `simplify.rs:40,:50`. Frozen `jas/algorithms/simplify.py:34,:54,:99,:131`, whose own docstring `:19-20` says it exists "for cross-language behavioral equivalence" — and it has **no runner key**, so no harness has ever called it. Zero hits in `workspace_interpreter/` for simplify/fit_curve/schneider/corner_angle. Checker PHASE 3 (`:907-911`). |
| `fit_curve` | frozen_only | fit_curve (14) | Rust `fit_curve.rs:13` (Schneider). Frozen `jas/algorithms/fit_curve.py:13`, **wired** at `algorithm_roundtrip.py:30,:77,:248` — runnable at the tag, which makes this the least-bad frozen row. No curve fitting in `workspace_interpreter/` (only `dash_renderer.py:10-11`'s deferral note and `expr_eval.py:594` atan2). Checker PHASE 2 (`:875`). |
| `arrow_trim` | absent | arrow_trim (16) | Rust `arrow_trim.rs` (added 2026-07-24, two days post-tag). `grep -rn -E "arrow_trim|trim_path" jas --include=*.py` returns **zero**; what exists there is the legacy `jas/canvas/arrowheads.py:118,:177`, which is the bug this algorithm fixes. Interpreter hits are stroke attribute plumbing only (`effects.py:1110-1114,1491-1510`). Checker PHASE 2, arc-length law available (`:867-869`). |
| `align` | frozen_only | align (16) | Rust `align.rs` — 14 ops over rect bounds. `workspace/actions.yaml:2119-2122` states the design: each op fires a platform effect and each native app wires its own handler; `workspace_interpreter/effects.py:1079-1087` silently returns when no handler is registered, and no interpreter test registers one. Frozen handlers at `jas/panels/align_apply.py:89-100` and `jas/algorithms/align.py:154-179,:237-262` — complete, wired, and self-declared at `:1-2` as a transcription of the Rust. Checker PHASE 2 (`:872-874`). |
| `layers_filter` | **split** — live for the checked-set half, frozen_only for `type_value`/`keep`/`menu_rows` | none in the algorithms corpus; `test_fixtures/view_state/layers_type_filter.json` (14), read by Rust and Swift only | Live half: `StateStore.list_toggle` (`state_store.py:507`) plus `effects.py:930-950,825-833` execute `workspace/actions.yaml:1907,1929,1944` straight off the YAML — that is Rust's `checked_after_action` (`layers_filter.rs:227`) and `action_is_in_force` (`:245`). Frozen half: `jas/panels/yaml_renderer.py:2820,:2823`, which computes the token as a raw Python class name where Rust **derives** it (`layers_filter.rs:50-63`) — a superseded law. Swift twin is inline at `YamlPanelBodyView.swift:3850`. |
| `boolean` | live **adjudicator** (checker tier); producer frozen_only | boolean (19) | Producer: frozen `jas/algorithms/boolean.py:71-86`, whose header declares the **pre-ruling** model and which greps zero for `fill_rule` — while 4 of the 19 vectors now carry `a_fill_rule` and frozen `run_boolean` (`algorithm_roundtrip.py:197-220`) reads only `a`/`b`/`function`. Adjudicator: `GEOMETRY_CHECKERS["boolean"] = boolean_result_is_the_sampled_combination` (`cross_language_algorithms.py:814`, defined `:1548`), ruling per-port through `spec/geometry/region.py` (438 lines, verified, imports nothing from the repo). Blocking in CI (`.github/workflows/test.yml:528-530`, `:364-370`). |
| `boolean_normalize` | live **adjudicator** (checker tier); producer frozen_only | boolean_normalize (20) | Producer: frozen `jas/algorithms/boolean_normalize.py:23`, which disqualifies itself at `:1-14` ("Does not handle T-junctions, collinear self-retrace, or inter-ring cancellation"), takes one argument where Rust's takes rings **plus** the rule, and cites a Rust filename that no longer exists. Adjudicator: `normalize_preserves_the_declared_region` (`cross_language_algorithms.py:816`, defined `:1619`), same `_rule_region` body (`:1283`), mutant `:1658`. |
| `gradient_remap` | absent (producer) — **live analytic law** | gradient_remap (13) | Rust `gradient_remap.rs:129`. No Python implementation anywhere: no `jas/algorithms/gradient_remap.py`, no gradient geometry in the interpreter, and the one `jas/` "remap" hit (`controller.py:208`) is dependency-graph remapping. `GEOMETRY_CHECKERS["gradient_remap"] = gradient_remap_repaints_the_fragment` (`:814`, impl `:1120`, mutant `:1166`) rules against `spec/geometry/linear_gradient.py`, which says of itself `:1-7` that it is the denotation and computes no remap. |
| `polygon_metrics` | **live** (membership and simplicity; `polygon_set_area` reference-less) | polygon_metrics (12) | Rust `polygon_metrics.rs:30,:47,:69,:176,:221,:245`. Live counterpart `spec/geometry/region.py` — `contains` `:171`, `contains_per_ring` `:186`, `crossings` `:140`, `ring_defect` `:346`, shoelace `:366-370` — imported as `rg` at `cross_language_algorithms.py:40` and already grading both boolean families (`:1325,1344,1381-1385,1519`). Not yet wired to grade this family (`docs/CHECKERS.md:899-902`). No live counterpart for `polygon_set_area` (`:176`). Frozen copies are hand-inlined in the harness (`algorithm_roundtrip.py:542-616`) with no runner key. |
| `transform_apply` | **live** (scale, rotate, horizontal shear; vertical/custom shear and `stroke_width_factor` reference-less) | transform_apply (22) | Rust `transform_apply.rs:22,:30,:45,:77`. Live: `workspace_interpreter/effects.py:1751,:1758,:1770` return the same 2×3 matrices, verified algebraically against `element.rs:600,608,646,661,679` and executable with `jas/` absent (only import is `math`). Live-wired at `effects.py:1873,1878,1884,1891`. Frozen twin `jas/algorithms/transform_apply.py:25-71`, no runner key. |
| `dash_renderer` | **live** (lines); curve arm reference-less | dash_renderer (12) | `workspace_interpreter/dash_renderer.py:35` is a full 530-line live implementation with its own tests, and Rust names it as the reference (`dash_renderer.rs:4-5,:29-30`). Lines-only by declaration (`dash_renderer.py:8-13`); Rust does curves (`:7-14,:23`) and the corpus has `a_cubic_dash_is_emitted_as_a_cubic`. The reference fails **silently** on curves: `_has_segments` counts only L/Z (`:108-111`), `_anchor_points` collects only M/L (`:118-127`). No runner key. |
| `corpus_text_measure` | **live** (under-exercised) | none — the helper that defines `char_width` for text_layout, text_layout_paragraph, path_text_layout | Rust `corpus_text_measure.rs:33`; its header `:14-17` points at frozen `jas/tools/algorithm_roundtrip.py:357,420,465`. But the live interpreter implements the same law: `panel_layout.py:39` `CHAR_WIDTH = 10`, `:164-173` `_text_w` returns `len(resolved) * CHAR_WIDTH`, and Python `len` counts Unicode scalars — the exact ruling at issue. It generates a golden (`scripts/gen_panel_layout_fixture.py:35,:373-380` → `panel_layout.json`, 16 vectors) that both ports assert against. That fixture is pure ASCII, so the drift it could rule is not currently being asked. |

---

## Risk ranking of the reference-less rows

Risk = (geometrically subtle enough that both ports can be identically wrong) × (thin corpus). Named concretely, worst first.

### Tier 1 — nothing watches them at all, not even mutual agreement

**1. `knuth_plass`.** No reference, no fixture, no ALGORITHMS row, no roundtrip verb in either port. Rust's `compose` is a dynamic program over badness and demerits with penalty items and glue stretch; Swift's `KnuthPlass.swift` is a hand mirror. Nothing compares them, so the two ports are not even known to *agree*. A defect is visible only when it perturbs one of the 24 `text_layout_paragraph` vectors, all of which run on an injected fixed-width measurer. The blocker is encoding a tagged union on the wire; the manifest prices the unblock at ~30 lines per port (`corpus_manifest.json:779-781`). This is the only row in the census with zero instruments of any kind.

**2. `eyedropper`.** No fixture, no runner, no checker. The five `test_fixtures` matches pin that the tool exists in the toolbar and has a shortcut; what `extract_appearance` and `apply_appearance` actually copy is pinned by nothing. `apply_appearance` rebuilds elements field by field — the documented habitat of the Swift copy-site omission class, where every newly added element field is silently dropped on the Swift side and no compiler complains. Rust's header asserts "Cross-language parity is mechanical" (`eyedropper.rs:16-17`); no gate tests that claim.

**3. `magic_wand`.** No fixture, no runner, no reference. Five tolerance defaults (fill 32.0, stroke 32.0, weight 5.0, opacity 5.0, blend off — `magic_wand.rs:49-59`) are duplicated as literals in each port with nothing pinning them, so a one-character drift in any one silently changes which elements a click selects. Lower geometric subtlety than tier 2, but the coverage is nil and the surface is user-facing.

**4. `build_segments_from_text`** (`text_layout_paragraph.rs:126`). Called from `app_state.rs:4732,4813`, reached by no family. Its sibling functions got `paragraph_markers` on 2026-08-01; this one did not.

### Tier 2 — subtle, thin, and this is the shape the precedent had

**5. `hit_test`.** 123 of the 157 vectors are element-level (81 rect, 42 polygon) and those are precisely the ones the frozen Python **refuses** — `run_hit_test` hard-exits on unrecognised names (`algorithm_roundtrip.py:183-185`). So the arm where the stroked-and-transformed-ellipse marquee bug lived for three and a half months has never had a Python lane, at the tag or at HEAD; only the 34 primitive vectors were ever three-way. The interpreter's `hit_test` is a false friend under audit: same name, no stroke, no transform, no marquee rect, no lasso polygon, and its bounds come from the frozen package. Subtlety is high because the answer depends on stroke widening, transform composition, and the flattening tolerance for curved outlines interacting at once. The checker is blocked not on the instrument but on the wire shape: `hit_test` carries path commands plus a tolerance rather than rings, so `flatten`'s deviation law is a prerequisite (`cross_language_algorithms.py:877`).

**6. `arrangement`.** The high-risk half has no Python anywhere and the frozen code that looks like it **would answer differently by design**: `planar.py:162 _intersect_proper` rejects the endpoint band at `:180-181` and declares no collinear epsilon at all (`_VERT_EPS :138`, `_PARAM_EPS :141`, `_DENOM_EPS :144`), which is exactly the T-junction and collinear-overlap class `split_points` was written to accept (`arrangement.rs:47-51`). So consulting it produces disagreement carrying no information. The family is one day old (created 2026-08-01), 24 vectors, expectations hand-derived from the epsilon policy with no expectation produced by running either port. Its own `_doc` calls this "the most production-reachable geometry in the tree" whose prior assurance was 11 Rust and 11 Swift tests **mirrored by hand**. Checker PHASE 3.

**7. `planar`.** Face extraction over a half-edge structure, 12 hand-derived goldens. The frozen Python is not merely pinned, it is *stale against the spec*: `planar.py:18-20` lists T-junctions and collinear overlap as deferred, while `planar.rs:44-53` handles both and four HEAD vectors pin them (`t_junction_chord_splits_square`, `t_junction_corner_chord_splits_25_75`, `collinear_overlap_shared_bottom_edge`, `collinear_partial_overlap_two_squares`). Unfreezing would not adjudicate. The checker roster is explicit that the instrument is no longer the blocker — the adapter is (`:883-888`).

**8. `calligraphic_outline`.** 9 vectors, no live reference, frozen Python present but never wired to the harness, and the Rust module's stated provenance is JavaScript in `jas_flask`, which is non-gating by charter. The ribbon law (both rails exactly half the declared width from the spine along the spine's own normal) is closed-form and needs no new instrument, and it is unwritten (`:843`). Rust-vs-Swift agreement is the entire assurance.

**9. `offset_path`.** Same ribbon law plus a cap law; 8 vectors; checker gap PHASE 4 (`:846-856`). The frozen Python cannot help by construction — it never turns the outline into a value. **This family has already produced the failure mode, measured:** on the first run all eight port-vs-port comparisons passed while three round-cap vectors failed the hand-derived oracle. Both ports had written `atan2(n_y, -n_x)` where the tangent read off the normal has angle `atan2(-n_x, n_y)` — a reflection about the 45-degree line, so both round caps were welded on at the wrong angle for every stroke direction except 135 and 315 degrees, where the two errors cancel. On a 10pt eastward stroke the cap arc began 7.07pt from the rail it was joined to. What caught it was expectations derived by hand from SVG 1.1 §11.4, not a port and not a checker.

### Tier 3 — subtle, but with a spec-derived golden or a runnable tag lane

**10. `shape_recognize`** — 6 vectors against 10 `ShapeKind` variants. RoundRect, Square, Arrow, Lemniscate and Scribble are recognised by both ports and watched by nothing; the compare is "shape" at tolerance 0.5, a loose geometric match rather than an exactness gate.

**11. The brush trio — `art_along_path` (9), `pattern_along_path` (7), `bristle_stroke` (6).** All vectors run on a straight horizontal path, where the warp collapses to a closed-form scale-and-translate and the unit normal is `(0,1)` everywhere. That is what makes the goldens hand-derivable; it also means the curvature arm — the part where identical-wrong is plausible — is untested. The one protection is inherited: all three delegate to `art_along_path::flatten`, which the `art_flatten` family watches, and that family exists because both ports shipped an identical leading-`ClosePath` bail-out that dropped the whole path and no port-vs-port comparison could see it (S-4). A second confirmed instance of this census's failure mode, in this code path.

**12. `hyphenator` (19), `simplify` (11), `align` (16).** All three have a frozen Python file and none of the three can be run: `hyphenator` and `simplify` have no runner key at all; `align`'s frozen implementation is complete and wired but is a self-declared transcription of the Rust (`jas/algorithms/align.py:1-2`), so even unfrozen it is a third voice repeating the first. `align` ranks lowest of the reference-less rows on subtlety — rectangle arithmetic, and the coincidence law would be cheap to write.

**13. `fit_curve` (14), `text_layout` (5+24), `path_text_layout` (5), `arrow_trim` (16).** The runnable-at-the-tag group plus the post-tag newcomer. `path_text_layout` is worth singling out: its frozen lane **already earned its keep**, breaking a real Rust/Swift tie on `"aéb"` (reference and Rust say 4 scalars, Swift said 3, root-caused to `Array(content)`), and the cost of the freeze is that the family is now ASCII-only because a non-ASCII vector would simply red the blocking lane (`corpus_manifest.json:508-509`). `arrow_trim`'s arc-length law is exact, needs no new instrument, and is the cheapest checker in the census to write.

### Reference-less tails inside rows marked "live"

Four rows are live in name and reference-less where it counts:

- `dash_renderer` — the curve arm. Worse than absent, because the live reference **fails silently**: a cubic subpath is skipped and a mixed path is dashed along its chords, so `a_cubic_dash_is_emitted_as_a_cubic` is outside what Python can rule while looking like it is inside.
- `polygon_metrics` — `polygon_set_area` (`:176`, the y-band scanline with quarter/three-quarter sampling) has no live counterpart. This matters more than its size suggests: `polygon_metrics.rs:1-14` says every `boolean` and `boolean_normalize` golden is expressed through these functions, so a drift here rewrites what two large families appear to prove.
- `transform_apply` — shear `axis="vertical"` and `axis="custom"` (`:52-65`) and `stroke_width_factor` (`:77`). Zero hits for `stroke_width_factor` across `workspace_interpreter/`, `spec/` and `jas_flask/`.
- `corpus_text_measure` — live and runnable on any string, but the golden it generates is pure ASCII, so a scalars-versus-graphemes drift would not be caught today. Under-exercised, not reference-less.

---

## Where the skeptic overturned the first reading — 6 of 28

Every absence claim was put to a refutation pass. **Six fell (21%), and all six moved in the same direction**: from `frozen_only` toward live. The first pass systematically over-reported reference-lessness. Three distinct search failures, all the same shape — the reference existed under a form the query did not describe.

**Wrong directory (3): `boolean`, `boolean_normalize`, `polygon_metrics`.** The search equated "live reference" with "inside `workspace_interpreter/`". The adjudicating Python is elsewhere: `spec/geometry/region.py` (438 lines, verified on disk, standard library only, added by REGIONTRUTH) and the checker bodies in `scripts/cross_language_algorithms.py`. `region.py` answers the membership and simplicity half of `polygon_metrics` function for function and already grades both boolean families. `docs/CHECKERS.md:170-175` records it catching a shared-wrong-answer mutant that ring equality passed green — the exact failure class this census maps.

**Wrong name (2): `transform_apply`, `corpus_text_measure`.** The search grepped the Rust identifier (`scale_matrix`, a "measure"-shaped module). The live Python spells the same arithmetic as `_scale_about_pivot` / `_rotate_about_pivot` / `_shear_about_pivot` (`effects.py:1751-1777`) and as `_text_w` over `CHAR_WIDTH` (`panel_layout.py:39,164-173`). The refuter found them by expanding the algebra and by following the call site, not by name.

**Read live logic as prose (1): `layers_filter`.** `state_store.py:516` was dismissed as "a PROSE comment, not logic". It is the docstring of `StateStore.list_toggle` (`:507`), the live set primitive added 2026-07-30 by commit `04782d6d` for exactly this action.

Two of the six were settled by **running** the live Python rather than reading it: the toggle/solo/clear sequence executed against `workspace/actions.yaml` plus the interpreter, and the three pivot builders executed standalone to prove they carry no `jas/` import. For the remaining rows, execution is the check that grep structurally cannot perform.

The finding about the search: a name-scoped grep in the directory whose name says "reference" answers the wrong question 21% of the time on this codebase, because the live adjudicating tier is deliberately *not* in that directory — `region.py` imports nothing from the repo precisely so it is not a fourth implementation (`cross_language_algorithms.py:34-37`, enforced by `scripts/check_geometry_checkers.py`).

---

## What this census cannot tell you

1. **It classifies per algorithm, not per arm.** Four rows marked live have reference-less tails (listed above). "Live" is not a statement that every vector in the family is adjudicable, and for `dash_renderer` the reference's silence on curves is indistinguishable from a pass.

2. **It says nothing about whether the goldens are right.** For the reference-less rows the expectations are hand-derived from spec prose (`arrangement` from the epsilon policy, `arrow_trim` and `art_along_path` and `bristle_stroke` from BRUSHES.md and the module contracts, `offset_path` from SVG 1.1 §11.4). If a derivation misread the spec, both ports get conformed to that error and this census still counts the family as covered. The one empirical datum in the other direction is `offset_path`, where hand-derived expectations did catch a real shared bug.

3. **It does not report whether the ports agree or whether they are correct today.** It maps what would happen if they disagreed. Every reference-less row can be green right now and identically wrong; that is the definition of the condition, not an exception to it.

4. **The enumeration unit is `jas_dioxus/src/algorithms/*.rs`.** Geometry living outside that module is out of frame — `canvas/render.rs`, `painter/`, `workspace/app_state.rs` on the Rust side, and everything inline in the Swift views. `layers_filter` is in this census only because the Rust side happens to be a module; its Swift twin is inline at `YamlPanelBodyView.swift:3850`, and there is no way to know from this census how much geometry exists in that shape on the Swift side alone. Conversely, `test_fixtures/algorithms/` holds 47 families against 28 modules; the families with no module row (`flatten`, `element_bounds`, `element_evaluated_bounds`, `path_project`, `pane_geometry`, `color_convert`, the seven `tspan_*`, and others) were not audited here and their reference status is unknown.

5. **Absence is proved by search, and search demonstrably fails.** The 22 surviving claims carry a second-pass warrant rather than a first-pass grep, which is materially stronger, but the residual risk has the same shape as the six that fell: a live implementation under a different name, in a directory whose name does not advertise it.

6. **It does not weigh production reachability.** `arrangement`'s own fixture claims it is the most production-reachable geometry in the tree; `knuth_plass` runs on every wrapped paragraph; `eyedropper` and `magic_wand` are single-click user-facing tools. Nothing in this ranking accounts for how often a wrong answer reaches an artist, only for how likely the wrong answer is to go unnoticed.

7. **It treats only Python as a candidate adjudicator.** OCaml is frozen at the same tag and was not examined; `jas_flask` is non-gating by charter and is not counted as evidence in either direction, even though its `geometry.mjs` is the named provenance of `calligraphic_outline` — which means that one algorithm's origin document is a file this repo has ruled cannot arbitrate.

8. **It is a snapshot at HEAD on 2026-08-02.** Four families (`arrangement`, `art_along_path`, `bristle_stroke`, `paragraph_markers`) were created 2026-08-01. Their vectors have one day of history and have never survived a refactor.

---

## Cheapest closures, from the gap notes themselves

- `arrow_trim` — PHASE 2, the arc-length law (`:867-869`). Exact, closed-form, no new instrument.
- `align` — PHASE 2, the coincidence law (`:872-874`). Rectangle arithmetic; the declared edge lands on the target edge and the perpendicular axis does not move.
- `polygon_metrics` — wire `spec/geometry/region.py` to grade its own family. `docs/CHECKERS.md:899-902` names this as the cheap first step, and it currently governs the goldens of two other families.
- `calligraphic_outline` and `offset_path` — one ribbon-law predicate serves both (`:846-856`); offset_path needs a profile where calligraphic needs a constant.
- `knuth_plass` and `magic_wand` — not laws, wire: ~30 lines per port for a tagged-union encoder, and driving magic_wand from the document corpus (`corpus_manifest.json:781`).
---

## RECONCILIATION: the other seat said ZERO, this census said four, and the other seat is right

`jas/windows` reported that **the live reference adjudicates ZERO families.** This
census's first cut says four algorithms have a `live` status
(`corpus_text_measure`, `dash_renderer`, `polygon_metrics`, `transform_apply`).
Both statements are true, and the difference is not arithmetic — it is the
question each one asks.

Measured, not reasoned:

```
$ grep -c -- "--lang.*python" .github/workflows/test.yml
0
$ grep -n "cross_language_algorithms.py" .github/workflows/test.yml
364:  ... --lang rust --checker-report checker-report.json
528:  ... --lang rust,swift --require-comparisons --checker-report checker-report.json
```

The default lane is `rust,swift` (`scripts/cross_language_algorithms.py:2384`) and
**CI never runs a Python lane at all.** So for those four algorithms a live Python
implementation EXISTS and adjudicates NOTHING, because nothing runs it. The
operative count is the other seat's: zero families are adjudicated by a live
reference today.

**This census committed, in its own first cut, the exact class it was written to
map.** It asked "does an implementation exist?" when the question that matters is
"does anything rule?" — an instrument silently answering a narrower question than
the one asked. The row labels are kept as measured, because the code-level fact is
real and worth having; but the headline number is the operative one, and any
reader quoting "four" without this section is quoting the narrower question.

## What the adversarial pass changed, which is a finding about SEARCHING

Every claim of absence went to a skeptic whose only job was to find the
implementation the first pass missed. **Six of twenty-four were overturned** — a
quarter of the absence claims were wrong:

| Algorithm | first cut | corrected |
|---|---|---|
| `boolean` | frozen_only | live ADJUDICATOR (checker tier) |
| `boolean_normalize` | frozen_only | live ADJUDICATOR (checker tier) |
| `corpus_text_measure` | frozen_only | live |
| `layers_filter` | frozen_only | split (live action half, frozen producing half) |
| `polygon_metrics` | frozen_only | live |
| `transform_apply` | frozen_only | live |

The `boolean` pair is the instructive one. The first pass grepped
`workspace_interpreter/` and concluded there was nothing. There is nothing THERE —
but `scripts/cross_language_algorithms.py:813-817` registers a live, CI-blocking
analytic checker that rules via `spec/geometry/region.py`, a module that imports
nothing from this repository. **It cannot PRODUCE a union; it can rule one
illegal.** That is a different and in one respect stronger instrument, because it
survives both ports being identically wrong — the precise failure mode
`hit_test` demonstrated for three and a half months.

A census that had not been adversarially checked would have reported the single
best mitigation in the codebase as absent.

**A quarter of absence claims being wrong is the reusable lesson.** Absence is the
hardest thing to establish and the easiest to assert: the implementation may be
under another name, inlined into a caller, expressed in the YAML layer, or — as
here — in a different TIER entirely. No future census in this repository should
report an absence that has not been attacked.
