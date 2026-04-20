//! LiveElement framework: shared infrastructure for non-destructive
//! element kinds that store source inputs and evaluate them on demand.
//!
//! CompoundShape is the first conformer (non-destructive boolean over
//! an operand tree). Future Live Effects (drop shadow, blend, ...) add
//! a variant to `LiveVariant` and implement `LiveElement`; the top-
//! level `Element` enum only ever grows one `Live(LiveVariant)` arm.
//!
//! See `transcripts/BOOLEAN.md` § Live element framework.

#![allow(dead_code)]

use std::rc::Rc;

use crate::algorithms::boolean::{
    self, PolygonSet,
};

use super::element::{Bounds, CommonProps, Element, Fill, Stroke};

/// Default geometric tolerance in points. Matches the `Precision`
/// default in the Boolean Options dialog (BOOLEAN.md § Boolean
/// Options dialog). Equals 0.01 mm.
pub(crate) const DEFAULT_PRECISION: f64 = 0.0283;

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Shared behavior of every LiveKind's inner struct. Implemented by
/// each concrete kind (e.g. `CompoundShape`) and also by `LiveVariant`
/// via delegation, so consumers holding a `LiveVariant` can invoke
/// these methods without an inner match.
pub trait LiveElement {
    /// Stable tag used in serialized form and in UI code to identify
    /// the live kind (e.g. `"compound_shape"`).
    fn kind(&self) -> &'static str;

    /// Version of the params schema for this kind. Incremented when a
    /// kind's serialized shape changes in a backwards-incompatible way.
    fn kind_schema_version(&self) -> u32;

    fn common(&self) -> &CommonProps;
    fn common_mut(&mut self) -> &mut CommonProps;
    fn fill(&self) -> Option<&Fill>;
    fn stroke(&self) -> Option<&Stroke>;

    /// Element-valued inputs. Per-feature conventions dictate the
    /// index ordering (compound shape: operands in z-order; blend:
    /// `[a, b, spine?]`; drop shadow: `[source]`).
    fn children(&self) -> &[Rc<Element>];
    fn children_mut(&mut self) -> &mut Vec<Rc<Element>>;

    /// Stroke-inclusive bounding box of the evaluated output.
    fn bounds(&self) -> Bounds;

    /// Mark the kind's internal cache dirty. Default: no-op. Kinds
    /// that introduce a cache override this.
    fn invalidate(&mut self) {}
}

// ---------------------------------------------------------------------------
// CompoundShape — first LiveKind
// ---------------------------------------------------------------------------

/// Which boolean operation a compound shape evaluates to. Only the
/// four Shape Mode operations can be compound; the destructive-only
/// pathfinder operations never produce compound shapes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompoundOperation {
    Union,
    SubtractFront,
    Intersection,
    Exclude,
}

/// A live, non-destructive boolean element: stores the operation and
/// its operand tree; evaluates to a polygon set on demand.
///
/// See `transcripts/BOOLEAN.md` § Compound shape data model.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CompoundShape {
    pub operation: CompoundOperation,
    pub operands: Vec<Rc<Element>>,
    pub fill: Option<Fill>,
    pub stroke: Option<Stroke>,
    pub common: CommonProps,
}

impl CompoundShape {
    /// Evaluate the compound shape: flatten every operand into a
    /// polygon set, then apply the boolean operation across them.
    ///
    /// Pure function — no cache today. A cache lives in a future
    /// phase once render performance demands it.
    pub fn evaluate(&self, precision: f64) -> PolygonSet {
        let operands: Vec<PolygonSet> = self.operands.iter()
            .map(|e| element_to_polygon_set(e, precision))
            .collect();
        apply_operation(self.operation, &operands)
    }
}

impl LiveElement for CompoundShape {
    fn kind(&self) -> &'static str { "compound_shape" }
    fn kind_schema_version(&self) -> u32 { 1 }
    fn common(&self) -> &CommonProps { &self.common }
    fn common_mut(&mut self) -> &mut CommonProps { &mut self.common }
    fn fill(&self) -> Option<&Fill> { self.fill.as_ref() }
    fn stroke(&self) -> Option<&Stroke> { self.stroke.as_ref() }
    fn children(&self) -> &[Rc<Element>] { &self.operands }
    fn children_mut(&mut self) -> &mut Vec<Rc<Element>> { &mut self.operands }

    fn bounds(&self) -> Bounds {
        bounds_of_polygon_set(&self.evaluate(DEFAULT_PRECISION))
    }
}

