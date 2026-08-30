//! The `Painter` seam — the ratified Painter contract v2 foundation (PH1).
//!
//! The Painter contract v2 (`project_painter_contract_draft.md`) is RATIFIED +
//! FROZEN (JYH council 2026-07-23): the FLIP (D1 v2: an immediate-mode trait,
//! not a retained IR) is ratified, and amendments A1-A5 are folded into the
//! vocabulary below (see the per-method notes flagged `RATIFIED 2026-07-23`).
//! This module is the PH1 foundation the de-risking spike proved: the
//! immediate-mode trait, three impls, a proof test, and a scene-build bench.
//!
//! PH1 begins converting `canvas/render.rs` to emit through this seam. The
//! conversion is a mechanical 1:1 rewrite of today's `ctx.*` call sequences
//! (R4 display-list-equivalence discipline), routed BY CAPABILITY: an element
//! that needs a feature the route in front of it cannot deliver stays on the
//! legacy raw-ctx path.
//!
//! ⚖️ AND "THE ROUTE IN FRONT OF IT" MEANS A BACKEND, SINCE 08/29 (council row
//! (e) = option (b)). The router asks [`Painter::supports`], because the two
//! backends differ: `Canvas2dPainter` executes isolated layers (#47) and mask
//! layers (#55); `Direct2DPainter` executes neither and answers NO, so masked
//! elements stay legacy-routed THERE while converting on Canvas2D. The
//! vocabulary it asks in is derived from the conformance corpus — see
//! [`capability`].
//!
//! ⛔ THE SENTENCE THIS REPLACES SAID "`Canvas2dPainter`'s mask/PlacedGlyphs
//! bodies remain `unimplemented!()` and must never be reached in production".
//! Half of it went false when #55 landed the mask bodies and nobody struck it —
//! a stale claim in the most-read header of this module, in the exact clause a
//! reader takes on trust. PlacedGlyphs IS still `unimplemented!()` and is still
//! kept off the seam by the router (text is PH3, and there is deliberately no
//! capability for it: no backend answer unlocks shaping work that does not
//! exist).
//!
//! # What the trait is
//!
//! `Painter` is an **immediate-mode** drawing seam: the caller issues a call
//! per drawing action and the impl acts on it right then. There is no retained
//! scene graph exposed across the seam. Three impls prove the shape:
//!
//! - [`Canvas2dPainter`](canvas2d::Canvas2dPainter) (feature = "web"): a thin
//!   1:1 mapping onto `web_sys::CanvasRenderingContext2d`. Compile-checked
//!   natively (web-sys bindings compile on any target); never RUN outside a
//!   browser and never wired into `render.rs` in this spike.
//! - [`RecordingPainter`](recording::RecordingPainter): materializes each call
//!   into a `Command` and serializes to canonical JSON — the
//!   display-list-equivalence goldens (R4) live where their only consumer lives
//!   (tests). No per-frame production tax.
//! - [`NoOpPainter`](sink::NoOpPainter): a do-nothing sink, for the R10 bench
//!   (measures scene-BUILD cost with rendering subtracted out).
//!
//! # Design decisions the council is ratifying (the signatures ARE the seam)
//!
//! - **Typed styles cross the seam (R3).** No CSS strings, no doc-model
//!   `Gradient`. [`Brush`] carries resolved gradient ENDPOINTS + stops; the
//!   `bbox`/`angle`/`aspect_ratio`/freeform math from today's
//!   `make_canvas_gradient` moves to BUILD time (the call site). The Painter
//!   never sees jas gradient semantics — only geometry + color. CSS strings
//!   exist only inside `Canvas2dPainter`.
//!
//! - **Paint-time alpha is a pinned, EXPLICIT parameter (`paint_alpha`).**
//!   Today's `fill_op`/`stroke_op` are a `globalAlpha` multiply applied right
//!   before each paint; the contract PINS this (never baked into brush color,
//!   to preserve the browser's exact compositing arithmetic). Making it an
//!   explicit arg to every paint method makes the pin visible and testable.
//!
//! - **Group alpha COMPOUNDS non-isolated ([`Painter::push_group`]).** Each
//!   element/group opacity multiplies into ALL descendants per-primitive, so
//!   overlaps within a group compound — exactly today's browser behavior (one
//!   flat `globalAlpha`, no offscreen isolation; incl. the 0.15 layers-dim
//!   pass). The effective paint alpha at any primitive is
//!   `(product of open group alphas) * paint_alpha`. The impl tracks the
//!   product internally; NOTHING reads it back off the context (D3: the
//!   group-alpha getter dies). `VelloPainter` (PH5) will EMULATE this
//!   per-primitive rather than use a `push_layer` (a push_layer would isolate
//!   and stop overlaps compounding — the wrong semantics).
//!
//! - **Group blend is inert by construction.** `push_group` carries a
//!   [`BlendMode`] so the mechanical rewrite of today's per-element
//!   `set_global_composite_operation` has somewhere to land, but a nested
//!   `push_group` resets it and leaf primitives inherit the innermost group's
//!   blend — matching today, where a Group's own mode is overridden by its
//!   children. We do NOT activate dead group-level blend behavior.
//!
//! ## AMENDMENT A6 — THE ELEMENT BRACKET (ratified 2026-08-27, Captain)
//!
//! Two ops added (14 → 16). `push_mask_layer` / `pop_mask_layer` keep their
//! FROZEN SIGNATURES and gain their missing meaning: legal only INSIDE an
//! isolated layer, bracketing the MASK ARTWORK.
//!
//! ```text
//! push_isolated_layer(alpha, blend)
//!     <body ops>                    — full vocabulary, arbitrary nesting
//!     [ push_mask_layer(mask)
//!         <mask artwork ops>        — full vocabulary, arbitrary nesting
//!       pop_mask_layer() ]
//! pop_isolated_layer()
//! ```
//!
//! - At most ONE mask bracket per isolated layer, at the layer's own nesting
//!   level, and NOTHING may be drawn between `pop_mask_layer` and
//!   `pop_isolated_layer` — the law stays a suffix operation. Relaxing this
//!   later is additive; tightening it later would not be.
//! - `push_mask_layer` OUTSIDE an isolated layer is a contract violation. It was
//!   semantically vacant before this amendment; now it is stated. Impls may
//!   panic; the recorder may still record it, for goldens OF the violation.
//! - All brackets strictly nest; each bracketed span is internally balanced.
//!
//! `pop_mask_layer` derives the mask map `M(x)` from the artwork rendered inside
//! the mask bracket (itself isolated: fresh transparent surface, alpha context
//! 1.0) and updates the layer surface `S` in place — `LuminanceClipIn`:
//! `α_S ← α_S · M` with `M = A·(0.299R+0.587G+0.114B)/255` (BT.601, normative);
//! `AlphaClipOut`: `α_S ← α_S · (1−M)` with raw `A`; `AlphaRevealOutsideBbox`:
//! `α_S ← α_S · M` inside `bbox`, unchanged outside, `bbox` arriving precomputed
//! (a backend never computes bounds).
//!
//! ⛔ THE MASK ENUM IS COMPLETE — no fourth variant. `(clip:false, invert:true)`
//! is pointwise equal to `(clip:true, invert:true)` by OPACITY.md's own table
//! and lowers at BUILD time to `Mask::AlphaClipOut`. A fourth law was transcript
//! overreach; ratified as such, zero further contract change.
//!
//! See `SPIKE_FINDINGS.md` in this directory for the ergonomics verdict, the
//! R7 float-law decision, the R10 first number, and the "PH1 status" note
//! recording the now-ratified amendments A1-A5 (A1: FastRun carries a baseline
//! anchor; A2: `ellipse_arc` splits into fill/stroke; A3: fills carry a
//! winding; A4: paint-time alpha is an explicit per-paint parameter; A5: clip
//! stays path-only and the seam carries no freeform-gradient policy).

