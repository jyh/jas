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

use super::element::{Bounds, CommonProps, Element, Fill, Stroke};

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
/// its operand tree; evaluates to a cached shape when rendered.
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

impl LiveElement for CompoundShape {
    fn kind(&self) -> &'static str { "compound_shape" }
    fn kind_schema_version(&self) -> u32 { 1 }
    fn common(&self) -> &CommonProps { &self.common }
    fn common_mut(&mut self) -> &mut CommonProps { &mut self.common }
    fn fill(&self) -> Option<&Fill> { self.fill.as_ref() }
    fn stroke(&self) -> Option<&Stroke> { self.stroke.as_ref() }
    fn children(&self) -> &[Rc<Element>] { &self.operands }
    fn children_mut(&mut self) -> &mut Vec<Rc<Element>> { &mut self.operands }

    /// Phase 1 stub. Phase 2 returns the bounds of the evaluated
    /// polygon set after running the boolean algorithm over operands.
    fn bounds(&self) -> Bounds { (0.0, 0.0, 0.0, 0.0) }
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_compound(op: CompoundOperation) -> CompoundShape {
        CompoundShape {
            operation: op,
            operands: vec![],
            fill: None,
            stroke: None,
            common: CommonProps::default(),
        }
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
        // Per BOOLEAN.md § Live element framework, LiveVariant is
        // internally tagged by `kind` so future variants (drop shadow,
        // blend) share the same outer shape.
        assert!(json.contains("\"kind\":\"compound_shape\""),
                "expected kind tag in {json}");
        assert!(json.contains("\"operation\":\"union\""),
                "expected snake_case operation in {json}");
    }
}
