//! Pure conversions from the Painter contract's vocabulary to Direct2D's.
//!
//! Every function here is a place a SILENT CROSS-PORT DIVERGENCE can live: the
//! output is not wrong in a way that crashes, it is wrong in a way that draws
//! slightly different pixels forever. B1 ranked these by "silence x blast
//! radius" and the three that reach this file are all here, each with the test
//! that pins it.
//!
//! No COM, no device, no GPU — these are enum and scalar maps, so they are
//! testable anywhere, including in CI on a machine with no display.

use crate::painter::{FillRule, LineCap, LineJoin, StrokeStyle};

use windows::Win32::Graphics::Direct2D::{
    D2D1_CAP_STYLE, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_SQUARE,
    D2D1_DASH_STYLE_CUSTOM, D2D1_DASH_STYLE_SOLID, D2D1_LINE_JOIN, D2D1_LINE_JOIN_BEVEL,
    D2D1_LINE_JOIN_MITER_OR_BEVEL, D2D1_LINE_JOIN_ROUND, D2D1_STROKE_STYLE_PROPERTIES,
};
// D2D1_FILL_MODE lives in ::Common, not the Direct2D root -- the geometry
// vocabulary is shared with the Common header.
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_FILL_MODE, D2D1_FILL_MODE_ALTERNATE, D2D1_FILL_MODE_WINDING,
};

/// Canvas2D's `lineJoin: "miter"` is NOT `D2D1_LINE_JOIN_MITER`.
///
/// D2D's plain `_MITER` keeps the spike at any angle; Canvas2D (and SVG, and
/// CoreGraphics) fall back to a bevel once the miter length exceeds the miter
/// limit. `_MITER_OR_BEVEL` is the one with that fallback, so it is the correct
/// map. Picking `_MITER` produces long spikes on acute joins that no other port
/// draws — visible, silent, and gated by nothing.
pub fn line_join(join: LineJoin) -> D2D1_LINE_JOIN {
    todo!("B1: map LineJoin")
}

pub fn line_cap(cap: LineCap) -> D2D1_CAP_STYLE {
    todo!("B1: map LineCap")
}

/// `FillRule::NonZero` -> WINDING, `EvenOdd` -> ALTERNATE.
///
/// Must be set on the sink BEFORE the first `BeginFigure`; D2D ignores it after.
pub fn fill_mode(rule: FillRule) -> D2D1_FILL_MODE {
    todo!("B1: map FillRule")
}

/// THE DASH-UNIT CONVERSION, and the trap inside it.
///
/// D2D dash entries are **multiples of the stroke width**; Canvas2D's are in
/// user units. So every entry needs dividing — and the divisor must be **the
/// width actually handed to `DrawGeometry`**, not the width on the incoming
/// `StrokeStyle`.
///
/// That distinction is the whole point. `element_render`'s inside/outside
/// stroke alignment lowers to clip + `doubled()`, which scales the width by 2.0
/// and leaves `dash` untouched. Divide by the pre-doubling width and every
/// aligned dashed stroke gets a dash period twice as long as every other port
/// draws it. Nothing compares pixels, so nothing would ever catch it.
///
/// `emit_width` is therefore a REQUIRED separate argument, not a convenience.
pub fn dash_multiples(dash: &[f64], emit_width: f64) -> Vec<f32> {
    todo!("B1: convert dash units")
}