pub mod capability;
pub mod corpus;
pub mod element_render;
// Test-gated with the driver it feeds. #56 landed it ungated and it has never
// had a non-test consumer, which cost 12 dead-code warnings on every build; now
// that `replay_drive` is its only caller, the gate follows the fact.
#[cfg(test)]
pub(crate) mod replay_decode;
// The shared corpus DISPATCH and the capability cross-check. Test-gated: it is
// an instrument, not a production path, and `capability_of` (which it consumes)
// is gated the same way for the same reason.
#[cfg(test)]
pub(crate) mod replay_drive;
pub mod recording;
pub mod scene;
pub mod sink;

#[cfg(feature = "web")]
pub mod canvas2d;

#[cfg(test)]
mod tests;

// The Path IR is REUSED, not reinvented (contract D5). Styles reuse the
// existing typed enums so the seam speaks the document's own vocabulary.
pub use crate::geometry::element::{
    BlendMode, Color, FillRule, LineCap, LineJoin, PathCommand, Transform,
};

// ---------------------------------------------------------------------------
// Typed geometry helpers
// ---------------------------------------------------------------------------

/// An axis-aligned rectangle, `(x, y)` top-left with size `w × h`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A (possibly partial) ellipse arc — the refuter's missing-circle fix.
///
/// Maps 1:1 onto `ctx.ellipse(cx, cy, rx, ry, rotation, start, end, ccw)`; a
/// circle is the `rx == ry, rotation == 0` case (today's `ctx.arc`). A FULL
/// ellipse uses `start = 0.0, end = TAU`. Partial arcs serve offset_path round
/// joins and overlay handles. Angles are in RADIANS.
///
/// Why this can't be a `PathCommand`: SVG's elliptical-arc command (`A`, our
/// [`PathCommand::ArcTo`]) degenerates when start == end, so it cannot draw a
/// full 360° circle in one command — the exact gap the v1 vocabulary hit.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EllipseArc {
    pub cx: f64,
    pub cy: f64,
    pub rx: f64,
    pub ry: f64,
    /// X-axis rotation, radians.
    pub rotation: f64,
    /// Start angle, radians.
    pub start: f64,
    /// End angle, radians.
    pub end: f64,
    /// Counter-clockwise sweep.
    pub ccw: bool,
}

