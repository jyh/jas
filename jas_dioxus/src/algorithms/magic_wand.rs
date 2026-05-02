//! Magic Wand match predicate.
//!
//! Pure function: given a seed element, a candidate element, and the
//! nine `state.magic_wand_*` configuration values, decide whether
//! the candidate is "similar" to the seed under the enabled
//! criteria.
//!
//! See `transcripts/MAGIC_WAND_TOOL.md` §Predicate for the rules.
//! Cross-language parity is mechanical — the OCaml / Swift / Python
//! ports of this module use the same logic.

use crate::geometry::element::{BlendMode, Element, Fill, Stroke};

/// The five-criterion configuration mirrors `state.magic_wand_*`.
/// Each criterion has an enabled flag (true = participate in the
/// predicate) and, where applicable, a tolerance.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MagicWandConfig {
    /// Fill Color criterion enabled.
    pub fill_color: bool,
    /// Maximum Euclidean RGB distance on the 0–255 scale.
    pub fill_tolerance: f64,

    /// Stroke Color criterion enabled.
    pub stroke_color: bool,
    /// Maximum Euclidean RGB distance on the 0–255 scale.
    pub stroke_tolerance: f64,

    /// Stroke Weight criterion enabled.
    pub stroke_weight: bool,
    /// Maximum |Δ width| in pt.
    pub stroke_weight_tolerance: f64,

    /// Opacity criterion enabled.
    pub opacity: bool,
    /// Maximum |Δ opacity| × 100 in percentage points.
    pub opacity_tolerance: f64,

    /// Blending Mode criterion enabled. Exact-match only — no
    /// tolerance (blend mode is categorical).
    pub blending_mode: bool,
}

impl Default for MagicWandConfig {
    fn default() -> Self {
        // Reference design defaults — the four "obvious" criteria
        // on, Blending Mode off, plus the published tolerances.
        Self {
            fill_color: true,
            fill_tolerance: 32.0,
            stroke_color: true,
            stroke_tolerance: 32.0,
            stroke_weight: true,
            stroke_weight_tolerance: 5.0,
            opacity: true,
            opacity_tolerance: 5.0,
            blending_mode: false,
        }
    }
}

/// Decide whether `candidate` is similar to `seed` under the
/// enabled criteria. AND across all enabled criteria — a single
/// disqualifying criterion means no match. When all criteria are
/// disabled the function returns `false` (the wand is a no-op in
/// that case; the click handler treats this as "select only the
/// seed itself", but that's the *caller's* responsibility, not
/// ours).
pub fn magic_wand_match(
    seed: &Element,
    candidate: &Element,
    cfg: &MagicWandConfig,
) -> bool {
    let any_enabled = cfg.fill_color || cfg.stroke_color
        || cfg.stroke_weight || cfg.opacity || cfg.blending_mode;
    if !any_enabled {
        return false;
    }
    if cfg.fill_color
        && !fill_color_matches(seed.fill(), candidate.fill(),
                               cfg.fill_tolerance) {
        return false;
    }
    if cfg.stroke_color
        && !stroke_color_matches(seed.stroke(), candidate.stroke(),
                                 cfg.stroke_tolerance) {
        return false;
    }
    if cfg.stroke_weight
        && !stroke_weight_matches(seed.stroke(), candidate.stroke(),
                                  cfg.stroke_weight_tolerance) {
        return false;
    }
    if cfg.opacity
        && !opacity_matches(seed.opacity(), candidate.opacity(),
                            cfg.opacity_tolerance) {
        return false;
    }
    if cfg.blending_mode
        && !blending_mode_matches(seed.mode(), candidate.mode()) {
        return false;
    }
    true
}

/// Color similarity for a Fill: solid + solid → Euclidean distance
/// ≤ tolerance; None + None → match; gradient/pattern (not yet
/// modeled here) → never match. Spec edge case: gradient fills
/// have a `Some(Fill)` with a representative `color` field — we
/// treat any element whose `fill_gradient()` is set as "non-solid"
/// upstream by inspecting the element directly. For this helper,
/// having `Some(fill)` means "solid".
fn fill_color_matches(seed: Option<&Fill>, cand: Option<&Fill>,
                       tolerance: f64) -> bool {
    match (seed, cand) {
        (None, None) => true,
        (Some(s), Some(c)) => rgb_distance(s.color.to_rgba(),
                                           c.color.to_rgba()) <= tolerance,
        _ => false,
    }
}

