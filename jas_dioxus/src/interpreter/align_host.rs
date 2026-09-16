//! The Align panel's platform effects, hosted without a web dependency.
//!
//! The fourteen Align panel buttons dispatch actions whose own effect keys
//! (`align_left` … `distribute_horizontal_spacing`) no arm of the effects
//! runner handles. The web renderer runs them against its `AppState`; the
//! native engine has none. This module is the ONE implementation both call:
//! `AppState::apply_align_operation` hands it the state the web app holds, and
//! an engine builds the same [`AlignInput`] from the align panel's own state
//! with [`AlignInput::from_panel_state`], by the keys `align.yaml` declares.
//!
//! The geometry is `crate::algorithms::align`'s. This module picks the
//! reference, runs the operation, and writes the translations into the model
//! as one edit.

use crate::algorithms::align as aa;
use crate::document::document::ElementPath;
use crate::document::model::Model;
use crate::geometry::element::{Bounds, Element};
use super::state_store::StateStore;

/// Align-To target mode. See ALIGN.md §Align To target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlignTo {
    Selection,
    Artboard,
    KeyObject,
}

impl AlignTo {
    pub fn as_str(self) -> &'static str {
        match self {
            AlignTo::Selection => "selection",
            AlignTo::Artboard => "artboard",
            AlignTo::KeyObject => "key_object",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "selection" => Some(AlignTo::Selection),
            "artboard" => Some(AlignTo::Artboard),
            "key_object" => Some(AlignTo::KeyObject),
            _ => None,
        }
    }
}

/// Everything an align operation reads besides the document.
#[derive(Debug, Clone, PartialEq)]
pub struct AlignInput {
    pub align_to: AlignTo,
    /// The designated key object, in key-object mode.
    pub key_object_path: Option<ElementPath>,
    /// Distribute Spacing's explicit gap, used only in key-object mode.
    pub distribute_spacing: f64,
    /// Measure with preview (stroke-inclusive) bounds.
    pub use_preview_bounds: bool,
    /// The Artboards panel's selection, by artboard id. Artboard mode aligns
    /// to the topmost selected artboard, else the first.
    pub artboard_selection: Vec<String>,
}

impl AlignInput {
    /// The align panel's state keys, as `align.yaml` declares them. The web
    /// panel state names the gap `distribute_spacing`, and the global mirror
    /// names it `align_distribute_spacing`; the panel's own key is
    /// `distribute_spacing_value`.
    pub const PANEL_KEYS: [&'static str; 4] =
        ["align_to", "key_object_path", "distribute_spacing_value", "use_preview_bounds"];

    /// Build the input from the align panel's state in `store`. A missing or
    /// mistyped value reads as the declared default. The artboard selection
    /// belongs to another panel, so the caller supplies it.
    pub fn from_panel_state(
        store: &StateStore,
        panel_id: &str,
        artboard_selection: Vec<String>,
    ) -> Self {
        let [align_to, key_object_path, gap, preview] = Self::PANEL_KEYS;
        let get = |key| store.get_panel(panel_id, key);
        Self {
            align_to: get(align_to).as_str().and_then(AlignTo::from_str)
                .unwrap_or(AlignTo::Selection),
            key_object_path: path_value(get(key_object_path)),
            distribute_spacing: get(gap).as_f64().unwrap_or(0.0),
            use_preview_bounds: get(preview).as_bool().unwrap_or(false),
            artboard_selection,
        }
    }

    /// Distribute Spacing's explicit gap: `Some(gap)` in key-object mode with
    /// a designated key, else `None` (average mode). See ALIGN.md §Distribute
    /// Spacing.
    pub fn explicit_gap(&self) -> Option<f64> {
        if self.align_to == AlignTo::KeyObject && self.key_object_path.is_some() {
            Some(self.distribute_spacing)
        } else {
            None
        }
    }
}

/// Read an element path from a state value: `{"__path__": [..]}` (how a path
/// round-trips through the store) or a bare array. Anything else, including
/// null, is no path.
pub fn path_value(val: &serde_json::Value) -> Option<ElementPath> {
    if val.is_null() {
        return None;
    }
    let arr = if let Some(obj) = val.as_object() {
        obj.get("__path__")?.as_array()?
    } else if let Some(a) = val.as_array() {
        a
    } else {
        return None;
    };
    let path: Vec<usize> = arr
        .iter()
        .filter_map(|v| v.as_u64().map(|n| n as usize))
        .collect();
    Some(path)
}

/// What one align operation did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlignOutcome {
    /// This many elements moved, in one undoable edit.
    Moved(usize),
    /// The operation ran and nothing moved: fewer than two elements selected,
    /// no key designated in key-object mode, or everything already in place.
    /// The document and the undo stack are untouched.
    Unchanged,
    /// Not one of this host's operations. Nothing was read or changed.
    UnknownOp,
}