impl EllipseArc {
    /// A full circle centered at `(cx, cy)` with radius `r` — today's
    /// `ctx.arc(cx, cy, r, 0, TAU)` for a `Circle` element.
    pub fn circle(cx: f64, cy: f64, r: f64) -> Self {
        Self { cx, cy, rx: r, ry: r, rotation: 0.0, start: 0.0, end: std::f64::consts::TAU, ccw: false }
    }

    /// A full (axis-aligned) ellipse — today's `ctx.ellipse(...0, 0, TAU)`.
    pub fn ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Self {
        Self { cx, cy, rx, ry, rotation: 0.0, start: 0.0, end: std::f64::consts::TAU, ccw: false }
    }
}

// ---------------------------------------------------------------------------
// Typed paint styles (R3 — typed across the seam, CSS lives only in Canvas2d)
// ---------------------------------------------------------------------------

/// A single gradient color stop. `offset` is 0..1 along the gradient; the
/// stop's opacity is BAKED into `color`'s alpha at build time (today's
/// `make_canvas_gradient` folds per-stop `opacity` into the stop color).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ColorStop {
    pub offset: f64,
    pub color: Color,
}

/// A linear gradient in the CURRENT coordinate space — endpoints already
/// resolved from the element bbox + angle at build time (the Painter never
/// sees `angle`/`aspect_ratio`).
#[derive(Debug, Clone, PartialEq)]
pub struct LinearGradient {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
    pub stops: Vec<ColorStop>,
}

/// A radial gradient as two circles (inner `r0` → outer `r1`) — the full
/// `ctx.create_radial_gradient(x0,y0,r0, x1,y1,r1)` form. Today's code uses the
/// concentric `r0 = 0` case; the general form is here so the seam never has to
/// widen later.
#[derive(Debug, Clone, PartialEq)]
pub struct RadialGradient {
    pub x0: f64,
    pub y0: f64,
    pub r0: f64,
    pub x1: f64,
    pub y1: f64,
    pub r1: f64,
    pub stops: Vec<ColorStop>,
}

/// The paint source for a fill or a stroke.
#[derive(Debug, Clone, PartialEq)]
pub enum Brush {
    Solid(Color),
    Linear(LinearGradient),
    Radial(RadialGradient),
}

