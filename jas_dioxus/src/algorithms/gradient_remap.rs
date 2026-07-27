//! Re-express a LINEAR gradient's stop locations on a sub-region of the
//! element it was authored on. Geometry-only: no document, no element.
//!
//! # Why this exists
//!
//! A gradient in this model carries **no position**. A linear gradient is an
//! `angle` plus a list of stops, and the painter resolves it against the
//! element's OWN bounding box: the ramp runs from `centre - half_diag * u` to
//! `centre + half_diag * u`, where `u = (cos θ, −sin θ)` and `half_diag` is
//! half the bbox diagonal (`painter::element_render::resolve_gradient`).
//!
//! So when an element is SPLIT — a severing path erase, whose fragments each
//! inherit the parent's gradient verbatim — every fragment re-fits the whole
//! ramp to its own smaller box. Three fragments of a red-to-blue hull each run
//! the full red-to-blue instead of each showing its slice.
//!
//! # The remap
//!
//! Parent and fragment share the angle, so they project onto the SAME
//! direction `u` and every parent stop has a well-defined absolute position
//! along it. Re-expressing that position as a fraction of the fragment's own
//! span is a plain affine map of `location`, which this module applies, then
//! clips to `[0, 100]` with interpolated colours inserted at the endpoints so
//! the visible ramp is exact.
//!
//! # What it does NOT do
//!
//! - **RADIAL is not remapped.** A radial gradient's centre is forced to the
//!   bbox centre and the model has nowhere to record an anchor, so a fragment
//!   necessarily re-centres. JYH accepted the recentre (2026-07-26); a
//!   "gradient anchor" field is banked as a separate stone. Callers must not
//!   route radial through here.
//! - **FREEFORM is not remapped.** Freeform gradients carry nodes, not stops,
//!   and `resolve_gradient` returns `None` for them — nothing is painted, so
//!   there is nothing to preserve.
//! - **`midpoint_to_next` is carried through unchanged.** It is the one field
//!   this remap does not correct, and the reason it is not a visible error
//!   today is that `resolve_gradient` never reads it: it builds its
//!   `ColorStop`s from `location`, `color` and `opacity` only. If the painter
//!   ever honours midpoints, a clipped first or last segment will need its
//!   midpoint recomputed and this note is the place that says so.

use crate::geometry::element::{Color, GradientStop};

/// A bounding box as `(x, y, w, h)` — the same shape
/// `painter::element_render::resolve_gradient` receives.
pub type BBox = (f64, f64, f64, f64);

/// Scalar position of a bbox centre along the gradient direction, and half the
/// bbox diagonal — the two numbers that place a linear ramp.
///
/// `u = (cos θ, −sin θ)` matches the painter exactly, y-down negation
/// included. The centre's projection is `centre · u`; because both boxes use
/// the same `u`, the difference of two such projections is the signed distance
/// between the two ramp centres along the ramp.
fn axis_frame(bbox: BBox, angle_deg: f64) -> (f64, f64) {
    let (bx, by, bw, bh) = bbox;
    let rad = angle_deg * std::f64::consts::PI / 180.0;
    let ux = rad.cos();
    let uy = -rad.sin();
    let cx = bx + bw / 2.0;
    let cy = by + bh / 2.0;
    let half_diag = (bw * bw + bh * bh).sqrt() / 2.0;
    (cx * ux + cy * uy, half_diag)
}

/// Linear blend of two stops' colour and opacity at fraction `t` of the way
/// from `a` to `b`.
///
/// Channel-wise in **sRGB**, because that is the space the ramp is
/// interpolated in downstream: `resolve_gradient` hands the painter plain
/// `ColorStop`s and the renderer blends their RGBA. A consequence worth
/// stating rather than discovering: an endpoint inserted between two CMYK or
/// HSB stops comes out as `Color::Rgb`, since it is the colour that space
/// produced at that position and there is no round trip back.
fn blend(a: &GradientStop, b: &GradientStop, t: f64) -> (Color, f64) {
    let (ar, ag, ab, aa) = a.color.to_rgba();
    let (br, bg, bb, ba) = b.color.to_rgba();
    let mix = |x: f64, y: f64| x + (y - x) * t;
    (
        Color::Rgb {
            r: mix(ar, br),
            g: mix(ag, bg),
            b: mix(ab, bb),
            a: mix(aa, ba),
        },
        mix(a.opacity, b.opacity),
    )
}