// ---------------------------------------------------------------------------
// LiveVariant — closed-world enum over the known LiveKinds
// ---------------------------------------------------------------------------

/// Closed-world enum over all known LiveKinds. Adding a new kind adds
/// one variant here and one match arm in each trait method; the top-
/// level `Element` enum only ever has one `Live(LiveVariant)` variant.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LiveVariant {
    CompoundShape(CompoundShape),
}

impl LiveElement for LiveVariant {
    fn kind(&self) -> &'static str {
        match self { LiveVariant::CompoundShape(cs) => cs.kind() }
    }
    fn kind_schema_version(&self) -> u32 {
        match self { LiveVariant::CompoundShape(cs) => cs.kind_schema_version() }
    }
    fn common(&self) -> &CommonProps {
        match self { LiveVariant::CompoundShape(cs) => cs.common() }
    }
    fn common_mut(&mut self) -> &mut CommonProps {
        match self { LiveVariant::CompoundShape(cs) => cs.common_mut() }
    }
    fn fill(&self) -> Option<&Fill> {
        match self { LiveVariant::CompoundShape(cs) => cs.fill() }
    }
    fn stroke(&self) -> Option<&Stroke> {
        match self { LiveVariant::CompoundShape(cs) => cs.stroke() }
    }
    fn children(&self) -> &[Rc<Element>] {
        match self { LiveVariant::CompoundShape(cs) => cs.children() }
    }
    fn children_mut(&mut self) -> &mut Vec<Rc<Element>> {
        match self { LiveVariant::CompoundShape(cs) => cs.children_mut() }
    }
    fn bounds(&self) -> Bounds {
        match self { LiveVariant::CompoundShape(cs) => cs.bounds() }
    }
    fn invalidate(&mut self) {
        match self { LiveVariant::CompoundShape(cs) => cs.invalidate() }
    }
}

// ---------------------------------------------------------------------------
// Evaluation helpers — Element → PolygonSet, boolean dispatch, bounds
// ---------------------------------------------------------------------------

/// Flatten a document element into a polygon set suitable for the
/// boolean algorithm. Per BOOLEAN.md § Geometry and precision:
///
/// - Rect / Polygon / Polyline / Circle / Ellipse → direct conversion.
///   Polyline is implicitly closed.
/// - Group / Layer → recursively concatenate children's rings.
/// - Live → recursively evaluate.
/// - Path / Text / TextPath / Line → empty for now. Path flattening
///   (Bézier → polyline) lands in a follow-up phase; Text glyph
///   flattening is deferred; Line has zero area.
pub(crate) fn element_to_polygon_set(elem: &Element, precision: f64) -> PolygonSet {
    match elem {
        Element::Rect(r) => vec![vec![
            (r.x, r.y),
            (r.x + r.width, r.y),
            (r.x + r.width, r.y + r.height),
            (r.x, r.y + r.height),
        ]],
        Element::Polygon(p) => {
            if p.points.is_empty() { PolygonSet::new() } else { vec![p.points.clone()] }
        }
        Element::Polyline(p) => {
            if p.points.is_empty() { PolygonSet::new() } else { vec![p.points.clone()] }
        }
        Element::Circle(c) => vec![circle_to_ring(c.cx, c.cy, c.r, precision)],
        Element::Ellipse(e) => vec![ellipse_to_ring(e.cx, e.cy, e.rx, e.ry, precision)],
        Element::Group(g) => {
            let mut out = PolygonSet::new();
            for child in &g.children {
                out.extend(element_to_polygon_set(child, precision));
            }
            out
        }
        Element::Layer(l) => {
            let mut out = PolygonSet::new();
            for child in &l.children {
                out.extend(element_to_polygon_set(child, precision));
            }
            out
        }
        Element::Live(v) => match v {
            LiveVariant::CompoundShape(cs) => cs.evaluate(precision),
        },
        Element::Line(_) | Element::Path(_) | Element::Text(_) | Element::TextPath(_) => {
            PolygonSet::new()
        }
    }
}

/// Sample a circle at enough points that the max perpendicular
/// distance between the polyline and the true arc is ≤ `precision`.
///
/// Error per segment on a circle of radius r is ≈ r·(1 − cos(π/n)),
/// which for large n is ≈ r·(π/n)²/2. Solving for n:
///
///     n ≥ π · √(r / (2 · precision))
fn circle_to_ring(cx: f64, cy: f64, r: f64, precision: f64) -> Vec<(f64, f64)> {
    let n = segments_for_arc(r, precision);
    (0..n)
        .map(|i| {
            let theta = (i as f64) / (n as f64) * std::f64::consts::TAU;
            (cx + r * theta.cos(), cy + r * theta.sin())
        })
        .collect()
}

