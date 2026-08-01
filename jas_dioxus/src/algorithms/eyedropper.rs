//! Eyedropper extract / apply helpers.
//!
//! Two pure functions plus an `Appearance` data container:
//!
//!   - `extract_appearance(element) -> Appearance`
//!     Snapshot a source element's relevant attrs into a serializable
//!     blob suitable for `state.eyedropper_cache`.
//!
//!   - `apply_appearance(target, appearance, config) -> Element`
//!     Return a copy of `target` with attrs from `appearance` written
//!     onto it, gated by the master / sub toggles in `config`.
//!
//! See `transcripts/EYEDROPPER_TOOL.md` for the full spec.
//! Cross-language parity is mechanical — the OCaml / Swift / Python
//! ports of this module follow the same shape.
//!
//! Phase 1 limitations:
//!
//!   - Character and Paragraph extraction / apply is stubbed; the
//!     `Appearance` carries `character` / `paragraph` as opaque JSON
//!     so the cache can round-trip without losing data, but Phase 1
//!     writes don't yet thread through Text element internals. A
//!     later phase will replace the JSON values with concrete structs
//!     and proper Text-element wiring.
//!
//!   - Stroke profile (variable-width points) lives on the element
//!     in `width_points`, not in `Stroke`. The `stroke_profile`
//!     toggle copies that field on Path / Line; other element types
//!     have no profile.
//!
//!   - Gradient / pattern fills are not sampled in Phase 1 — only
//!     solid fills round-trip. A non-solid source fill is treated as
//!     "no fill data sampled" (cached as `None`).

use serde::{Deserialize, Serialize};

use crate::geometry::element::{
    BlendMode, Color, Element, Fill, Stroke, StrokeWidthPoint, Visibility,
    with_fill, with_stroke, with_stroke_brush, with_width_points,
};

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/// Snapshot of a source element's attrs. Round-trips through JSON via
/// `state.eyedropper_cache`.
///
/// Fields are `Option`-wrapped so the cache can encode "not sampled"
/// distinctly from "sampled as default". `Option<Fill>` and
/// `Option<Stroke>` follow the document model's own use of these
/// types — `None` means the source had no fill / stroke (or had
/// `fill=none` / `stroke=none`); the apply path treats both the same
/// in Phase 1.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Appearance {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<Fill>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke: Option<Stroke>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f64>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blend_mode: Option<BlendMode>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_brush: Option<String>,

    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub width_points: Vec<StrokeWidthPoint>,

    /// Phase 1 stub: character data is round-tripped as opaque JSON.
    /// A follow-up phase replaces this with concrete fields and full
    /// Text-element extract / apply.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub character: Option<serde_json::Value>,

    /// Phase 1 stub for paragraph data — same caveat as `character`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paragraph: Option<serde_json::Value>,
}

/// Toggle configuration mirroring the 25 `state.eyedropper_*`
/// boolean keys. Master toggles gate entire groups; sub-toggles
/// gate individual attrs within a group. Both must be true for an
/// attribute to be applied.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EyedropperConfig {
    pub fill: bool,

    pub stroke: bool,
    pub stroke_color: bool,
    pub stroke_weight: bool,
    pub stroke_cap_join: bool,
    pub stroke_align: bool,
    pub stroke_dash: bool,
    pub stroke_arrowheads: bool,
    pub stroke_profile: bool,
    pub stroke_brush: bool,

    pub opacity: bool,
    pub opacity_alpha: bool,
    pub opacity_blend: bool,

    pub character: bool,
    pub character_font: bool,
    pub character_size: bool,
    pub character_leading: bool,
    pub character_kerning: bool,
    pub character_tracking: bool,
    pub character_color: bool,

    pub paragraph: bool,
    pub paragraph_align: bool,
    pub paragraph_indent: bool,
    pub paragraph_space: bool,
    pub paragraph_hyphenate: bool,
}

