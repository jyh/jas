//! Align and distribute operations — per `transcripts/ALIGN.md`.
//!
//! This module owns the geometry of the 14 Align panel buttons.
//! Each operation reads a slice of selected elements plus an
//! [`AlignReference`] (selection bbox, artboard rectangle, or
//! designated key object) and returns a list of (path, Δx, Δy)
//! translations for the caller to apply.
//!
//! The module has no side effects. Callers (renderer.rs platform-
//! effect handlers) are responsible for taking a document
//! snapshot, appending the translations to each moved element's
//! transform, and committing the transaction.
//!
//! Use-preview-bounds mode is orthogonal: the caller chooses which
//! bbox function to pass in via [`BoundsFn`]. Elements with
//! `locked == true` contribute to the reference bbox math but do
//! not receive a translation, per ALIGN.md §Enable and disable
//! rules.

use crate::document::document::ElementPath;
use crate::geometry::element::{Bounds, Element};

/// Fixed reference a single Align / Distribute / Distribute
/// Spacing operation consults. Produced from `AppState.align_panel`
/// and the current tab's document state by the renderer-side
/// `align_reference_for(...)` (not yet implemented — see Stage 2h).
#[derive(Debug, Clone, PartialEq)]
pub enum AlignReference {
    /// Bounding box of the current selection, excluding locked
    /// elements that are fixed reference points anyway.
    Selection(Bounds),
    /// Active artboard rectangle.
    Artboard(Bounds),
    /// Designated key object — its own bbox plus the path so the
    /// caller can skip the key during the move phase.
    KeyObject {
        bbox: Bounds,
        path: ElementPath,
    },
}

impl AlignReference {
    pub fn bbox(&self) -> Bounds {
        match self {
            AlignReference::Selection(b) => *b,
            AlignReference::Artboard(b) => *b,
            AlignReference::KeyObject { bbox, .. } => *bbox,
        }
    }

    /// Path of the key object if this is key-object mode, else
    /// `None`. Used to skip the key during the move loop.
    pub fn key_path(&self) -> Option<&ElementPath> {
        match self {
            AlignReference::KeyObject { path, .. } => Some(path),
            _ => None,
        }
    }
}

/// Per-element translation emitted by an Align operation. The
/// caller applies `(dx, dy)` as a pre-pended translate onto the
/// element at `path`.
#[derive(Debug, Clone, PartialEq)]
pub struct AlignTranslation {
    pub path: ElementPath,
    pub dx: f64,
    pub dy: f64,
}

/// Bounds-lookup function. Pass [`preview_bounds`] when Use
/// Preview Bounds is checked in the panel menu; otherwise pass
/// [`geometric_bounds`]. See ALIGN.md §Bounding box selection.
pub type BoundsFn = fn(&Element) -> Bounds;

/// Bounds-lookup function that returns preview (stroke-inflated)
/// bounds — the existing `Element::bounds`.
pub fn preview_bounds(e: &Element) -> Bounds {
    e.bounds()
}

/// Bounds-lookup function that returns geometric (stroke-
/// exclusive) bounds. This is the default selected by the panel
/// menu Use Preview Bounds flag being off.
pub fn geometric_bounds(e: &Element) -> Bounds {
    e.geometric_bounds()
}

/// Union the bounding boxes of a slice of elements using the given
/// bounds function. Returns `(0, 0, 0, 0)` when the slice is empty.
pub fn union_bounds(
    elements: &[&Element],
    bounds_fn: BoundsFn,
) -> Bounds {
    if elements.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for e in elements {
        let (x, y, w, h) = bounds_fn(e);
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x + w);
        max_y = max_y.max(y + h);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

/// Horizontal / vertical axis of an operation. A single operation
/// either moves elements horizontally or vertically, never both,
/// so an `Axis` flag keeps the algorithms generic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    Horizontal,
    Vertical,
}

/// Extract (min, max, center) along the given axis from a bbox.
pub fn axis_extent(bbox: Bounds, axis: Axis) -> (f64, f64, f64) {
    let (x, y, w, h) = bbox;
    match axis {
        Axis::Horizontal => (x, x + w, x + w / 2.0),
        Axis::Vertical => (y, y + h, y + h / 2.0),
    }
}