/// Same formula as `circle_to_ring`, using the larger radius to pick
/// the segment count conservatively.
fn ellipse_to_ring(cx: f64, cy: f64, rx: f64, ry: f64, precision: f64) -> Vec<(f64, f64)> {
    let n = segments_for_arc(rx.max(ry), precision);
    (0..n)
        .map(|i| {
            let theta = (i as f64) / (n as f64) * std::f64::consts::TAU;
            (cx + rx * theta.cos(), cy + ry * theta.sin())
        })
        .collect()
}

fn segments_for_arc(radius: f64, precision: f64) -> usize {
    if radius <= 0.0 || precision <= 0.0 {
        return 32;
    }
    let approx = std::f64::consts::PI * (radius / (2.0 * precision)).sqrt();
    approx.ceil().max(8.0) as usize
}

/// Dispatch a boolean operation across an arbitrary number of operands.
/// Binary ops are folded left-to-right; SubtractFront consumes the
/// last operand as the cutter and unions the remaining survivors
/// after each one has the cutter removed, matching the semantics in
/// BOOLEAN.md § Operand and paint rules.
pub(crate) fn apply_operation(op: CompoundOperation, operands: &[PolygonSet]) -> PolygonSet {
    if operands.is_empty() {
        return PolygonSet::new();
    }
    match op {
        CompoundOperation::Union => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_union(&acc, b))
        }
        CompoundOperation::Intersection => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_intersect(&acc, b))
        }
        CompoundOperation::SubtractFront => {
            if operands.len() < 2 {
                return operands[0].clone();
            }
            let (survivors, cutter_slice) = operands.split_at(operands.len() - 1);
            let cutter = &cutter_slice[0];
            survivors
                .iter()
                .map(|s| boolean::boolean_subtract(s, cutter))
                .fold(PolygonSet::new(), |acc, s| boolean::boolean_union(&acc, &s))
        }
        CompoundOperation::Exclude => {
            operands[1..]
                .iter()
                .fold(operands[0].clone(), |acc, b| boolean::boolean_exclude(&acc, b))
        }
    }
}