impl Default for EyedropperConfig {
    fn default() -> Self {
        // All toggles on by default per EYEDROPPER_TOOL.md
        // §State persistence.
        Self {
            fill: true,
            stroke: true,
            stroke_color: true,
            stroke_weight: true,
            stroke_cap_join: true,
            stroke_align: true,
            stroke_dash: true,
            stroke_arrowheads: true,
            stroke_profile: true,
            stroke_brush: true,
            opacity: true,
            opacity_alpha: true,
            opacity_blend: true,
            character: true,
            character_font: true,
            character_size: true,
            character_leading: true,
            character_kerning: true,
            character_tracking: true,
            character_color: true,
            paragraph: true,
            paragraph_align: true,
            paragraph_indent: true,
            paragraph_space: true,
            paragraph_hyphenate: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Eligibility
// ---------------------------------------------------------------------------

/// Source-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
/// Locked is OK (we read, don't write); Hidden is not (no hit-test).
/// Group / Layer are never sources — the caller is responsible for
/// descending to the innermost element under the cursor.
pub fn is_source_eligible(element: &Element) -> bool {
    if matches!(element.common().visibility, Visibility::Invisible) {
        return false;
    }
    !matches!(element, Element::Group(_) | Element::Layer(_))
}

/// Target-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
/// Locked is not OK (writes need permission); Hidden is OK (writes
/// persist). Group / Layer are never targets — the caller recurses
/// into them and applies to leaves.
pub fn is_target_eligible(element: &Element) -> bool {
    if element.common().locked {
        return false;
    }
    !matches!(element, Element::Group(_) | Element::Layer(_))
}

// ---------------------------------------------------------------------------
// Extract
// ---------------------------------------------------------------------------

/// Snapshot the source element's attrs into an `Appearance`.
/// Caller is responsible for source-eligibility; this function does
/// not filter.
pub fn extract_appearance(element: &Element) -> Appearance {
    Appearance {
        fill: element.fill().copied(),
        stroke: element.stroke().copied(),
        opacity: Some(element.common().opacity),
        blend_mode: Some(element.common().mode),
        stroke_brush: extract_stroke_brush(element),
        width_points: extract_width_points(element),
        character: None,  // Phase 1 stub
        paragraph: None,  // Phase 1 stub
    }
}

fn extract_stroke_brush(element: &Element) -> Option<String> {
    if let Element::Path(p) = element {
        p.stroke_brush.clone()
    } else {
        None
    }
}

fn extract_width_points(element: &Element) -> Vec<StrokeWidthPoint> {
    match element {
        Element::Line(e) => e.width_points.clone(),
        Element::Path(e) => e.width_points.clone(),
        _ => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------------

/// Return a copy of `target` with the attrs from `appearance` applied
/// per `config`. Master OFF skips the entire group; master ON +
/// sub OFF skips that sub-attribute. Caller is responsible for
/// target-eligibility (locked / container check); this function
/// applies to whatever it's given.
pub fn apply_appearance(
    target: &Element,
    appearance: &Appearance,
    config: &EyedropperConfig,
) -> Element {
    let mut result = target.clone();

    // ── Fill ──
    if config.fill {
        result = with_fill(&result, appearance.fill);
    }

    // ── Stroke (master + sub-toggles, then brush + profile separately) ──
    if config.stroke {
        result = apply_stroke_with_subs(&result, appearance.stroke.as_ref(), config);
        if config.stroke_brush {
            result = with_stroke_brush(&result, appearance.stroke_brush.clone());
        }
        if config.stroke_profile {
            // Profile lives in width_points (Line / Path only); other
            // element types have no profile and the call is a no-op.
            result = with_width_points(&result, appearance.width_points.clone());
        }
    }

    // ── Opacity (master + 2 sub-toggles) ──
    if config.opacity {
        if config.opacity_alpha
            && let Some(op) = appearance.opacity
        {
            result.common_mut().opacity = op;
        }
        if config.opacity_blend
            && let Some(blend) = appearance.blend_mode
        {
            result.common_mut().mode = blend;
        }
    }

    // ── Character / Paragraph: Phase 1 stub (no-op) ──
    // Future phase will read appearance.character / .paragraph and
    // write into the Text element's tspan tree.

    result
}

/// The stroke a fabrication starts from when a ticked sub-toggle would
/// write a stroke attribute onto a target that has no stroke at all.
///
/// RULED (JYH 2026-07-31): the colour and width come from the APP's
/// default stroke — `workspace/state.yaml`'s `stroke_color` (`#000000`)
/// and `stroke_width` (1.0), the same pair `Model::new` seeds
/// `default_stroke` / `app_default_stroke` with — and NEVER from the
/// source. Seeding from the source transfers two attributes the artist
/// deselected. (Refusing to fabricate at all was the alternative, and
/// was rejected on usability: tick dash, click, nothing happens.)
fn fabricated_stroke_base() -> Stroke {
    Stroke::new(Color::BLACK, 1.0)
}

/// Helper for the Stroke group's per-sub-toggle apply. Uses the
/// existing `with_stroke` helper; fabricates a stroke from the app
/// defaults when the target has none and at least one sub-toggle would
/// copy a field.
fn apply_stroke_with_subs(
    target: &Element,
    src: Option<&Stroke>,
    config: &EyedropperConfig,
) -> Element {
    let Some(src_stroke) = src else {
        // Source had no stroke. That is not a licence to ignore the
        // sub-toggles — this branch honours them exactly as the `Some`
        // branch below does. "No stroke" is a value of the stroke_color
        // attribute (EYEDROPPER_TOOL.md §Stroke: that sub-toggle covers
        // "color, none, gradient, or pattern"), so it transfers only
        // when stroke_color is ticked. Every other sub-toggle has
        // nothing to read off a stroke that isn't there, and is a no-op
        // per the spec's "source lacks the attribute → no-op" rule.
        return if config.stroke_color {
            with_stroke(target, None)
        } else {
            target.clone()
        };
    };

    let any_stroke_sub = config.stroke_color
        || config.stroke_weight
        || config.stroke_cap_join
        || config.stroke_align
        || config.stroke_dash
        || config.stroke_arrowheads;
    if !any_stroke_sub {
        // All sub-toggles off — leave target's stroke alone.
        return target.clone();
    }

    // Start from target's existing stroke, or fabricate one from the
    // app defaults when the target had none — see
    // `fabricated_stroke_base`. Whatever the ticked sub-toggles copy
    // below then lands on top of that base; the fields they do NOT
    // cover keep the app default rather than a value smuggled in from
    // the source.
    let mut new_stroke = target
        .stroke()
        .copied()
        .unwrap_or_else(fabricated_stroke_base);

    if config.stroke_color {
        new_stroke.color = src_stroke.color;
        new_stroke.opacity = src_stroke.opacity;
    }
    if config.stroke_weight {
        new_stroke.width = src_stroke.width;
    }
    if config.stroke_cap_join {
        new_stroke.linecap = src_stroke.linecap;
        new_stroke.linejoin = src_stroke.linejoin;
        new_stroke.miter_limit = src_stroke.miter_limit;
    }
    if config.stroke_align {
        new_stroke.align = src_stroke.align;
    }
    if config.stroke_dash {
        new_stroke.dash_pattern = src_stroke.dash_pattern;
        new_stroke.dash_len = src_stroke.dash_len;
    }
    if config.stroke_arrowheads {
        new_stroke.start_arrow = src_stroke.start_arrow;
        new_stroke.end_arrow = src_stroke.end_arrow;
        new_stroke.start_arrow_scale = src_stroke.start_arrow_scale;
        new_stroke.end_arrow_scale = src_stroke.end_arrow_scale;
        new_stroke.arrow_align = src_stroke.arrow_align;
    }

    with_stroke(target, Some(new_stroke))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{
        Color, CommonProps, LineCap, LineJoin, RectElem, StrokeAlign,
        Arrowhead, ArrowAlign, LineElem, GroupElem,
    };

    fn red_fill() -> Fill {
        Fill { color: Color::rgb(1.0, 0.0, 0.0), opacity: 1.0 }
    }

    fn blue_stroke() -> Stroke {
        let mut s = Stroke::new(Color::rgb(0.0, 0.0, 1.0), 4.0);
        s.linecap = LineCap::Round;
        s.linejoin = LineJoin::Bevel;
        s.align = StrokeAlign::Inside;
        s
    }

    fn rect_with(fill: Option<Fill>, stroke: Option<Stroke>) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 100.0, rx: 0.0, ry: 0.0,
            fill, stroke, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        })
    }

    fn line_with(stroke: Option<Stroke>) -> Element {
        Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 10.0, y2: 10.0,
            stroke, width_points: Vec::new(),
            common: CommonProps::default(), stroke_gradient: None,
        })
    }