/// Colour and opacity of the ramp at remapped location `at`, given stops whose
/// `location`s are the REMAPPED ones (already possibly outside `[0, 100]`) in
/// non-decreasing order. Before the first stop and after the last, a linear
/// gradient paints the end colour flat, which is what the clamped arms return.
fn sample(remapped: &[GradientStop], at: f64) -> (Color, f64) {
    let first = &remapped[0];
    let last = &remapped[remapped.len() - 1];
    if at <= first.location {
        return (first.color, first.opacity);
    }
    if at >= last.location {
        return (last.color, last.opacity);
    }
    for w in remapped.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        if at >= a.location && at <= b.location {
            let span = b.location - a.location;
            // Coincident stops are a hard colour break; take the later one,
            // which is what a zero-width segment means.
            if span <= 0.0 {
                return (b.color, b.opacity);
            }
            return blend(a, b, (at - a.location) / span);
        }
    }
    (last.color, last.opacity)
}

/// Remap `stops` (a LINEAR gradient's, authored against `parent`) onto the
/// sub-region `fragment`, both at the same `angle_deg`.
///
/// Returns stops whose `location`s all lie in `[0, 100]` and which paint the
/// same colours over `fragment` that the parent's ramp painted there.
///
/// Returns the input unchanged when there is nothing to do or nothing to do it
/// with: fewer than two stops (the painter refuses to build a brush at all),
/// or a fragment whose diagonal is zero (a degenerate box has no span to map
/// onto, and dividing by it would produce infinities).
pub fn remap_linear_stops(
    stops: &[GradientStop],
    angle_deg: f64,
    parent: BBox,
    fragment: BBox,
) -> Vec<GradientStop> {
    if stops.len() < 2 {
        return stops.to_vec();
    }
    let (parent_centre, parent_half) = axis_frame(parent, angle_deg);
    let (frag_centre, frag_half) = axis_frame(fragment, angle_deg);
    if frag_half <= 0.0 {
        return stops.to_vec();
    }

    // A stop at parent location L sits at absolute position
    //   parent_centre + (2L/100 − 1) · parent_half
    // and the fragment's own ramp spans frag_centre ± frag_half, so
    //   L' = 50 · ( (absolute − frag_centre) / frag_half + 1 ).
    let remapped: Vec<GradientStop> = stops
        .iter()
        .map(|s| {
            let absolute =
                parent_centre + (2.0 * s.location / 100.0 - 1.0) * parent_half;
            GradientStop {
                location: 50.0 * ((absolute - frag_centre) / frag_half + 1.0),
                ..*s
            }
        })
        .collect();

    // Clip to [0, 100]. Interior stops survive as they are; the two ends are
    // replaced by SAMPLES of the remapped ramp, so the colour at the
    // fragment's own edges is the colour the parent's ramp had there.
    let mut out: Vec<GradientStop> = Vec::with_capacity(remapped.len() + 2);
    let (c0, o0) = sample(&remapped, 0.0);
    out.push(GradientStop {
        color: c0,
        opacity: o0,
        location: 0.0,
        midpoint_to_next: remapped[0].midpoint_to_next,
    });
    for s in &remapped {
        if s.location > 0.0 && s.location < 100.0 {
            out.push(*s);
        }
    }
    let (c1, o1) = sample(&remapped, 100.0);
    out.push(GradientStop {
        color: c1,
        opacity: o1,
        location: 100.0,
        midpoint_to_next: remapped[remapped.len() - 1].midpoint_to_next,
    });
    out
}