/// Stroke geometry. `dash` is the pattern (empty = solid); there is NO dash
/// offset — the contract verified it is unused. Stroke ALIGN is intentionally
/// absent: inside/outside alignment lowers to a build-time clip at the call
/// site (as today), so it never crosses the seam.
#[derive(Debug, Clone, PartialEq)]
pub struct StrokeStyle {
    pub width: f64,
    pub cap: LineCap,
    pub join: LineJoin,
    pub miter: f64,
    pub dash: Vec<f64>,
}

// ---------------------------------------------------------------------------
// Mask + text
// ---------------------------------------------------------------------------

/// A mask layer's compositing law. The jas asymmetry is carried BY
/// CONSTRUCTION: `LuminanceClipIn` reads the mask's luminance; the other two
/// read raw alpha. (Masks are DEFERRED in this spike — the enum is defined and
/// recorded so the vocabulary is complete, but no impl renders one and the
/// proof test does not exercise it. PH4 owns the scratch pipeline.)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mask {
    /// Keep where the mask is bright (luminance mask). Browser uses BT.601;
    /// vello's native luminance is BT.709 — the R8 ratification point.
    LuminanceClipIn,
    /// Cut out where the mask is opaque (raw alpha).
    AlphaClipOut,
    /// Reveal outside the mask's bounding box (raw alpha), `bbox` given.
    AlphaRevealOutsideBbox { bbox: Rect },
}

/// THE (clip, invert) TRUTH TABLE — ONE COPY, and it lives here because it
/// produces a seam type. A6 §4 puts the lowering at BUILD time: the document's
/// two booleans become one of the three frozen laws before anything crosses the
/// seam, so a backend never sees `clip`/`invert` and the enum stays complete.
///
/// ⛔ `(clip:false, invert:true)` COLLAPSES ONTO `(true, true)` — both yield
/// `E · (1 − M)` once the mask's outside-region alpha is 0, so an alpha-based
/// mask cannot distinguish them. That collapse is exactly why the "fourth mask
/// law" was ruled transcript overreach: it is not a fourth behaviour, it is a
/// third spelling of the second one.
///
/// `bbox` is consumed only by the reveal law and arrives precomputed — a
/// backend never computes bounds (§3.3).
pub fn mask_from_flags(clip: bool, invert: bool, bbox: Rect) -> Mask {
    match (clip, invert) {
        (true, false) => Mask::LuminanceClipIn,
        (true, true) => Mask::AlphaClipOut,
        (false, true) => Mask::AlphaClipOut,
        (false, false) => Mask::AlphaRevealOutsideBbox { bbox },
    }
}

/// A single placed glyph (PlacedGlyphs mode). `glyph_id` is resolved at BUILD
/// time by a shaping stage (skrifa cmap — NET-NEW work named for PH3); vello
/// never receives raw text.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlacedGlyph {
    pub glyph_id: u32,
    pub x: f64,
    pub y: f64,
}

/// A text run, in one of two modes. Text rides PH1 because it interleaves in
/// z-order with other primitives (the v1 PH1/PH3 inversion is repaired).
#[derive(Debug, Clone, PartialEq)]
pub enum TextRun {
    /// The byte-preserving fast path: one `ctx.fill_text` with native
    /// `letterSpacing`. AMENDMENT A1 (RATIFIED 2026-07-23): the contract sketch
    /// `{font,size,text,letter_spacing}` omits a POSITION, but today a text
    /// element lowers to N FastRuns (one per wrapped line), each at its own
    /// `(x, baseline)`. A baseline anchor `(x, y)` is therefore mandatory —
    /// carried here.
    FastRun {
        font: String,
        size: f64,
        text: String,
        letter_spacing: f64,
        /// Baseline origin x.
        x: f64,
        /// Baseline origin y.
        y: f64,
    },
    /// Pre-shaped glyphs at explicit positions (per-glyph transform lowers to N
    /// single-glyph runs in vello).
    PlacedGlyphs {
        font: String,
        size: f64,
        glyphs: Vec<PlacedGlyph>,
    },
}

// ---------------------------------------------------------------------------
// The trait
// ---------------------------------------------------------------------------