    #[test]
    fn extract_rect_with_fill_and_stroke() {
        let el = rect_with(Some(red_fill()), Some(blue_stroke()));
        let app = extract_appearance(&el);
        assert_eq!(app.fill, Some(red_fill()));
        assert_eq!(app.stroke, Some(blue_stroke()));
        assert_eq!(app.opacity, Some(1.0));
        assert_eq!(app.blend_mode, Some(BlendMode::Normal));
        assert_eq!(app.stroke_brush, None);
    }

    #[test]
    fn extract_line_has_no_fill() {
        let el = line_with(Some(blue_stroke()));
        let app = extract_appearance(&el);
        assert_eq!(app.fill, None);
        assert_eq!(app.stroke, Some(blue_stroke()));
    }

    #[test]
    fn appearance_json_roundtrip() {
        let app = Appearance {
            fill: Some(red_fill()),
            stroke: Some(blue_stroke()),
            opacity: Some(0.75),
            blend_mode: Some(BlendMode::Multiply),
            stroke_brush: Some("calligraphic_default".to_string()),
            width_points: Vec::new(),
            character: None,
            paragraph: None,
        };
        let s = serde_json::to_string(&app).unwrap();
        let back: Appearance = serde_json::from_str(&s).unwrap();
        assert_eq!(app, back);
    }

