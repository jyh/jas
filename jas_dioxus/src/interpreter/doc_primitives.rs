//! Document-aware evaluator primitives.
//!
//! Tools written in YAML call functions like `hit_test(x, y)` or
//! `selection_contains(path)` that need access to the current
//! document. The pure expression evaluator (`expr_eval.rs`) can't
//! carry a Document through its signature without rippling lifetimes
//! throughout, so we stash the document in a thread-local for the
//! duration of a tool dispatch.
//!
//! Mirrors `registerDocumentPrimitives` in
//! `jas_flask/static/js/engine/tools.mjs`. The JS engine mutates a
//! `PRIMITIVES` dict before each dispatch and restores the prior
//! entries after; we do the moral equivalent with a `RefCell<Option<Document>>`
//! guarded by [`DocGuard`] so nested registrations nest safely and
//! never leak past a dispatch's end.
//!
//! Primitives return `Value::Null` (or a sensible zero — e.g.
//! `Value::Bool(false)`) when no document has been registered, so
//! evaluating a tool expression outside a dispatch context degrades
//! gracefully rather than panicking.

use std::cell::RefCell;

use super::expr_types::Value;
use crate::document::document::Document;

thread_local! {
    static CURRENT_DOC: RefCell<Option<Document>> = const { RefCell::new(None) };
}

/// Guard returned by [`register_document`]. Dropping it restores the
/// previously registered document (usually `None`). Because restoration
/// happens in `Drop`, early returns and panics in the dispatch body
/// still run the cleanup.
pub struct DocGuard {
    prior: Option<Document>,
}

impl Drop for DocGuard {
    fn drop(&mut self) {
        let prior = self.prior.take();
        CURRENT_DOC.with(|c| *c.borrow_mut() = prior);
    }
}

/// Install `doc` as the current dispatch's document. Returns a guard
/// whose `Drop` restores the previous document. Safe to nest: each
/// call saves the outer document in its guard and restores on drop.
pub fn register_document(doc: Document) -> DocGuard {
    let prior = CURRENT_DOC.with(|c| c.replace(Some(doc)));
    DocGuard { prior }
}

/// Peek at the registered document without cloning. Returns `None`
/// when no dispatch is active. Primarily intended for the primitive
/// implementations in this module.
fn with_doc<F, R>(default: R, f: F) -> R
where
    F: FnOnce(&Document) -> R,
{
    CURRENT_DOC.with(|c| match &*c.borrow() {
        Some(doc) => f(doc),
        None => default,
    })
}

/// `hit_test(x, y)` → `Path | null`. Returns the path of the topmost
/// unlocked, visible element whose bounding box contains the point.
/// Matches `hitTestImpl` in `jas_flask/static/js/engine/geometry.mjs`.
///
/// This is the "flat" variant — stops at direct layer children without
/// recursing into groups. Selection tool uses it because it wants to
/// select whole groups on click. For the per-element-through-groups
/// behavior (used by InteriorSelection), see [`hit_test_deep`].
pub fn hit_test(x: f64, y: f64) -> Value {
    with_doc(Value::Null, |doc| {
        use crate::geometry::element::Visibility;
        for (li, layer) in doc.layers.iter().enumerate() {
            if layer.visibility() == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                // Top-down: last-drawn element is hit first.
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    if std::cmp::min(layer.visibility(), child.visibility())
                        == Visibility::Invisible
                    {
                        continue;
                    }
                    let (bx, by, bw, bh) = child.bounds();
                    if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
                        return Value::Path(vec![li, ci]);
                    }
                }
            }
        }
        Value::Null
    })
}

