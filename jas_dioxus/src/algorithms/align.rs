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
}