    #[test]
    fn apply_master_off_skips_group() {
        let src = rect_with(Some(red_fill()), Some(blue_stroke()));
        let app = extract_appearance(&src);
        let target = rect_with(None, None);
        let mut cfg = EyedropperConfig::default();
        cfg.fill = false;
        cfg.stroke = false;
        cfg.opacity = false;
        let out = apply_appearance(&target, &app, &cfg);
        assert_eq!(out.fill(), None);
        assert_eq!(out.stroke(), None);
    }

    #[test]
    fn apply_stroke_color_sub_only() {
        let src = rect_with(None, Some(blue_stroke()));
        let app = extract_appearance(&src);
        let mut existing = Stroke::new(Color::rgb(0.5, 0.5, 0.5), 2.0);
        existing.linecap = LineCap::Square;
        let target = rect_with(None, Some(existing));
        let cfg = EyedropperConfig {
            stroke: true,
            stroke_color: true,
            stroke_weight: false,
            stroke_cap_join: false,
            stroke_align: false,
            stroke_dash: false,
            stroke_arrowheads: false,
            stroke_brush: false,
            stroke_profile: false,
            ..EyedropperConfig::default()
        };
        let out = apply_appearance(&target, &app, &cfg);
        let out_stroke = out.stroke().unwrap();
        // Color copied from source...
        assert_eq!(out_stroke.color, Color::rgb(0.0, 0.0, 1.0));
        // ...but weight, cap, etc. preserved from target.
        assert_eq!(out_stroke.width, 2.0);
        assert_eq!(out_stroke.linecap, LineCap::Square);
    }

