# PH1 de-risking spike — findings for the council (Mon 7/27)

Evidence packet for ratifying (or amending) the Painter contract v2
(`project_painter_contract_draft.md`). This is a working prototype, NOT the PH1
production conversion. `canvas/render.rs`, `app_state.rs`, and all existing draw
code are UNTOUCHED — the FLIP is unratified, so production conversion is
forbidden until the council word. Everything here is reworkable if the fork
changes.

Artifacts (all under `jas_dioxus/src/painter/`, plus one bench):
- `mod.rs` — the immediate `Painter` trait (14 methods, D5 v2 vocabulary) + typed styles.
- `recording.rs` — `RecordingPainter` + canonical-JSON emitter + the R7 float-law experiments.
- `sink.rs` — `NoOpPainter` (R10 bench sink).
- `canvas2d.rs` — `Canvas2dPainter` STUB (compile-checked 1:1 web_sys mapping; never run).
- `scene.rs` — the proof scene + the synthetic bench scene, driven through the trait.
- `tests.rs` + `testdata/scene_golden.json` — the proof test (deliverable #5).
- `../../benches/painter_build.rs` — the R10 native scene-build bench (deliverable #6).

Gate status: `cargo test` green (2344+ pass, 0 fail; 10 painter tests + float-law
proofs); `cargo build --lib` clean; `cargo bench --bench painter_build` runs.

---

## 1. Trait ergonomics verdict: the immediate trait is CLEAN

The immediate-mode trait did NOT fight the design. Concretely:

- **1:1 onto today's call sites.** `Canvas2dPainter` is a thin passthrough:
  `fill_path` → build subpath + `ctx.fill_with_canvas_winding_rule`,
  `ellipse_arc` → `ctx.ellipse_with_anticlockwise`, `push_state` → `save()` +
  `transform()`, etc. It compiles (native, web-sys bindings) with no contortion.
  This is direct evidence that the v1 "replay fidelity" problem dissolves — the
  production backend keeps today's exact call sequence.

- **Non-isolated group alpha as an owned multiply stack works and confirms D3.**
  `push_group(alpha)` pushes onto a `Vec<f64>`; the effective paint alpha is
  `product(open group alphas) * paint_alpha`. NOTHING reads `ctx.global_alpha()`
  back — the getter dies exactly as D3 claims. Overlaps compound because it is
  one flat multiply, no offscreen. This was the cleanest part of the spike.

- **Typed styles across the seam (R3) forced a good build-time split.** `Brush`
  carries RESOLVED gradient endpoints + stops (opacity pre-baked into stop
  alpha). The doc-model `Gradient` semantics — `angle`, `aspect_ratio`,
  freeform, dither, stroke sub-mode — never cross the seam; today's
  `make_canvas_gradient` bbox/angle math becomes a build-time lowering at the
  call site. The Painter stays free of jas gradient policy. Clean.

Two places the design pushed back; both resolved into amendments below (A1, A2)
rather than into trait ugliness.

---

## 2. R7 — the FLOAT LAW: DECIDED (with a coupling insight for the council)

**Decision: serialize coordinates as a fixed 4-decimal decimal string,
round-half-to-even (Rust `{:.4}`), in DOCUMENT space. The view transform
(zoom/pan) rides ONE matrix per `push_state` and is never multiplied into
coordinates.** (`recording.rs::canonical_f64`, proven by the `float_law` tests.)

Reasoning, each point backed by a passing test:

- **Not bit-exact** (`bit_exact_is_unstable`): `0.1 + 0.2` and `0.3` differ in
  the last ULP, so bit patterns and shortest-round-trip strings diverge —
  brittle goldens, the refuter's trap.
- **Not screen-space rounding** (`screen_space_rounding_can_straddle`):
  distributivity fails in f64, so `(a+b)*z` and `a*z + b*z` differ by ULPs; when
  the product lands near an `x.xxxx5` boundary the two equivalent build paths
  round to DIFFERENT 4-decimal strings (the test SEARCHES for and finds such a
  triple — a self-verifying existence proof). Multiplying by zoom manufactures
  these near-boundary values.
- **Doc-space 4dp is stable** (`doc_space_4dp_is_stable`,
  `doc_space_avoids_the_boundary`): equivalent doc coords collapse to the same
  4-decimal string, and authored coords aren't sitting on `x.xxxx5` boundaries.

**Coupling insight (new, for the council): R7 depends on D2.** The float law is
stable *because* D2 puts the view transform in a matrix rather than baking zoom
into every coordinate. That keeps the golden coordinate stream equal to the
authored/computed DOCUMENT geometry, which is what makes it stable across
equivalent builds. **Recommend ratifying R7 and D2 as a pair** — R7 without D2's
transform-as-matrix would re-open the screen-space straddle.

**Named residual (not hidden):** a doc coordinate landing EXACTLY on an
`x.xxxx5` boundary and computed two different ways could still straddle.
Doc-space keeps this rare and D2 removes the dominant source; if ever bitten,
raise precision or snap authored coords. Signed zero is normalized so
`-0.0`/`0.0` cannot split a golden.

This proves R4's display-list-equivalence golden mechanism WORKS: the proof
scene serializes byte-identically every run (`golden_is_deterministic`) and
matches a committed golden (`proof_scene_matches_golden`).

---

## 3. R10 — first number (native, CI-reproducible)

`cargo bench --bench painter_build` — scene-BUILD cost through `NoOpPainter`
(rendering subtracted out). Representative run (optimized, Apple-silicon native):

| N (per kind) | Painter calls | build time | ns/call (NoOp) | ns/call (Recording) |
|-------------:|--------------:|-----------:|---------------:|--------------------:|
| 1 000        | 6 004         | ~4.1 us    | ~0.69          | ~28.5               |
| 10 000       | 60 004        | ~17.6 us   | ~0.29          | ~44.7               |
| 50 000       | 300 004       | ~87.7 us   | ~0.29          | ~47.6               |

**First number: ~0.29 ns per Painter call to BUILD a scene; a 60k-call scene
builds in ~18 us.** RecordingPainter adds ~44 ns/call (Command alloc + clones) —
test-only, never in production.

Interpretation: scene-build is nanoseconds/op; the ≤10% budget on this number is
comfortably instrumentable, and the number confirms the seam itself is not a
per-frame cost concern. The real frame cost is browser rasterization (a
manual browser-side spot-measure per R10, explicitly out of scope here). This
makes R10 concrete — the refuter's "theater" critique is answered by a
reproducible native number, though see the residual: this uses a SYNTHETIC
uniform mix, not the jas-shaped reference-document fixture R10 ultimately wants.

---

## 4. CONTRACT AMENDMENTS the spike surfaced (highest-value output)

The last cheap chance to fix the contract before it freezes.

- **A1 — `FastRun` needs a baseline anchor `(x, y)`.** The D5 sketch
  `FastRun{font,size,text,letter_spacing}` omits POSITION, but a text element
  lowers to N FastRuns (one per wrapped line), each drawn at its own
  `(line_x, baseline)` via `ctx.fill_text(s, x, y)`. Without an anchor the op
  cannot place text. Added `x, y` to the FastRun variant. **Fix the D5 text
  entry.**

- **A2 — `ellipse_arc` must SPLIT into `fill_ellipse_arc` + `stroke_ellipse_arc`.**
  Today's Circle/Ellipse elements build the arc once, then FILL and STROKE it
  (two paints on one geometry). A single `ellipse_arc` op with no paint, or one
  that only fills-or-strokes, cannot express fill-then-stroke across an immediate
  seam without re-introducing a stateful path builder — the thing the immediate
  trait is trying to avoid. Split to mirror `fill_path`/`stroke_path`.
  (Alternative for the council: a unified `Geometry { Path | EllipseArc | Rect }`
  input to `fill_*`/`stroke_*`. I recommend the explicit split — simpler
  signatures, and it keeps the ~16-method count.)

- **A3 — fills need a `winding`, not just clip.** D5 lists winding (incl.
  EvenOdd) only on `clip`. But boolean-op output carries `FillRule::EvenOdd`
  today (holes), so `fill_path` and `fill_ellipse_arc` also need a `winding`
  param. Added. **Extend the D5 fill entry to carry winding.**

- **A4 — paint-time alpha (`fill_op`/`stroke_op`) is cleaner as an EXPLICIT
  per-paint PARAMETER than as trait state.** D5 says "set-style ops as trait
  state where today's code sets them." Modeling `paint_alpha` as an explicit arg
  to every paint method made the pin visible and testable and avoided hidden
  mutable state that a recorder would have to snapshot. **Council decision:
  state vs parameter.** I recommend parameter for the alpha specifically; the
  brush/stroke style can stay per-call too (they already are here).

- **A5 (minor) — `clip` is path-only in the spike.** An ellipse-shaped clip
  region would need either an ellipse-clip entry or path-flattening / a
  compound-path clip. Not hit by the proof slice; likely fine via a
  caller-built compound path (same as the outside-stroke trick). Named so the
  council can confirm clip stays path-only.

Not an amendment but worth minuting: **freeform gradients** have no Painter
representation (today they render as None / unpainted). That is correct — the
seam should not carry freeform gradient policy; it is a build-time lowering
concern. Named as a residual, not a gap.

---

## 5. What this spike did NOT prove (honest deferrals)

- **Masks.** The `Mask` enum and `push/pop_mask_layer` are defined and RECORDED,
  but no impl RENDERS a mask; `Canvas2dPainter`'s mask methods are
  `unimplemented!()`. The offscreen/luminance pipeline and the R8 BT.601-vs-
  BT.709 choice are PH4. The proof scene does not exercise masks.
- **Text shaping / PlacedGlyphs.** `glyph_id` resolution (skrifa cmap — PH3
  net-new) is not built; PlacedGlyphs is recorded structurally only and
  `Canvas2dPainter`'s PlacedGlyphs body is a stub. Only the FastRun path is
  demonstrated end-to-end.
- **The vello side.** No `VelloPainter`. Non-isolated per-primitive emulation,
  R1 chunking, and `render_to_texture` accumulation are all unproven (PH5).
- **Production conversion.** `render.rs` is untouched; NO call site was
  rewritten. The 1:1 mapping is proven by `Canvas2dPainter` COMPILING against
  web_sys, not by running in the app. GUI parity is unverified.
- **Canvas2dPainter at runtime.** Compile-checked only; never executed (no
  browser in this harness).
- **The R10 reference-document fixture.** The bench uses a synthetic uniform
  mix (N of each of 6 kinds), not the named jas-shaped fixture (masks/text/
  gradients) R10 ultimately requires. That fixture is PH1-proper work.
- **The double-save cost.** `push_state` and `push_group` each call `save()`, so
  an element that needs both does two saves vs today's one. Semantically
  correct; perf impact unmeasured (expected negligible).

---

## 6. Council asks this spike informs

1. **Ratify the FLIP** — the immediate trait is clean and the recording golden
   mechanism is proven stable (§1, §2). Recommend YES.
2. **Ratify R7's float law** — doc-space 4dp round-half-even, AND note it is
   coupled to D2 (§2). Recommend ratifying R7+D2 together.
3. **Absorb amendments A1–A3** into the D5 vocabulary before the freeze; decide
   A4 (state vs param) and confirm A5 (clip stays path-only).
4. R8 luma choice and R10's reference fixture are unaffected by this spike (both
   deferred); the R10 mechanism is proven, the fixture is not yet built.

---

## PH1 status (RATIFIED + FROZEN 2026-07-23; updated as PH1 lands)

The Monday-brief asks above were RATIFIED by the JYH council 2026-07-23: the
FLIP is ratified, R7's doc-space 4-decimal round-half-even float law is ratified
(coupled to D2), R8 accepts the documented BT.709/BT.601 luma difference under
the PH6 perceptual gate, and the v2 freeze is ratified **with amendments A1-A5
folded in**. The contract is now FROZEN: a discovered flaw goes back to a Fable
design block, not a mid-execution patch.

**A1-A5 are folded and consistent** across the trait (`mod.rs`), all three impls
(`recording.rs`, `canvas2d.rs`, `sink.rs`), the shared scene builders
(`scene.rs`), and the committed golden (`testdata/scene_golden.json`). The spike
had already shaped the trait to the amendments while surfacing them, so folding
them was a confirm-and-document pass: re-running the ignored regen tool
(`cargo test regenerate_proof_golden -- --ignored`) leaves the golden
BYTE-IDENTICAL — no A1-A5 golden churn. Per-method ratification is flagged
in the `mod.rs` doc comments (`RATIFIED 2026-07-23`), and the A5 invariant
(clip is path-only; the seam carries no freeform-gradient policy) is stated as a
code comment on `Painter::clip`.

**PH2 — the R4 gate.** A set of reference documents covering only the
PH1-expressible surface (filled/stroked rects, circles/ellipses fill-then-stroke,
lines, bezier/quad paths, polygons; solid + linear/radial gradient brushes;
dashed strokes; stroke alignment; nested groups with non-isolated alpha;
fast-path text) render through a `&mut dyn Painter` element renderer via
`RecordingPainter` and are locked against committed goldens under `testdata/`.
These goldens are the behavior-lock the production conversion lands behind.
Deliberately EXCLUDED (their phases own them): opacity masks (PH4),
type-on-path / placed-glyph text (PH3), freeform gradients (build-time lowering).

**PH3 — production conversion (capability-routed, Zeno-partial by design).**
`render.rs` grows a Painter-emitting path for the element renderer; an element
needing a PH3/PH4 feature (opacity mask, type-on-path/placed glyphs, freeform
gradient) stays on the legacy raw-ctx path unchanged. `Canvas2dPainter`'s
mask/PlacedGlyphs bodies stay `unimplemented!()` and are guarded so they can
never be reached in production. See the "notes for conductor" in the PH1 wave
report for exactly which element kinds converted vs stayed legacy.