/// Tight bounding box of a polygon set. Returns `(0, 0, 0, 0)` for
/// empty input.
fn bounds_of_polygon_set(ps: &PolygonSet) -> Bounds {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for ring in ps {
        for &(x, y) in ring {
            if x < min_x { min_x = x; }
            if y < min_y { min_y = y; }
            if x > max_x { max_x = x; }
            if y > max_y { max_y = y; }
        }
    }
    if !min_x.is_finite() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::RectElem;

    fn empty_compound(op: CompoundOperation) -> CompoundShape {
        CompoundShape {
            operation: op,
            operands: vec![],
            fill: None,
            stroke: None,
            common: CommonProps::default(),
        }
    }

    fn rc_rect(x: f64, y: f64, w: f64, h: f64) -> Rc<Element> {
        Rc::new(Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
        }))
    }

    fn bbox_of_ring(ring: &[(f64, f64)]) -> (f64, f64, f64, f64) {
        let min_x = ring.iter().map(|(x, _)| *x).fold(f64::INFINITY, f64::min);
        let max_x = ring.iter().map(|(x, _)| *x).fold(f64::NEG_INFINITY, f64::max);
        let min_y = ring.iter().map(|(_, y)| *y).fold(f64::INFINITY, f64::min);
        let max_y = ring.iter().map(|(_, y)| *y).fold(f64::NEG_INFINITY, f64::max);
        (min_x, min_y, max_x, max_y)
    }

    #[test]
    fn compound_shape_kind_and_version() {
        let cs = empty_compound(CompoundOperation::Union);
        assert_eq!(cs.kind(), "compound_shape");
        assert_eq!(cs.kind_schema_version(), 1);
    }

    #[test]
    fn live_variant_delegates_to_inner() {
        let lv = LiveVariant::CompoundShape(empty_compound(CompoundOperation::Intersection));
        assert_eq!(lv.kind(), "compound_shape");
        assert_eq!(lv.children().len(), 0);
        // Empty compound → empty bounds.
        assert_eq!(lv.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn serde_roundtrip_via_element() {
        let cs = empty_compound(CompoundOperation::SubtractFront);
        let element = Element::Live(LiveVariant::CompoundShape(cs));
        let json = serde_json::to_string(&element).expect("serialize");
        let back: Element = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(element, back);
    }

    #[test]
    fn live_variant_is_kind_tagged() {
        let lv = LiveVariant::CompoundShape(empty_compound(CompoundOperation::Union));
        let json = serde_json::to_string(&lv).expect("serialize");
        assert!(json.contains("\"kind\":\"compound_shape\""),
                "expected kind tag in {json}");
        assert!(json.contains("\"operation\":\"union\""),
                "expected snake_case operation in {json}");
    }

    #[test]
    fn evaluate_union_of_two_overlapping_rects() {
        // r1 = [0..10]×[0..10], r2 = [5..15]×[0..10]. Union spans
        // x∈[0,15], y∈[0,10], as a single ring.
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1, "union of overlapping rects = 1 ring");
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 0.0).abs() < 1e-6, "min_x = {min_x}");
        assert!((max_x - 15.0).abs() < 1e-6, "max_x = {max_x}");
        assert!((min_y - 0.0).abs() < 1e-6, "min_y = {min_y}");
        assert!((max_y - 10.0).abs() < 1e-6, "max_y = {max_y}");
    }

    #[test]
    fn evaluate_intersection_of_two_overlapping_rects() {
        let cs = CompoundShape {
            operation: CompoundOperation::Intersection,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1);
        let (min_x, min_y, max_x, max_y) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 5.0).abs() < 1e-6, "min_x = {min_x}");
        assert!((max_x - 10.0).abs() < 1e-6, "max_x = {max_x}");
        assert!((min_y - 0.0).abs() < 1e-6, "min_y = {min_y}");
        assert!((max_y - 10.0).abs() < 1e-6, "max_y = {max_y}");
    }

    #[test]
    fn evaluate_subtract_front_removes_frontmost_operand() {
        // Front (last) = cutter at [5..15]×[0..10]. Survivor at
        // [0..10]×[0..10]. Subtraction leaves x∈[0,5], y∈[0,10].
        let cs = CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        assert_eq!(polygons.len(), 1);
        let (min_x, _, max_x, _) = bbox_of_ring(&polygons[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((max_x - 5.0).abs() < 1e-6, "max_x = {max_x}");
    }

    #[test]
    fn evaluate_exclude_is_symmetric_difference() {
        // XOR of two overlapping rects → two disjoint rings.
        let cs = CompoundShape {
            operation: CompoundOperation::Exclude,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let polygons = cs.evaluate(DEFAULT_PRECISION);
        // Two non-overlapping strips.
        assert_eq!(polygons.len(), 2, "xor of partially overlapping rects = 2 rings");
    }

    #[test]
    fn bounds_reflects_evaluated_geometry() {
        let cs = CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let (bx, by, bw, bh) = cs.bounds();
        assert!((bx - 0.0).abs() < 1e-6);
        assert!((by - 0.0).abs() < 1e-6);
        assert!((bw - 15.0).abs() < 1e-6);
        assert!((bh - 10.0).abs() < 1e-6);
    }

    #[test]
    fn empty_compound_has_empty_bounds() {
        let cs = empty_compound(CompoundOperation::Union);
        assert_eq!(cs.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn element_to_polygon_set_rect() {
        let rect = Element::Rect(RectElem {
            x: 1.0, y: 2.0, width: 3.0, height: 4.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
        });
        let ps = element_to_polygon_set(&rect, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0], vec![(1.0, 2.0), (4.0, 2.0), (4.0, 6.0), (1.0, 6.0)]);
    }

    #[test]
    fn element_to_polygon_set_recurses_into_live() {
        let inner = Rc::new(Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![rc_rect(0.0, 0.0, 10.0, 10.0), rc_rect(5.0, 0.0, 10.0, 10.0)],
            fill: None, stroke: None, common: CommonProps::default(),
        })));
        let ps = element_to_polygon_set(&inner, DEFAULT_PRECISION);
        assert_eq!(ps.len(), 1, "nested compound shape evaluates to one ring");
        let (min_x, _, max_x, _) = bbox_of_ring(&ps[0]);
        assert!((min_x - 0.0).abs() < 1e-6);
        assert!((max_x - 15.0).abs() < 1e-6);
    }
}