/// Position along an axis the operation wants to match. Used by
/// the 12 Align/Distribute buttons as "where on the bbox edge do I
/// read or write": left edge / center / right edge, analogously
/// top / vcenter / bottom for the vertical axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AxisAnchor {
    /// Min edge along the axis: left (horizontal) or top (vertical).
    Min,
    /// Midpoint along the axis.
    Center,
    /// Max edge along the axis: right (horizontal) or bottom (vertical).
    Max,
}

/// The anchor position of a bbox along a given axis.
pub fn anchor_position(bbox: Bounds, axis: Axis, anchor: AxisAnchor) -> f64 {
    let (lo, hi, mid) = axis_extent(bbox, axis);
    match anchor {
        AxisAnchor::Min => lo,
        AxisAnchor::Center => mid,
        AxisAnchor::Max => hi,
    }
}

/// Generic alignment driver used by the six public Align
/// operations. For each selected element whose bbox anchor differs
/// from the reference bbox anchor along the given axis, emit a
/// translation that moves it onto the target.
///
/// Elements whose path matches [`AlignReference::key_path`] are
/// skipped — the key object never moves, per ALIGN.md §Align To
/// target.
///
/// Zero-delta translations are omitted per the identity-value
/// rule in ALIGN.md §SVG attribute mapping.
pub fn align_along_axis(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    axis: Axis,
    anchor: AxisAnchor,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    let target = anchor_position(reference.bbox(), axis, anchor);
    let key_path = reference.key_path();
    let mut out = Vec::new();
    for (path, elem) in elements.iter() {
        if Some(path) == key_path {
            continue;
        }
        let elem_pos = anchor_position(bounds_fn(elem), axis, anchor);
        let delta = target - elem_pos;
        if delta == 0.0 {
            continue;
        }
        let (dx, dy) = match axis {
            Axis::Horizontal => (delta, 0.0),
            Axis::Vertical => (0.0, delta),
        };
        out.push(AlignTranslation { path: path.clone(), dx, dy });
    }
    out
}

/// ALIGN_LEFT_BUTTON. Move every non-key element so its left edge
/// coincides with the reference's left edge.
pub fn align_left(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Horizontal, AxisAnchor::Min, bounds_fn)
}

/// ALIGN_HORIZONTAL_CENTER_BUTTON. Move every non-key element so
/// its horizontal center coincides with the reference's.
pub fn align_horizontal_center(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Horizontal, AxisAnchor::Center, bounds_fn)
}

/// ALIGN_RIGHT_BUTTON. Move every non-key element so its right
/// edge coincides with the reference's right edge.
pub fn align_right(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Horizontal, AxisAnchor::Max, bounds_fn)
}

/// ALIGN_TOP_BUTTON. Move every non-key element so its top edge
/// coincides with the reference's top edge.
pub fn align_top(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Vertical, AxisAnchor::Min, bounds_fn)
}

/// ALIGN_VERTICAL_CENTER_BUTTON. Move every non-key element so
/// its vertical center coincides with the reference's.
pub fn align_vertical_center(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Vertical, AxisAnchor::Center, bounds_fn)
}