/// Color similarity for a Stroke: same shape as fill_color_matches.
fn stroke_color_matches(seed: Option<&Stroke>, cand: Option<&Stroke>,
                         tolerance: f64) -> bool {
    match (seed, cand) {
        (None, None) => true,
        (Some(s), Some(c)) => rgb_distance(s.color.to_rgba(),
                                           c.color.to_rgba()) <= tolerance,
        _ => false,
    }
}

/// Stroke-weight similarity. None + None matches; otherwise both
/// sides must have a stroke and `|Δ width| ≤ tolerance`.
fn stroke_weight_matches(seed: Option<&Stroke>, cand: Option<&Stroke>,
                          tolerance: f64) -> bool {
    match (seed, cand) {
        (None, None) => true,
        (Some(s), Some(c)) => (s.width - c.width).abs() <= tolerance,
        _ => false,
    }
}

/// Opacity similarity. Internal opacity is `[0.0, 1.0]`; tolerance
/// is in percentage points, so `|Δ| × 100 ≤ tolerance`.
fn opacity_matches(seed: f64, cand: f64, tolerance: f64) -> bool {
    ((seed - cand).abs() * 100.0) <= tolerance
}

/// Blending-mode similarity. Exact enum equality.
fn blending_mode_matches(seed: BlendMode, cand: BlendMode) -> bool {
    seed == cand
}