/// The fourteen operations, named by their effect keys.
#[derive(Debug, Clone, Copy)]
enum AlignOp {
    Left, HorizontalCenter, Right, Top, VerticalCenter, Bottom,
    DistLeft, DistHorizontalCenter, DistRight, DistTop, DistVerticalCenter, DistBottom,
    DistVerticalSpacing, DistHorizontalSpacing,
}

impl AlignOp {
    fn from_key(key: &str) -> Option<Self> {
        use AlignOp::*;
        Some(match key {
            "align_left" => Left,
            "align_horizontal_center" => HorizontalCenter,
            "align_right" => Right,
            "align_top" => Top,
            "align_vertical_center" => VerticalCenter,
            "align_bottom" => Bottom,
            "distribute_left" => DistLeft,
            "distribute_horizontal_center" => DistHorizontalCenter,
            "distribute_right" => DistRight,
            "distribute_top" => DistTop,
            "distribute_vertical_center" => DistVerticalCenter,
            "distribute_bottom" => DistBottom,
            "distribute_vertical_spacing" => DistVerticalSpacing,
            "distribute_horizontal_spacing" => DistHorizontalSpacing,
            _ => return None,
        })
    }
}

/// True when `key` is an effect this host runs.
pub fn hosts(key: &str) -> bool {
    AlignOp::from_key(key).is_some()
}