/// `hit_test_deep(x, y)` → `Path | null`. Recurses into groups so the
/// returned path points at the deepest leaf element under the cursor.
/// Matches `hit_recursive` in the deleted
/// `jas_dioxus/src/tools/interior_selection_tool.rs`.
pub fn hit_test_deep(x: f64, y: f64) -> Value {
    use crate::geometry::element::{Element, Visibility};
    fn recurse(
        elem: &Element,
        path: Vec<usize>,
        ancestor_vis: Visibility,
        x: f64,
        y: f64,
    ) -> Option<Vec<usize>> {
        let effective = std::cmp::min(ancestor_vis, elem.visibility());
        if effective == Visibility::Invisible {
            return None;
        }
        if elem.is_group_or_layer() {
            if let Some(children) = elem.children() {
                for (i, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    let mut child_path = path.clone();
                    child_path.push(i);
                    if let Some(result) =
                        recurse(child, child_path, effective, x, y)
                    {
                        return Some(result);
                    }
                }
            }
            return None;
        }
        let (bx, by, bw, bh) = elem.bounds();
        if x >= bx && x <= bx + bw && y >= by && y <= by + bh {
            Some(path)
        } else {
            None
        }
    }
    with_doc(Value::Null, |doc| {
        for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    let child_vis = std::cmp::min(layer_vis, child.visibility());
                    if child_vis == Visibility::Invisible {
                        continue;
                    }
                    if let Some(path) =
                        recurse(child, vec![li, ci], child_vis, x, y)
                    {
                        return Value::Path(path);
                    }
                }
            }
        }
        Value::Null
    })
}

/// `selection_contains(path)` → `bool`. True iff the given path is
/// currently selected.
pub fn selection_contains(arg: &Value) -> Value {
    let target: Vec<usize> = match arg {
        Value::Path(p) => p.clone(),
        _ => return Value::Bool(false),
    };
    with_doc(Value::Bool(false), |doc| {
        let found = doc.selection.iter().any(|es| es.path == target);
        Value::Bool(found)
    })
}