/// Euclidean RGB distance on the 0–255 scale. Inputs are
/// `Color::to_rgba()` outputs (R, G, B, A) in `[0.0, 1.0]`; we
/// scale R, G, B to `[0, 255]` and ignore alpha (Fill / Stroke
/// carry their own `opacity` field).
fn rgb_distance(a: (f64, f64, f64, f64), b: (f64, f64, f64, f64)) -> f64 {
    let dr = (a.0 - b.0) * 255.0;
    let dg = (a.1 - b.1) * 255.0;
    let db = (a.2 - b.2) * 255.0;
    (dr * dr + dg * dg + db * db).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{Color, CommonProps, RectElem};
    use crate::geometry::element::Visibility;

    fn make_rect(fill: Option<Fill>, stroke: Option<Stroke>,
                 opacity: f64, mode: BlendMode) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill, stroke,
            common: CommonProps {
                opacity, mode,
                transform: None, locked: false,
                visibility: Visibility::Preview, mask: None,
                tool_origin: None,
            name: None,
            },
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    #[test]
    fn all_disabled_never_matches() {
        let cfg = MagicWandConfig {
            fill_color: false, stroke_color: false,
            stroke_weight: false, opacity: false,
            blending_mode: false,
            ..MagicWandConfig::default()
        };
        let seed = make_rect(Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
                              None, 1.0, BlendMode::Normal);
        let cand = seed.clone();
        assert!(!magic_wand_match(&seed, &cand, &cfg));
    }

    #[test]
    fn identical_elements_match_under_default_config() {
        let cfg = MagicWandConfig::default();
        let seed = make_rect(
            Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            Some(Stroke::new(Color::rgb(0.0, 0.0, 0.0), 2.0)),
            1.0, BlendMode::Normal);
        let cand = seed.clone();
        assert!(magic_wand_match(&seed, &cand, &cfg));
    }

    #[test]
    fn fill_color_within_tolerance_matches() {
        // Tolerance 32 with seed = pure red. Candidate = (240, 10,
        // 10) is √(15²+10²+10²) ≈ 21.8 — within 32.
        let cfg = MagicWandConfig {
            stroke_color: false, stroke_weight: false,
            opacity: false, blending_mode: false,
            ..MagicWandConfig::default()
        };
        let seed = make_rect(Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
                              None, 1.0, BlendMode::Normal);
        let cand = make_rect(
            Some(Fill::new(Color::rgb(240.0/255.0, 10.0/255.0, 10.0/255.0))),
            None, 1.0, BlendMode::Normal);
        assert!(magic_wand_match(&seed, &cand, &cfg));
    }

    #[test]
    fn fill_color_outside_tolerance_misses() {
        // Tolerance 10 with seed = pure red. Candidate = (200, 0,
        // 0) is 55 — outside 10.
        let cfg = MagicWandConfig {
            stroke_color: false, stroke_weight: false,
            opacity: false, blending_mode: false,
            fill_tolerance: 10.0,
            ..MagicWandConfig::default()
        };
        let seed = make_rect(Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
                              None, 1.0, BlendMode::Normal);
        let cand = make_rect(
            Some(Fill::new(Color::rgb(200.0/255.0, 0.0, 0.0))),
            None, 1.0, BlendMode::Normal);
        assert!(!magic_wand_match(&seed, &cand, &cfg));
    }

    #[test]
    fn none_fill_matches_only_none_fill() {
        // Only fill_color enabled. Both sides None → match. Mixed
        // None / Some → no match.
        let cfg = MagicWandConfig {
            stroke_color: false, stroke_weight: false,
            opacity: false, blending_mode: false,
            ..MagicWandConfig::default()
        };
        let none_fill = make_rect(None, None, 1.0, BlendMode::Normal);
        let red = make_rect(Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
                            None, 1.0, BlendMode::Normal);
        assert!(magic_wand_match(&none_fill, &none_fill.clone(), &cfg));
        assert!(!magic_wand_match(&none_fill, &red, &cfg));
        assert!(!magic_wand_match(&red, &none_fill, &cfg));
    }

    #[test]
    fn stroke_weight_uses_pt_delta() {
        // Only stroke_weight enabled, tolerance = 1 pt.
        let cfg = MagicWandConfig {
            fill_color: false, stroke_color: false,
            opacity: false, blending_mode: false,
            stroke_weight_tolerance: 1.0,
            ..MagicWandConfig::default()
        };
        let s2 = make_rect(None, Some(Stroke::new(Color::BLACK, 2.0)),
                           1.0, BlendMode::Normal);
        let s2_5 = make_rect(None, Some(Stroke::new(Color::BLACK, 2.5)),
                              1.0, BlendMode::Normal);
        let s4 = make_rect(None, Some(Stroke::new(Color::BLACK, 4.0)),
                           1.0, BlendMode::Normal);
        assert!(magic_wand_match(&s2, &s2_5, &cfg));   // Δ 0.5 ≤ 1
        assert!(!magic_wand_match(&s2, &s4, &cfg));   // Δ 2.0 > 1
    }

    #[test]
    fn opacity_uses_percentage_point_delta() {
        // Tolerance 5%. Internal opacity is [0, 1] so the helper
        // multiplies by 100 before comparing.
        let cfg = MagicWandConfig {
            fill_color: false, stroke_color: false,
            stroke_weight: false, blending_mode: false,
            opacity_tolerance: 5.0,
            ..MagicWandConfig::default()
        };
        let a = make_rect(None, None, 1.0, BlendMode::Normal);
        let b = make_rect(None, None, 0.97, BlendMode::Normal);
        let c = make_rect(None, None, 0.80, BlendMode::Normal);
        assert!(magic_wand_match(&a, &b, &cfg));   // |Δ|·100 = 3 ≤ 5
        assert!(!magic_wand_match(&a, &c, &cfg));  // |Δ|·100 = 20 > 5
    }

    #[test]
    fn blending_mode_is_exact_match() {
        let cfg = MagicWandConfig {
            fill_color: false, stroke_color: false,
            stroke_weight: false, opacity: false,
            blending_mode: true,
            ..MagicWandConfig::default()
        };
        let normal = make_rect(None, None, 1.0, BlendMode::Normal);
        let normal2 = make_rect(None, None, 1.0, BlendMode::Normal);
        let multiply = make_rect(None, None, 1.0, BlendMode::Multiply);
        assert!(magic_wand_match(&normal, &normal2, &cfg));
        assert!(!magic_wand_match(&normal, &multiply, &cfg));
    }

    #[test]
    fn and_across_criteria_one_failure_misses() {
        // Fill matches but stroke weight doesn't → AND fails.
        let cfg = MagicWandConfig {
            opacity: false, blending_mode: false,
            stroke_weight_tolerance: 1.0,
            ..MagicWandConfig::default()
        };
        let seed = make_rect(
            Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            Some(Stroke::new(Color::BLACK, 2.0)),
            1.0, BlendMode::Normal);
        let cand = make_rect(
            Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),  // same fill
            Some(Stroke::new(Color::BLACK, 5.0)),        // wider stroke
            1.0, BlendMode::Normal);
        assert!(!magic_wand_match(&seed, &cand, &cfg));
    }
}