/// The immediate-mode drawing seam. ~14 methods; the D5 v2 vocabulary with the
/// refuter repairs absorbed. See the module docs for the semantic pins.
///
/// Coordinate convention: every method takes coordinates in the CURRENT
/// coordinate space, i.e. after the transforms pushed via [`push_state`]. The
/// driver owns the view transform (D2) and pushes it as a matrix, so PAINT-op
/// coordinates stay in document space — the property that makes R7's float law
/// stable (see `SPIKE_FINDINGS.md`).
///
/// [`push_state`]: Painter::push_state
// B1 -- the Direct2D backend. Behind feature = "d2d" so the web build and the
// wasm target never see it.
#[cfg(all(feature = "d2d", windows))]
pub mod direct2d;

pub trait Painter {
    /// ⚖️ THE CAPABILITY QUERY (council 08/29, row (e) = option (b)). Can this
    /// backend EXECUTE `cap`, or must a caller needing it take another route?
    ///
    /// # Why the seam carries this at all
    ///
    /// The capability router
    /// ([`element_needs_legacy`](element_render::element_needs_legacy)) used to
    /// ask only about the ELEMENT — "does this element need a mask?" — and that
    /// question has no answer that is right for both backends.
    /// `Canvas2dPainter` executes isolated layers (#47) and mask layers (#55);
    /// `Direct2DPainter` executes neither. One element-only answer therefore
    /// either routes Canvas2D to legacy forever or routes Direct2D into an
    /// `unimplemented!()`. The router has to ask the BACKEND, so the backend
    /// has to be askable.
    ///
    /// # What a `true` means, precisely
    ///
    /// **The recorded command executes through this seam rather than falling
    /// into an unimplemented or unsupported arm.** It is NOT a claim about
    /// pixels — what a scene should look like is the goldens' job. That narrow
    /// meaning is chosen because it is the one both backends already MEASURE
    /// against the same corpus (D2D's `ReplayReport::unsupported`, the Canvas2D
    /// corpus driver's refusal list), so every answer here is cross-checked by
    /// a fixture rather than trusted.
    ///
    /// # ⛔ NO DEFAULT BODY, DELIBERATELY
    ///
    /// A default would be a claim made by OMISSION — the shape where a backend
    /// that never considered the question still answers, and nobody's diff ever
    /// shows the answer being given. `true` by default would route a new
    /// backend into a panic; `false` by default would quietly route it to
    /// legacy forever and look identical to a considered decision. Both are
    /// invisible. Every impl states its own answer, and a new backend does not
    /// compile until it does.
    ///
    /// See [`capability`] for how the vocabulary is derived from the fixtures.
    fn supports(&self, cap: capability::Capability) -> bool;

    /// Fill a path. `winding` is `EvenOdd` for boolean-op output that carries
    /// holes (AMENDMENT A3, RATIFIED 2026-07-23: fills carry a winding, not
    /// only `clip`). `paint_alpha` is the pinned paint-time `globalAlpha`
    /// multiply (today's `fill_op`) — AMENDMENT A4 (RATIFIED 2026-07-23) makes
    /// it an explicit per-paint PARAMETER, not trait state; the effective alpha
    /// is `(product of open group alphas) * paint_alpha`.
    fn fill_path(&mut self, path: &[PathCommand], winding: FillRule, brush: &Brush, paint_alpha: f64);