/// ALIGN_BOTTOM_BUTTON. Move every non-key element so its bottom
/// edge coincides with the reference's bottom edge.
pub fn align_bottom(
    elements: &[(ElementPath, &Element)],
    reference: &AlignReference,
    bounds_fn: BoundsFn,
) -> Vec<AlignTranslation> {
    align_along_axis(elements, reference, Axis::Vertical, AxisAnchor::Max, bounds_fn)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::{CircleElem, CommonProps, Color, Fill, RectElem};
    use std::rc::Rc;

    fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        })
    }

    fn circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        })
    }

    #[test]
    fn union_bounds_empty_returns_zero() {
        let b = union_bounds(&[], geometric_bounds);
        assert_eq!(b, (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn union_bounds_single_element() {
        let r = rect(10.0, 20.0, 30.0, 40.0);
        let b = union_bounds(&[&r], geometric_bounds);
        assert_eq!(b, (10.0, 20.0, 30.0, 40.0));
    }

    #[test]
    fn union_bounds_three_elements_spans_all() {
        let r1 = rect(0.0, 0.0, 10.0, 10.0);
        let r2 = rect(20.0, 5.0, 10.0, 10.0);
        let c = circle(50.0, 50.0, 10.0);
        let b = union_bounds(&[&r1, &r2, &c], geometric_bounds);
        assert_eq!(b, (0.0, 0.0, 60.0, 60.0));
    }

    #[test]
    fn axis_extent_horizontal() {
        let (lo, hi, mid) = axis_extent((10.0, 20.0, 40.0, 60.0), Axis::Horizontal);
        assert_eq!(lo, 10.0);
        assert_eq!(hi, 50.0);
        assert_eq!(mid, 30.0);
    }

    #[test]
    fn axis_extent_vertical() {
        let (lo, hi, mid) = axis_extent((10.0, 20.0, 40.0, 60.0), Axis::Vertical);
        assert_eq!(lo, 20.0);
        assert_eq!(hi, 80.0);
        assert_eq!(mid, 50.0);
    }

    #[test]
    fn anchor_position_min_center_max() {
        let bbox = (10.0, 20.0, 40.0, 60.0);
        assert_eq!(anchor_position(bbox, Axis::Horizontal, AxisAnchor::Min), 10.0);
        assert_eq!(anchor_position(bbox, Axis::Horizontal, AxisAnchor::Center), 30.0);
        assert_eq!(anchor_position(bbox, Axis::Horizontal, AxisAnchor::Max), 50.0);
        assert_eq!(anchor_position(bbox, Axis::Vertical, AxisAnchor::Min), 20.0);
        assert_eq!(anchor_position(bbox, Axis::Vertical, AxisAnchor::Center), 50.0);
        assert_eq!(anchor_position(bbox, Axis::Vertical, AxisAnchor::Max), 80.0);
    }

    #[test]
    fn align_reference_bbox_unpacks_each_variant() {
        let b = (1.0, 2.0, 3.0, 4.0);
        assert_eq!(AlignReference::Selection(b).bbox(), b);
        assert_eq!(AlignReference::Artboard(b).bbox(), b);
        assert_eq!(
            AlignReference::KeyObject { bbox: b, path: vec![0] }.bbox(),
            b,
        );
    }

    #[test]
    fn align_reference_key_path_only_for_key_object() {
        let b = (0.0, 0.0, 10.0, 10.0);
        assert!(AlignReference::Selection(b).key_path().is_none());
        assert!(AlignReference::Artboard(b).key_path().is_none());
        let r = AlignReference::KeyObject { bbox: b, path: vec![0, 2] };
        assert_eq!(r.key_path(), Some(&vec![0, 2]));
    }

    #[test]
    fn preview_bounds_matches_element_bounds() {
        let r = rect(10.0, 20.0, 30.0, 40.0);
        assert_eq!(preview_bounds(&r), r.bounds());
    }

    #[test]
    fn geometric_bounds_matches_element_geometric_bounds() {
        let r = rect(10.0, 20.0, 30.0, 40.0);
        assert_eq!(geometric_bounds(&r), r.geometric_bounds());
    }

    // Guard against Rc references being necessary — silence unused
    // Rc import warning by touching it here.
    #[test]
    fn rc_is_usable() {
        let _rc: Rc<Element> = Rc::new(rect(0.0, 0.0, 1.0, 1.0));
    }

    // ── align operations ─────────────────────────────────────

    fn selection_ref(bbox: Bounds) -> AlignReference {
        AlignReference::Selection(bbox)
    }

    /// Convenience: three rects at x=10, 30, 60 with width 10 each,
    /// forming a selection bbox of (10, 0, 60, 10).
    fn three_rects() -> [Element; 3] {
        [
            rect(10.0, 0.0, 10.0, 10.0),
            rect(30.0, 0.0, 10.0, 10.0),
            rect(60.0, 0.0, 10.0, 10.0),
        ]
    }

    fn ref_selection_of(elems: &[Element]) -> AlignReference {
        let refs: Vec<&Element> = elems.iter().collect();
        selection_ref(union_bounds(&refs, geometric_bounds))
    }

    fn pair(path: Vec<usize>, e: &Element) -> (ElementPath, &Element) {
        (path, e)
    }

    #[test]
    fn align_left_moves_two_rects_to_left_edge() {
        let rs = three_rects();
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
            pair(vec![2], &rs[2]),
        ];
        let out = align_left(&input, &r, geometric_bounds);
        // First rect already at x=10 (the selection left); omitted.
        // Second moves from 30 to 10 (Δ -20); third from 60 to 10 (Δ -50).
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], AlignTranslation { path: vec![1], dx: -20.0, dy: 0.0 });
        assert_eq!(out[1], AlignTranslation { path: vec![2], dx: -50.0, dy: 0.0 });
    }

    #[test]
    fn align_right_moves_to_right_edge() {
        let rs = three_rects();
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
            pair(vec![2], &rs[2]),
        ];
        let out = align_right(&input, &r, geometric_bounds);
        // Right edge target = 70. Rect[0] at 20 → Δ +50.
        // Rect[1] at 40 → Δ +30. Rect[2] already at 70 → omitted.
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].dx, 50.0);
        assert_eq!(out[1].dx, 30.0);
    }

    #[test]
    fn align_horizontal_center_moves_to_midpoint() {
        let rs = three_rects();
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
            pair(vec![2], &rs[2]),
        ];
        let out = align_horizontal_center(&input, &r, geometric_bounds);
        // Center target = 40. Rect[0] center 15 → Δ +25.
        // Rect[1] center 35 → Δ +5. Rect[2] center 65 → Δ -25.
        assert_eq!(out.len(), 3);
        assert_eq!(out[0].dx, 25.0);
        assert_eq!(out[1].dx, 5.0);
        assert_eq!(out[2].dx, -25.0);
    }

    #[test]
    fn align_top_only_affects_y() {
        let rs = [
            rect(0.0, 10.0, 10.0, 10.0),
            rect(20.0, 30.0, 10.0, 10.0),
            rect(40.0, 50.0, 10.0, 10.0),
        ];
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
            pair(vec![2], &rs[2]),
        ];
        let out = align_top(&input, &r, geometric_bounds);
        for t in &out {
            assert_eq!(t.dx, 0.0);
        }
        assert_eq!(out.len(), 2); // first already at top
    }

    #[test]
    fn align_vertical_center_moves_to_midline() {
        let rs = [
            rect(0.0, 0.0, 10.0, 10.0),
            rect(20.0, 20.0, 10.0, 10.0),
        ];
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
        ];
        let out = align_vertical_center(&input, &r, geometric_bounds);
        // Vertical center target = 15. Rect[0] cy 5 → Δ +10.
        // Rect[1] cy 25 → Δ -10.
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].dy, 10.0);
        assert_eq!(out[1].dy, -10.0);
    }

    #[test]
    fn align_bottom_moves_to_bottom_edge() {
        let rs = [
            rect(0.0, 0.0, 10.0, 20.0),
            rect(20.0, 0.0, 10.0, 10.0),
        ];
        let r = ref_selection_of(&rs);
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
        ];
        let out = align_bottom(&input, &r, geometric_bounds);
        // Bottom edge target = 20. Rect[0] bottom 20 → omitted.
        // Rect[1] bottom 10 → Δ +10.
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].path, vec![1]);
        assert_eq!(out[0].dy, 10.0);
    }

    #[test]
    fn align_left_with_key_object_does_not_move_key() {
        let rs = three_rects();
        let key_path = vec![1];
        let r = AlignReference::KeyObject {
            bbox: rs[1].geometric_bounds(),
            path: key_path.clone(),
        };
        let input = vec![
            pair(vec![0], &rs[0]),
            pair(vec![1], &rs[1]),
            pair(vec![2], &rs[2]),
        ];
        let out = align_left(&input, &r, geometric_bounds);
        // The key (path=[1]) never appears in the output. Others
        // align to the key's left edge (x=30).
        for t in &out {
            assert_ne!(t.path, key_path);
        }
        // Rect[0] moves 10 → 30 = Δ +20; Rect[2] moves 60 → 30 = Δ -30.
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], AlignTranslation { path: vec![0], dx: 20.0, dy: 0.0 });
        assert_eq!(out[1], AlignTranslation { path: vec![2], dx: -30.0, dy: 0.0 });
    }

    #[test]
    fn align_left_empty_input_yields_empty_output() {
        let r = selection_ref((0.0, 0.0, 10.0, 10.0));
        let out = align_left(&[], &r, geometric_bounds);
        assert!(out.is_empty());
    }
}