/// Run the align operation `op` over the model's current selection.
///
/// Zero-delta translations are discarded, so an idempotent click does not
/// touch the document. A move is one `edit_document`: it joins a transaction
/// the caller already opened (the action's `snapshot`), or brackets its own
/// undo step when there is none.
pub fn apply_align_operation(model: &mut Model, op: &str, input: &AlignInput) -> AlignOutcome {
    let Some(op) = AlignOp::from_key(op) else {
        return AlignOutcome::UnknownOp;
    };

    // Gather (path, &Element) pairs from the current selection.
    let doc = model.document();
    let mut elements: Vec<(ElementPath, &Element)> = Vec::new();
    for es in &doc.selection {
        if let Some(e) = doc.get_element(&es.path) {
            elements.push((es.path.clone(), e));
        }
    }
    if elements.len() < 2 {
        return AlignOutcome::Unchanged;
    }

    // Pick the LEAF measurement per Use Preview Bounds, then wrap it so the
    // three kinds whose geometry lives behind an id resolve (RESOLVEDALIGN).
    // Both modes were affected: `preview_bounds` and `geometric_bounds` are
    // each resolver-less, so an instance measured as a zero box at the
    // origin whichever way the flag was set.
    let leaf: fn(&Element) -> Bounds = if input.use_preview_bounds {
        Element::bounds
    } else {
        Element::geometric_bounds
    };
    let resolver = crate::document::id_index::IndexResolver(model.id_index());
    let bounds_fn_body = |e: &Element| aa::resolved_bounds(e, &resolver, leaf);
    let bounds_fn: aa::BoundsFn = &bounds_fn_body;

    // Build the reference.
    let reference = match input.align_to {
        AlignTo::Selection => {
            let refs: Vec<&Element> = elements.iter().map(|(_, e)| *e).collect();
            aa::AlignReference::Selection(aa::union_bounds(&refs, bounds_fn))
        }
        AlignTo::Artboard => {
            // ARTBOARDS.md §Selection semantics — current = topmost
            // panel-selected artboard, else first. The at-least-one invariant
            // guarantees artboards[0] exists; if it somehow doesn't, fall back
            // to the selection union so the op still moves elements.
            let current_ab = crate::document::artboard::current_artboard(
                &doc.artboards,
                &input.artboard_selection,
            );
            if let Some(ab) = current_ab {
                aa::AlignReference::Artboard((ab.x, ab.y, ab.width, ab.height))
            } else {
                let refs: Vec<&Element> = elements.iter().map(|(_, e)| *e).collect();
                aa::AlignReference::Artboard(aa::union_bounds(&refs, bounds_fn))
            }
        }
        AlignTo::KeyObject => {
            let Some(key_path) = input.key_object_path.clone() else {
                return AlignOutcome::Unchanged;
            };
            let Some(key_elem) = doc.get_element(&key_path) else {
                return AlignOutcome::Unchanged;
            };
            aa::AlignReference::KeyObject {
                bbox: bounds_fn(key_elem),
                path: key_path,
            }
        }
    };

    // Dispatch to the algorithm.
    let e = &elements;
    let r = &reference;
    let translations: Vec<aa::AlignTranslation> = match op {
        AlignOp::Left => aa::align_left(e, r, bounds_fn),
        AlignOp::HorizontalCenter => aa::align_horizontal_center(e, r, bounds_fn),
        AlignOp::Right => aa::align_right(e, r, bounds_fn),
        AlignOp::Top => aa::align_top(e, r, bounds_fn),
        AlignOp::VerticalCenter => aa::align_vertical_center(e, r, bounds_fn),
        AlignOp::Bottom => aa::align_bottom(e, r, bounds_fn),
        AlignOp::DistLeft => aa::distribute_left(e, r, bounds_fn),
        AlignOp::DistHorizontalCenter => aa::distribute_horizontal_center(e, r, bounds_fn),
        AlignOp::DistRight => aa::distribute_right(e, r, bounds_fn),
        AlignOp::DistTop => aa::distribute_top(e, r, bounds_fn),
        AlignOp::DistVerticalCenter => aa::distribute_vertical_center(e, r, bounds_fn),
        AlignOp::DistBottom => aa::distribute_bottom(e, r, bounds_fn),
        AlignOp::DistVerticalSpacing => {
            aa::distribute_vertical_spacing(e, r, input.explicit_gap(), bounds_fn)
        }
        AlignOp::DistHorizontalSpacing => {
            aa::distribute_horizontal_spacing(e, r, input.explicit_gap(), bounds_fn)
        }
    };

    if translations.is_empty() {
        return AlignOutcome::Unchanged;
    }

    // Translate each element by baking dx/dy into its coordinates
    // (translate_element). Stuffing the offset into common().transform
    // produces a visual move but leaves the element's own coords — and
    // therefore bounds() and hit_test — at the original position, so
    // subsequent clicks and the selection overlay disagree with the rendered
    // element. The bake keeps coords, bounds, hit-test, and overlay in
    // lockstep.
    let mut new_doc = doc.clone();
    for t in &translations {
        if let Some(elem) = new_doc.get_element_mut(&t.path) {
            *elem = crate::geometry::element::translate_element(elem, t.dx, t.dy);
        }
    }
    // Self-bracketing (OP_LOG.md Increment 1): a direct call (tests) opens
    // and commits its own undo step; in production the align YAML action's
    // `snapshot` effect already opened the txn, so this joins it.
    model.edit_document(new_doc);
    AlignOutcome::Moved(translations.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::artboard::Artboard;
    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem, Stroke,
    };

    fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// One layer holding `rects`, with `selected` (child indices) selected.
    fn model_with(rects: Vec<Element>, selected: &[usize], artboards: Vec<Artboard>) -> Model {
        let layer = Element::Layer(LayerElem {
            children: rects.into_iter().map(std::rc::Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let selection = selected.iter().map(|&i| ElementSelection::all(vec![0, i])).collect();
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection,
                                 ..Document::default() };
        if !artboards.is_empty() {
            doc.artboards = artboards;
        }
        let mut model = Model::default();
        model.set_document_for_test(doc);
        model
    }

    fn xs(model: &Model) -> Vec<f64> {
        match model.document().get_element(&vec![0]) {
            Some(Element::Layer(l)) => l.children.iter().map(|c| match &**c {
                Element::Rect(r) => r.x,
                other => panic!("expected a rect, got {other:?}"),
            }).collect(),
            _ => panic!("expected a layer at [0]"),
        }
    }

    fn ys(model: &Model) -> Vec<f64> {
        match model.document().get_element(&vec![0]) {
            Some(Element::Layer(l)) => l.children.iter().map(|c| match &**c {
                Element::Rect(r) => r.y,
                other => panic!("expected a rect, got {other:?}"),
            }).collect(),
            _ => panic!("expected a layer at [0]"),
        }
    }

    fn artboard(id: &str, x: f64, y: f64, w: f64, h: f64) -> Artboard {
        let mut a = Artboard::default_with_id(id.to_string());
        a.x = x;
        a.y = y;
        a.width = w;
        a.height = h;
        a
    }

    fn input(align_to: AlignTo) -> AlignInput {
        AlignInput {
            align_to,
            key_object_path: None,
            distribute_spacing: 0.0,
            use_preview_bounds: false,
            artboard_selection: vec![],
        }
    }

    // ── the operation ─────────────────────────────────────────────────────

    #[test]
    fn align_left_to_the_selection_moves_every_rect_to_the_leftmost_edge() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(30.0, 0.0, 10.0, 10.0),
                 rect(60.0, 0.0, 10.0, 10.0)],
            &[0, 1, 2], vec![]);
        let out = apply_align_operation(&mut m, "align_left", &input(AlignTo::Selection));
        assert_eq!(out, AlignOutcome::Moved(2), "the leftmost rect has a zero delta");
        assert_eq!(xs(&m), vec![10.0, 10.0, 10.0]);
    }

    #[test]
    fn the_move_is_one_undo_step() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(30.0, 0.0, 10.0, 10.0)],
            &[0, 1], vec![]);
        apply_align_operation(&mut m, "align_right", &input(AlignTo::Selection));
        assert_eq!(xs(&m), vec![30.0, 30.0]);
        m.undo();
        assert_eq!(xs(&m), vec![10.0, 30.0], "one undo restores the pre-click positions");
    }

    #[test]
    fn fewer_than_two_selected_is_unchanged() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(30.0, 0.0, 10.0, 10.0)],
            &[1], vec![]);
        assert_eq!(apply_align_operation(&mut m, "align_left", &input(AlignTo::Selection)),
                   AlignOutcome::Unchanged);
        assert_eq!(xs(&m), vec![10.0, 30.0]);
        assert!(!m.can_undo(), "an unchanged click leaves no undo step");
    }

    #[test]
    fn an_already_aligned_selection_is_unchanged() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(10.0, 40.0, 10.0, 10.0)],
            &[0, 1], vec![]);
        assert_eq!(apply_align_operation(&mut m, "align_left", &input(AlignTo::Selection)),
                   AlignOutcome::Unchanged);
        assert!(!m.can_undo());
    }

    #[test]
    fn an_unknown_op_is_named_as_unknown_even_where_nothing_could_move() {
        // One element selected: every KNOWN op is Unchanged here, so an
        // unknown op must be recognised before the selection is read.
        let mut m = model_with(vec![rect(10.0, 0.0, 10.0, 10.0)], &[0], vec![]);
        assert_eq!(apply_align_operation(&mut m, "not_a_real_op", &input(AlignTo::Selection)),
                   AlignOutcome::UnknownOp);
        assert!(!hosts("not_a_real_op"));
    }

    #[test]
    fn align_to_artboard_uses_the_selected_artboard_else_the_first() {
        let boards = || vec![artboard("aaa", 0.0, 0.0, 100.0, 100.0),
                             artboard("bbb", 200.0, 0.0, 100.0, 100.0)];
        let rects = || vec![rect(50.0, 0.0, 10.0, 10.0), rect(70.0, 0.0, 10.0, 10.0)];

        let mut first = model_with(rects(), &[0, 1], boards());
        apply_align_operation(&mut first, "align_left", &input(AlignTo::Artboard));
        assert_eq!(xs(&first), vec![0.0, 0.0], "no artboard selected: the first");

        let mut picked = model_with(rects(), &[0, 1], boards());
        let mut i = input(AlignTo::Artboard);
        i.artboard_selection = vec!["bbb".into()];
        apply_align_operation(&mut picked, "align_left", &i);
        assert_eq!(xs(&picked), vec![200.0, 200.0], "the selected artboard");
    }

    #[test]
    fn align_to_key_object_leaves_the_key_and_moves_the_rest() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(50.0, 0.0, 10.0, 10.0),
                 rect(90.0, 0.0, 10.0, 10.0)],
            &[0, 1, 2], vec![]);
        let mut i = input(AlignTo::KeyObject);
        i.key_object_path = Some(vec![0, 1]);
        assert_eq!(apply_align_operation(&mut m, "align_left", &i), AlignOutcome::Moved(2));
        assert_eq!(xs(&m), vec![50.0, 50.0, 50.0]);
    }

    #[test]
    fn key_object_mode_without_a_key_is_unchanged() {
        let mut m = model_with(
            vec![rect(10.0, 0.0, 10.0, 10.0), rect(50.0, 0.0, 10.0, 10.0)],
            &[0, 1], vec![]);
        assert_eq!(apply_align_operation(&mut m, "align_left", &input(AlignTo::KeyObject)),
                   AlignOutcome::Unchanged);
        assert_eq!(xs(&m), vec![10.0, 50.0]);
    }

    #[test]
    fn distribute_spacing_uses_the_explicit_gap_only_with_a_key() {
        // Three 10-wide rects; the key is the first. With an explicit gap of
        // 5, the others sit 5 apart to its right: 10 → 25 → 40.
        let rects = || vec![rect(10.0, 0.0, 10.0, 10.0), rect(40.0, 0.0, 10.0, 10.0),
                            rect(100.0, 0.0, 10.0, 10.0)];
        let mut keyed = model_with(rects(), &[0, 1, 2], vec![]);
        let mut i = input(AlignTo::KeyObject);
        i.key_object_path = Some(vec![0, 0]);
        i.distribute_spacing = 5.0;
        assert_eq!(i.explicit_gap(), Some(5.0));
        apply_align_operation(&mut keyed, "distribute_horizontal_spacing", &i);
        assert_eq!(xs(&keyed), vec![10.0, 25.0, 40.0]);

        // Selection mode ignores the gap (average mode): the span 10..110
        // holds 30 of width, so the two gaps are 35 each.
        let mut avg = model_with(rects(), &[0, 1, 2], vec![]);
        let mut j = input(AlignTo::Selection);
        j.distribute_spacing = 5.0;
        assert_eq!(j.explicit_gap(), None);
        apply_align_operation(&mut avg, "distribute_horizontal_spacing", &j);
        assert_eq!(xs(&avg), vec![10.0, 55.0, 100.0]);
    }

    #[test]
    fn preview_bounds_count_the_stroke() {
        // Two rects, left edges both at 10; the second has a 10-wide stroke,
        // so its PREVIEW left edge is 5. Geometric: already aligned.
        // Preview: the first moves 5 left to meet it.
        let stroked = |x| {
            let mut r = rect(x, 20.0, 10.0, 10.0);
            if let Element::Rect(ref mut rr) = r {
                rr.stroke = Some(Stroke::new(Color::BLACK, 10.0));
            }
            r
        };
        let mut geo = model_with(vec![rect(10.0, 0.0, 10.0, 10.0), stroked(10.0)], &[0, 1], vec![]);
        assert_eq!(apply_align_operation(&mut geo, "align_left", &input(AlignTo::Selection)),
                   AlignOutcome::Unchanged);

        let mut prev = model_with(vec![rect(10.0, 0.0, 10.0, 10.0), stroked(10.0)], &[0, 1], vec![]);
        let mut i = input(AlignTo::Selection);
        i.use_preview_bounds = true;
        assert_eq!(apply_align_operation(&mut prev, "align_left", &i), AlignOutcome::Moved(1));
        assert_eq!(xs(&prev), vec![5.0, 10.0]);
    }

    #[test]
    fn a_vertical_op_moves_y_only() {
        let mut m = model_with(
            vec![rect(10.0, 10.0, 10.0, 10.0), rect(40.0, 70.0, 10.0, 10.0)],
            &[0, 1], vec![]);
        apply_align_operation(&mut m, "align_bottom", &input(AlignTo::Selection));
        assert_eq!(ys(&m), vec![70.0, 70.0]);
        assert_eq!(xs(&m), vec![10.0, 40.0]);
    }

    // ── the real workspace ────────────────────────────────────────────────

    /// Every button on the compiled Align panel dispatches an action whose one
    /// effect besides `snapshot` this host runs. The population is the PANEL's
    /// buttons, not the `align` category, which also holds three state
    /// setters (`set_align_to`, …) that the effects runner handles itself. A
    /// new button without a host reds here, and so does a host that stops
    /// naming one.
    #[test]
    fn this_host_runs_every_align_panel_button() {
        fn dispatched(n: &serde_json::Value, out: &mut Vec<String>) {
            match n {
                serde_json::Value::Object(m) => {
                    if let Some(serde_json::Value::String(a)) = m.get("dispatch") {
                        out.push(a.clone());
                    }
                    m.values().for_each(|v| dispatched(v, out));
                }
                serde_json::Value::Array(a) => a.iter().for_each(|v| dispatched(v, out)),
                _ => {}
            }
        }
        let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
        let panel = ws.panel("align_panel_content").expect("align panel");
        let mut actions = vec![];
        dispatched(panel, &mut actions);
        actions.sort();
        actions.dedup();
        assert!(!actions.is_empty(), "the walk found no button");

        let mut keys = vec![];
        for name in &actions {
            let effects = ws.actions().get(name).and_then(|d| d.get("effects"))
                .and_then(|e| e.as_array()).unwrap_or_else(|| panic!("{name} has no effects"));
            let own: Vec<&str> = effects.iter()
                .filter(|e| e.as_str() != Some("snapshot"))
                .map(|e| {
                    let obj = e.as_object().unwrap_or_else(|| panic!("{name}: {e}"));
                    assert_eq!(obj.len(), 1, "{name}: one key per effect");
                    obj.keys().next().unwrap().as_str()
                })
                .collect();
            assert_eq!(own.len(), 1, "{name} runs {own:?}");
            assert!(hosts(own[0]), "{name}'s effect `{}` has no host", own[0]);
            keys.push(own[0].to_string());
        }
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), actions.len(), "each button its own op: {keys:?}");
        eprintln!("align host: {} panel buttons, all hosted", actions.len());
    }

    /// The input is built from the panel's OWN keys. The web panel state calls
    /// the gap `distribute_spacing` and the global mirror calls it
    /// `align_distribute_spacing`; a builder reading either of those reads
    /// nothing from the align panel.
    #[test]
    fn the_input_builder_reads_the_keys_align_yaml_declares() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("workspace");
        let declared = ws.panel_state_defaults("align_panel_content");
        for k in AlignInput::PANEL_KEYS {
            assert!(declared.contains_key(k), "`{k}` is not an align panel state key");
        }
        assert_eq!(AlignInput::PANEL_KEYS.len(), declared.len(),
                   "every declared key is read: {declared:?}");

        let mut store = StateStore::new();
        store.init_panel("align_panel_content", declared.clone());
        let defaults = AlignInput::from_panel_state(&store, "align_panel_content", vec![]);
        assert_eq!(defaults, input(AlignTo::Selection), "the declared defaults");

        store.set_panel("align_panel_content", "align_to", serde_json::json!("key_object"));
        store.set_panel("align_panel_content", "key_object_path",
                        serde_json::json!({"__path__": [0, 2]}));
        store.set_panel("align_panel_content", "distribute_spacing_value", serde_json::json!(12));
        store.set_panel("align_panel_content", "use_preview_bounds", serde_json::json!(true));
        // Decoys under the OTHER two spellings must be ignored.
        store.set_panel("align_panel_content", "distribute_spacing", serde_json::json!(99));
        store.set("align_distribute_spacing", serde_json::json!(98));
        let built = AlignInput::from_panel_state(&store, "align_panel_content",
                                                 vec!["ab1".into()]);
        assert_eq!(built, AlignInput {
            align_to: AlignTo::KeyObject,
            key_object_path: Some(vec![0, 2]),
            distribute_spacing: 12.0,
            use_preview_bounds: true,
            artboard_selection: vec!["ab1".into()],
        });
    }

    #[test]
    fn a_path_value_reads_both_spellings_and_refuses_the_rest() {
        assert_eq!(path_value(&serde_json::json!({"__path__": [1, 2]})), Some(vec![1, 2]));
        assert_eq!(path_value(&serde_json::json!([3])), Some(vec![3]));
        assert_eq!(path_value(&serde_json::Value::Null), None);
        assert_eq!(path_value(&serde_json::json!("0.1")), None);
    }

    #[test]
    fn align_to_names_match_the_yaml_enum() {
        for t in [AlignTo::Selection, AlignTo::Artboard, AlignTo::KeyObject] {
            assert_eq!(AlignTo::from_str(t.as_str()), Some(t));
        }
        assert_eq!(AlignTo::from_str("canvas"), None);
    }
}