    /// Stroke a path. `paint_alpha` = today's `stroke_op`.
    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64);

    /// Fill an axis-aligned rectangle.
    fn fill_rect(&mut self, rect: Rect, brush: &Brush, paint_alpha: f64);

    /// Stroke an axis-aligned rectangle.
    fn stroke_rect(&mut self, rect: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64);

    /// Fill an ellipse arc (the missing-circle primitive). AMENDMENT A2
    /// (RATIFIED 2026-07-23): the contract's single `ellipse_arc` is split into
    /// fill/stroke here, to mirror `fill_path`/`stroke_path` and support
    /// fill-THEN-stroke of the SAME circle (today's Circle/Ellipse elements do
    /// exactly that) without a stateful path builder across the immediate seam.
    /// `winding` per AMENDMENT A3 (RATIFIED 2026-07-23).
    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, winding: FillRule, brush: &Brush, paint_alpha: f64);

    /// Stroke an ellipse arc.
    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64);

    /// Intersect the clip region with `path` under `winding`. Undone by the
    /// enclosing [`pop_state`](Painter::pop_state) (clip is part of saved
    /// state, exactly like the canvas). `EvenOdd` is first-class — the
    /// outside-stroke trick (a huge rect + the shape, clipped even-odd) is
    /// expressed by the CALLER building that compound path.
    ///
    /// AMENDMENT A5 — INVARIANT (RATIFIED 2026-07-23): `clip` is PATH-ONLY.
    /// There is no ellipse-clip entry (an elliptical clip region is a
    /// caller-built compound path, same as the outside-stroke trick), and the
    /// seam carries NO freeform-gradient policy: freeform gradients are a
    /// build-time lowering concern that never crosses this seam (today they
    /// render as unpainted / `None`, and the capability router keeps such
    /// elements on the legacy path). Nothing about clipping or gradient
    /// freeform-ness is expressible here beyond a path + winding — by design.
    fn clip(&mut self, path: &[PathCommand], winding: FillRule);

    /// Save drawing state and concatenate `transform` onto the CTM
    /// (`ctx.save()` then `ctx.transform(...)`). Alpha, clip, and composite op
    /// are all part of the saved state.
    fn push_state(&mut self, transform: Transform);

    /// Restore the state saved by the matching [`push_state`](Painter::push_state).
    fn pop_state(&mut self);

    /// Open a NON-ISOLATED group: `alpha` compounds (multiplies) into every
    /// descendant primitive; `blend` is set but inert under nesting (see module
    /// docs). No offscreen is allocated.
    fn push_group(&mut self, alpha: f64, blend: BlendMode);

    /// Close the group opened by the matching [`push_group`](Painter::push_group).
    fn pop_group(&mut self);

    /// Open a mask layer (DEFERRED — recorded, not rendered, in this spike).
    fn push_mask_layer(&mut self, mask: Mask);

    /// Close the mask layer opened by the matching
    /// [`push_mask_layer`](Painter::push_mask_layer).
    fn pop_mask_layer(&mut self);

    /// AMENDMENT A6 (ratified 2026-08-27). Open an ISOLATED layer: a fresh,
    /// transparent intermediate surface in the parent's coordinate frame and
    /// rasterization scale. Drawing inside the layer composites against the
    /// LAYER's content only — the parent backdrop is invisible (the opposite
    /// pole of `push_group`, which stays non-isolated). The open-group alpha
    /// product RESTARTS at 1.0 inside the layer; `alpha` and `blend` are
    /// consumed once, at the closing composite.
    ///
    /// The name says nothing about masks or elements on purpose: the seam
    /// speaks geometry, not document vocabulary (R3), and the bracket is
    /// useful maskless.
    fn push_isolated_layer(&mut self, alpha: f64, blend: BlendMode);

    /// Close the layer: flatten it and composite into the parent surface as ONE
    /// primitive, at effective alpha = (product of open group alphas at the
    /// push site) × `alpha`, under `blend`.
    ///
    /// ⛔ THE ALPHA APPLIES ONCE. Defect D-α (design block §2.1) is HEAD's
    /// double-apply: the masked path multiplied `elem.opacity()` into every body
    /// primitive AND again at the blit, and REPLACED the inherited ancestor
    /// product instead of multiplying into it — so a 0.5-opacity element in a
    /// 0.5-alpha group rendered at 0.25 from the element alone while the group's
    /// 0.5 never applied. The contract pins the MULTIPLICATIVE law, matching this
    /// module's global rule above and the unmasked path. Ratified 2026-08-27 with
    /// the reserved question answered: no shipped document depends on the HEAD
    /// rendering, so documents with masked elements at opacity < 1 WILL render
    /// differently after the repair, and that is accepted.
    fn pop_isolated_layer(&mut self);

    /// Draw a text run (see [`TextRun`]). Interleaves in z-order with the other
    /// primitives — text is a PH1 op, not a separate pass.
    fn draw_text_run(&mut self, run: &TextRun, brush: &Brush, paint_alpha: f64);
}