    #[test]
    fn apply_opacity_alpha_only() {
        let mut src = rect_with(None, None);
        src.common_mut().opacity = 0.4;
        src.common_mut().mode = BlendMode::Screen;
        let app = extract_appearance(&src);
        let target = rect_with(None, None);
        let cfg = EyedropperConfig {
            opacity: true,
            opacity_alpha: true,
            opacity_blend: false,
            ..EyedropperConfig::default()
        };
        let out = apply_appearance(&target, &app, &cfg);
        assert_eq!(out.common().opacity, 0.4);
        assert_eq!(out.common().mode, BlendMode::Normal); // unchanged
    }

    /// A source stroke that is loud in every field the artist did NOT
    /// tick, so a value leaking through from the source is unmistakable.
    fn dashed_magenta_stroke() -> Stroke {
        let mut s = Stroke::new(Color::rgb(1.0, 0.0, 1.0), 9.0);
        s.dash_pattern = [6.0, 3.0, 0.0, 0.0, 0.0, 0.0];
        s.dash_len = 2;
        s
    }

    /// CASE 1, THE SEED — RULED (JYH 2026-07-31).
    ///
    /// Target has no stroke; source has a dashed one; the artist ticked
    /// `stroke_dash` but deselected `stroke_color` and `stroke_weight`.
    /// A dash needs a stroke to live on, so one is fabricated — and the
    /// colour and width of that fabrication come from the APP's default
    /// (`workspace/state.yaml`: `stroke_color: "#000000"`,
    /// `stroke_width: 1.0`), never from the source. Sourcing them
    /// transfers two attributes the artist switched off.
    #[test]
    fn fabricated_stroke_seeds_from_app_default_not_source() {
        let src = rect_with(None, Some(dashed_magenta_stroke()));
        let app = extract_appearance(&src);
        let target = rect_with(Some(red_fill()), None); // no stroke at all
        let cfg = EyedropperConfig {
            fill: false,
            stroke: true,
            stroke_color: false,
            stroke_weight: false,
            stroke_cap_join: false,
            stroke_align: false,
            stroke_dash: true,
            stroke_arrowheads: false,
            stroke_brush: false,
            stroke_profile: false,
            opacity: false,
            ..EyedropperConfig::default()
        };

        let out = apply_appearance(&target, &app, &cfg);
        let s = out.stroke().expect("a ticked dash sub-toggle fabricates a stroke");

        // The one attribute the artist ticked does come from the source.
        assert_eq!(s.dash_len, 2);
        assert_eq!(&s.dash_pattern[..2], &[6.0, 3.0]);

        // The two the artist deselected come from the app default.
        assert_eq!(s.color, Color::BLACK, "fabricated colour leaked from the source");
        assert_eq!(s.width, 1.0, "fabricated width leaked from the source");
    }

    /// The seed is the app default even when NO loud sub-toggle is the
    /// dash — `stroke_align` alone is enough to force a fabrication, and
    /// it must not drag the source's paint along with it.
    #[test]
    fn fabricated_stroke_seeds_from_app_default_for_any_sub_toggle() {
        let src = rect_with(None, Some(dashed_magenta_stroke()));
        let app = extract_appearance(&src);
        let target = rect_with(None, None);
        let cfg = EyedropperConfig {
            fill: false,
            stroke: true,
            stroke_color: false,
            stroke_weight: false,
            stroke_cap_join: false,
            stroke_align: true,
            stroke_dash: false,
            stroke_arrowheads: false,
            stroke_brush: false,
            stroke_profile: false,
            opacity: false,
            ..EyedropperConfig::default()
        };

        let out = apply_appearance(&target, &app, &cfg);
        let s = out.stroke().expect("a ticked align sub-toggle fabricates a stroke");
        assert_eq!(s.align, StrokeAlign::Center); // source's align, which is Center
        assert_eq!(s.color, Color::BLACK, "fabricated colour leaked from the source");
        assert_eq!(s.width, 1.0, "fabricated width leaked from the source");
    }