/// `selection_empty()` → `bool`. True iff the current selection is
/// empty (or no document is registered).
pub fn selection_empty() -> Value {
    with_doc(Value::Bool(true), |doc| Value::Bool(doc.selection.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::{Document, ElementSelection};
    use crate::geometry::element::{
        Color, CommonProps, Element, Fill, LayerElem, RectElem,
    };

    fn doc_with_rect() -> Document {
        let rect = Element::Rect(RectElem {
            x: 10.0, y: 10.0, width: 20.0, height: 20.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
            ..Document::default()
        }
    }

    #[test]
    fn hit_test_without_registered_doc_is_null() {
        // Outside any dispatch, primitives return null/false.
        assert_eq!(hit_test(15.0, 15.0), Value::Null);
    }

    #[test]
    fn hit_test_hits_element_inside_bounds() {
        let _g = register_document(doc_with_rect());
        let result = hit_test(15.0, 15.0);
        assert_eq!(result, Value::Path(vec![0, 0]));
    }

    #[test]
    fn hit_test_returns_group_path_when_clicking_child_rect() {
        // Layer 0 contains Group 0 which contains a Rect at (10,10,20,20).
        // Selection-tool hit_test stops at direct layer children — so
        // clicking inside the rect's bounds must return the GROUP path
        // (not the deeper rect path; that's hit_test_deep's job).
        use crate::geometry::element::GroupElem;
        let rect = Element::Rect(RectElem {
            x: 10.0, y: 10.0, width: 20.0, height: 20.0,
            rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(group)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0, selection: Vec::new(),
            ..Document::default()
        };
        let _g = register_document(doc);
        // Click inside the rect's bounds.
        let hit = hit_test(15.0, 15.0);
        assert_eq!(
            hit, Value::Path(vec![0, 0]),
            "click inside group's child rect should return the group path \
             (layer 0 → group 0); got {:?}", hit,
        );
    }

    #[test]
    fn hit_test_misses_element_outside_bounds() {
        let _g = register_document(doc_with_rect());
        assert_eq!(hit_test(100.0, 100.0), Value::Null);
    }

    #[test]
    fn hit_test_returns_null_for_non_number_args() {
        // This is a property of the caller in expr_eval, not this module,
        // but document the behavior: the primitive itself only receives
        // f64s; arg-type validation happens at the evaluator match arm.
        let _g = register_document(doc_with_rect());
        let _ = hit_test(15.0, 15.0); // just confirm no panic on valid
    }

    #[test]
    fn guard_drop_restores_prior_state() {
        // Outer registration.
        let _outer = register_document(doc_with_rect());
        assert_eq!(hit_test(15.0, 15.0), Value::Path(vec![0, 0]));
        {
            // Inner scope: register a fresh (empty) doc.
            let _inner = register_document(Document::default());
            // Empty doc has no elements to hit.
            assert_eq!(hit_test(15.0, 15.0), Value::Null);
        }
        // After inner scope drops, outer doc is restored.
        assert_eq!(hit_test(15.0, 15.0), Value::Path(vec![0, 0]));
    }

    #[test]
    fn guard_drop_clears_when_no_prior() {
        {
            let _g = register_document(doc_with_rect());
            assert_eq!(hit_test(15.0, 15.0), Value::Path(vec![0, 0]));
        }
        // Back to None after the guard drops.
        assert_eq!(hit_test(15.0, 15.0), Value::Null);
    }

    #[test]
    fn selection_contains_returns_false_without_doc() {
        assert_eq!(
            selection_contains(&Value::Path(vec![0, 0])),
            Value::Bool(false),
        );
    }

    #[test]
    fn selection_contains_returns_false_for_non_path_arg() {
        let _g = register_document(doc_with_rect());
        assert_eq!(
            selection_contains(&Value::Number(0.0)),
            Value::Bool(false),
        );
    }

    #[test]
    fn selection_contains_finds_selected_path() {
        let mut doc = doc_with_rect();
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let _g = register_document(doc);
        assert_eq!(
            selection_contains(&Value::Path(vec![0, 0])),
            Value::Bool(true),
        );
        assert_eq!(
            selection_contains(&Value::Path(vec![0, 1])),
            Value::Bool(false),
        );
    }

    #[test]
    fn selection_empty_without_doc_is_true() {
        assert_eq!(selection_empty(), Value::Bool(true));
    }

    #[test]
    fn selection_empty_reflects_document_selection() {
        let mut doc = doc_with_rect();
        let _g = register_document(doc.clone());
        assert_eq!(selection_empty(), Value::Bool(true));
        drop(_g);

        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let _g2 = register_document(doc);
        assert_eq!(selection_empty(), Value::Bool(false));
    }

    // ── Integration: primitives dispatch through the evaluator ──────

    use super::super::expr::eval;

    #[test]
    fn evaluator_dispatches_hit_test_during_registered_dispatch() {
        let _g = register_document(doc_with_rect());
        // hit_test(15, 15) — point inside the rect at (10,10,20,20).
        // Path values round-trip through serde_json as {"__path__":[...]}.
        let v = eval("hit_test(15, 15)", &serde_json::json!({}));
        assert_eq!(v, Value::Path(vec![0, 0]));
    }

    #[test]
    fn evaluator_dispatches_hit_test_miss_returns_null() {
        let _g = register_document(doc_with_rect());
        let v = eval("hit_test(100, 100)", &serde_json::json!({}));
        assert_eq!(v, Value::Null);
    }

    #[test]
    fn evaluator_returns_null_for_hit_test_outside_dispatch() {
        // No registered document → null.
        let v = eval("hit_test(15, 15)", &serde_json::json!({}));
        assert_eq!(v, Value::Null);
    }

    #[test]
    fn evaluator_dispatches_selection_contains() {
        let mut doc = doc_with_rect();
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let _g = register_document(doc);
        // path(0, 0) constructs a Path value via the evaluator, which
        // selection_contains consumes. path() is an existing primitive
        // in expr_eval.rs.
        let yes = eval("selection_contains(path(0, 0))", &serde_json::json!({}));
        assert_eq!(yes, Value::Bool(true));
        let no = eval("selection_contains(path(0, 1))", &serde_json::json!({}));
        assert_eq!(no, Value::Bool(false));
    }

    #[test]
    fn evaluator_dispatches_selection_empty() {
        let _g = register_document(doc_with_rect());
        let v = eval("selection_empty()", &serde_json::json!({}));
        assert_eq!(v, Value::Bool(true));
    }

    #[test]
    fn evaluator_hit_test_with_non_number_args_returns_null() {
        let _g = register_document(doc_with_rect());
        // "abc" is a string literal; hit_test returns null when args
        // aren't numbers.
        let v = eval("hit_test(\"abc\", 15)", &serde_json::json!({}));
        assert_eq!(v, Value::Null);
    }

    #[test]
    fn evaluator_let_binding_captures_hit_test_result() {
        // Mirrors the selection.yaml pattern:
        //   let: { hit: "hit_test(event.x, event.y)" }
        //   in:  [ ... use hit ... ]
        // Here we exercise the let-form directly via the evaluator's
        // scope by evaluating `hit_test` with event-scope values.
        let _g = register_document(doc_with_rect());
        let ctx = serde_json::json!({
            "event": { "x": 15, "y": 15 }
        });
        let v = eval("hit_test(event.x, event.y)", &ctx);
        assert_eq!(v, Value::Path(vec![0, 0]));
    }
}