/// Build the D2D stroke-style properties for a contract `StrokeStyle`.
///
/// `dash_cap` is set to the line cap deliberately: Canvas2D dashes inherit
/// `lineCap`, while D2D defaults `dashCap` to FLAT independently. Leaving it
/// default makes every round-capped dashed stroke draw square dashes.
pub fn stroke_properties(style: &StrokeStyle) -> D2D1_STROKE_STYLE_PROPERTIES {
    todo!("B1: stroke properties")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn miter_maps_to_miter_or_bevel_not_miter() {
        // The single most likely silent divergence in this file. D2D's plain
        // _MITER has no miter-limit fallback; every other port bevels.
        assert_eq!(line_join(LineJoin::Miter), D2D1_LINE_JOIN_MITER_OR_BEVEL);
        assert_eq!(line_join(LineJoin::Round), D2D1_LINE_JOIN_ROUND);
        assert_eq!(line_join(LineJoin::Bevel), D2D1_LINE_JOIN_BEVEL);
    }

    #[test]
    fn caps_map_butt_to_flat() {
        assert_eq!(line_cap(LineCap::Butt), D2D1_CAP_STYLE_FLAT);
        assert_eq!(line_cap(LineCap::Round), D2D1_CAP_STYLE_ROUND);
        assert_eq!(line_cap(LineCap::Square), D2D1_CAP_STYLE_SQUARE);
    }

    #[test]
    fn fill_rules_map() {
        assert_eq!(fill_mode(FillRule::NonZero), D2D1_FILL_MODE_WINDING);
        assert_eq!(fill_mode(FillRule::EvenOdd), D2D1_FILL_MODE_ALTERNATE);
    }

    #[test]
    fn dashes_are_divided_by_the_emitted_width() {
        // 10-user-unit dashes on a 2-wide stroke are 5 stroke-widths in D2D.
        let got = dash_multiples(&[10.0, 6.0], 2.0);
        assert_eq!(got, vec![5.0_f32, 3.0]);
    }

    #[test]
    fn the_doubled_width_trap_is_the_reason_emit_width_is_a_parameter() {
        // element_render's aligned-stroke path calls doubled(): width 2 -> 4,
        // dash UNCHANGED. If the divisor were the StrokeStyle's own width the
        // period would come out 2x too long, on every aligned dashed stroke, in
        // silence.
        let contract_dash = [10.0, 6.0];
        let wrong = dash_multiples(&contract_dash, 2.0); // pre-doubling width
        let right = dash_multiples(&contract_dash, 4.0); // width actually emitted
        assert_eq!(right, vec![2.5_f32, 1.5]);
        assert_ne!(wrong, right, "the trap must be observable, not theoretical");
        // and the error is exactly a factor of two
        for (w, r) in wrong.iter().zip(right.iter()) {
            assert!((w / r - 2.0).abs() < 1e-6);
        }
    }

    #[test]
    fn a_zero_width_stroke_cannot_divide_by_zero() {
        // Hairlines exist; D2D treats width 0 as a 1-pixel hairline rather than
        // an error, so this must not produce inf/NaN dash entries.
        let got = dash_multiples(&[4.0, 2.0], 0.0);
        assert!(got.iter().all(|v| v.is_finite()), "got {got:?}");
    }

    #[test]
    fn an_empty_dash_is_solid_not_an_empty_custom_pattern() {
        let p = stroke_properties(&StrokeStyle {
            width: 3.0,
            cap: LineCap::Butt,
            join: LineJoin::Miter,
            miter: 4.0,
            dash: vec![],
        });
        assert_eq!(p.dashStyle, D2D1_DASH_STYLE_SOLID);
    }

    #[test]
    fn a_dashed_style_is_custom_and_carries_cap_into_dashcap() {
        // Canvas2D dashes inherit lineCap; D2D defaults dashCap to FLAT, so a
        // round-capped dashed stroke would silently draw square dashes.
        let p = stroke_properties(&StrokeStyle {
            width: 3.0,
            cap: LineCap::Round,
            join: LineJoin::Round,
            miter: 10.0,
            dash: vec![6.0, 3.0],
        });
        assert_eq!(p.dashStyle, D2D1_DASH_STYLE_CUSTOM);
        assert_eq!(p.dashCap, D2D1_CAP_STYLE_ROUND);
        assert_eq!(p.startCap, D2D1_CAP_STYLE_ROUND);
        assert_eq!(p.endCap, D2D1_CAP_STYLE_ROUND);
        assert_eq!(p.miterLimit, 10.0_f32);
    }
}