    /// CASE 2, THE DEFECT. Master ON + source has NO stroke used to clear
    /// the target outright, ignoring every sub-toggle — asymmetric with
    /// the `Some` branch, which honours them. "No stroke" is a value of
    /// the `stroke_color` attribute (EYEDROPPER_TOOL.md §Stroke: that
    /// sub-toggle covers "color, none, gradient, or pattern"), so with
    /// `stroke_color` OFF the artist never asked for the target's paint
    /// to change, and nothing about the target's stroke may move.
    #[test]
    fn source_without_stroke_respects_stroke_color_off() {
        let src = rect_with(Some(red_fill()), None); // source has no stroke
        let app = extract_appearance(&src);
        let target = rect_with(None, Some(blue_stroke()));
        let cfg = EyedropperConfig {
            fill: false,
            stroke: true,
            stroke_color: false, // every OTHER stroke sub-toggle stays ON
            opacity: false,
            ..EyedropperConfig::default()
        };

        let out = apply_appearance(&target, &app, &cfg);
        assert_eq!(
            out.stroke(),
            Some(&blue_stroke()),
            "a stroke-less source wiped the target with stroke_color off",
        );
    }

    /// The same branch under EYE-112: master ON, source has no stroke,
    /// EVERY stroke sub-toggle off → the target is left alone, exactly as
    /// the `Some` branch's all-subs-off short-circuit leaves it alone.
    #[test]
    fn source_without_stroke_all_subs_off_leaves_target_alone() {
        let src = rect_with(Some(red_fill()), None);
        let app = extract_appearance(&src);
        let target = rect_with(None, Some(blue_stroke()));
        let cfg = EyedropperConfig {
            fill: false,
            stroke: true,
            stroke_color: false,
            stroke_weight: false,
            stroke_cap_join: false,
            stroke_align: false,
            stroke_dash: false,
            stroke_arrowheads: false,
            stroke_brush: false,
            stroke_profile: false,
            opacity: false,
            ..EyedropperConfig::default()
        };

        let out = apply_appearance(&target, &app, &cfg);
        assert_eq!(out.stroke(), Some(&blue_stroke()));
    }

    /// EYE-111, the other half of the same branch, kept as a guard: with
    /// `stroke_color` ON a stroke-less source still means "no stroke",
    /// and the target's stroke goes. This passed before the CASE 2 repair
    /// and must keep passing after it.
    #[test]
    fn source_without_stroke_clears_target_when_stroke_color_on() {
        let src = rect_with(Some(red_fill()), None);
        let app = extract_appearance(&src);
        let target = rect_with(None, Some(blue_stroke()));
        let cfg = EyedropperConfig {
            fill: false,
            stroke: true,
            stroke_color: true,
            opacity: false,
            ..EyedropperConfig::default()
        };

        let out = apply_appearance(&target, &app, &cfg);
        assert_eq!(out.stroke(), None);
    }

    #[test]
    fn source_eligibility_filters_hidden_and_containers() {
        let mut hidden = rect_with(None, None);
        hidden.common_mut().visibility = Visibility::Invisible;
        assert!(!is_source_eligible(&hidden));

        let visible = rect_with(None, None);
        assert!(is_source_eligible(&visible));

        let mut locked = rect_with(None, None);
        locked.common_mut().locked = true;
        // Locked is OK on source side.
        assert!(is_source_eligible(&locked));

        let group = Element::Group(GroupElem::default());
        assert!(!is_source_eligible(&group));
    }

    #[test]
    fn target_eligibility_filters_locked_and_containers() {
        let unlocked = rect_with(None, None);
        assert!(is_target_eligible(&unlocked));

        let mut locked = rect_with(None, None);
        locked.common_mut().locked = true;
        assert!(!is_target_eligible(&locked));

        // Hidden is OK on target side (writes persist).
        let mut hidden = rect_with(None, None);
        hidden.common_mut().visibility = Visibility::Invisible;
        assert!(is_target_eligible(&hidden));

        let group = Element::Group(GroupElem::default());
        assert!(!is_target_eligible(&group));
    }
}
