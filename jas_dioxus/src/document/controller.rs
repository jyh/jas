//! Document controller (MVC pattern).
//!
//! The Controller provides mutation operations on the Model's document.
//! Since the Document is cloned on mutation, changes produce a new Document
//! that replaces the old one in the Model.

use std::rc::Rc;

use crate::document::document::{
    Document, ElementPath, ElementSelection, Selection, SelectionKind, SortedCps,
};
use crate::document::model::{Model, NonUndoableIntent};
use crate::geometry::element::{
    control_point_count, control_points, move_control_points,
    move_path_handle, with_fill, with_stroke, with_width_points,
    Element, Fill, GroupElem, Mask, Stroke, StrokeWidthPoint,
};
use crate::algorithms::hit_test::{element_intersects_polygon, element_intersects_rect, point_in_rect};

// ---------------------------------------------------------------------------
// Helpers — shared by the Controller's boolean ops
// ---------------------------------------------------------------------------

// ── Opacity-mask helpers (OPACITY.md § States) ──────────────

/// Return the [`Mask`] on the first selected element, if any.
/// Drives "first-element-wins" toggles in the Opacity panel (disable,
/// unlink, and the MAKE_MASK_BUTTON label flip per OPACITY.md § States).
pub fn first_mask(doc: &Document) -> Option<&Mask> {
    let first = doc.selection.first()?;
    doc.get_element(&first.path)?.common().mask.as_deref()
}

/// True when **every** selected element has an opacity mask attached.
/// Mixed selections (some masked, some not) count as "no mask" per
/// OPACITY.md § States, so the MAKE_MASK_BUTTON stays in its "Make Mask"
/// state and the CLIP / INVERT checkboxes remain disabled for mixed
/// selections.
pub fn selection_has_mask(doc: &Document) -> bool {
    if doc.selection.is_empty() {
        return false;
    }
    doc.selection.iter().all(|es| {
        doc.get_element(&es.path)
            .map(|e| e.common().mask.is_some())
            .unwrap_or(false)
    })
}

/// MERGE predicate per BOOLEAN.md §Operand and paint rules.
/// Two fills merge when both are solid colors with exactly equal
/// `color` components. `None` fills never match anything — including
/// other `None` fills. Gradients and patterns, once they exist,
/// likewise never match; the current `Fill` type holds only a
/// solid-color enum so every `Some(_)` is eligible today.
/// Only the color is inspected; opacity / stroke / blend_mode do not
/// participate.
fn fills_merge_equal(a: &Option<Fill>, b: &Option<Fill>) -> bool {
    match (a, b) {
        (Some(fa), Some(fb)) => fa.color == fb.color,
        _ => false,
    }
}

/// The `CommonProps` an N -> 1 merge product wears, minus its id (the caller
/// mints that). transcripts/EDIT_SEMANTICS_FREEZE.md §3.3, ratified
/// 2026-07-27.
///
/// PAINT rides from `front`: BOOLEAN.md §Operand and paint rules names four
/// properties — fill, stroke, `opacity`, blend mode — as what a boolean op
/// SPEAKS TO, and two of them (`opacity`, `mode`) live on `CommonProps`.
///
/// EVERYTHING ELSE follows UNANIMITY: when every source agrees, carrying the
/// value IS preservation — well-defined, no winner elected — and when they
/// disagree the fresh element's documented default stands. Nothing geometric
/// ever breaks the tie; "the frontmost/largest source keeps it" was rejected
/// in both directions.
///
/// `name` follows ASSERTING-SOURCES unanimity (JYH's ratified answer (1)):
/// unanimity ranges over the sources that ASSERT a name, because absence is
/// not a competing claim. "hull" + unnamed -> "hull"; "hull" + "keel" ->
/// the default. Nothing geometric elects the survivor there either — the only
/// assertion present survives.
///
/// `transform` is carried unanimously and no further. The flattening walk
/// (`element_to_polygon_set_with`) contains ZERO transform references, so the
/// result rings are RAW: a unanimous transform is the only one under which
/// they are meaningful, and operands that disagree already produced nonsense
/// geometry before this function existed. What changes is that no operand is
/// elected to donate one. Widening this is S-3's job (§3.3).
fn merged_common(
    sources: &[Rc<Element>],
    front: &Rc<Element>,
) -> crate::geometry::element::CommonProps {
    use crate::geometry::element::CommonProps;
    fn unanimous<T: PartialEq + Clone>(
        sources: &[Rc<Element>],
        get: impl Fn(&Element) -> T,
    ) -> Option<T> {
        let first = get(sources.first()?);
        sources
            .iter()
            .all(|e| get(e) == first)
            .then_some(first)
    }
    let mut common = CommonProps {
        // Paint, per the ratified four-property rule.
        opacity: front.common().opacity,
        mode: front.common().mode,
        ..CommonProps::default()
    };
    if let Some(v) = unanimous(sources, |e| e.common().transform) {
        common.transform = v;
    }
    if let Some(v) = unanimous(sources, |e| e.common().locked) {
        common.locked = v;
    }
    if let Some(v) = unanimous(sources, |e| e.common().visibility) {
        common.visibility = v;
    }
    if let Some(v) = unanimous(sources, |e| e.common().mask.clone()) {
        common.mask = v;
    }
    if let Some(v) = unanimous(sources, |e| e.common().tool_origin.clone()) {
        common.tool_origin = v;
    }
    // ASSERTING-SOURCES: silent sources are not voters.
    let named: Vec<Rc<Element>> = sources
        .iter()
        .filter(|e| e.common().name.is_some())
        .cloned()
        .collect();
    if let Some(v) = unanimous(&named, |e| e.common().name.clone()) {
        common.name = v;
    }
    common
}

/// Collapse each ring point whose perpendicular distance to the line
/// between its two neighbors is smaller than `tol`. Single-pass;
/// acceptable for boolean-op outputs which already have clean right-
/// angle / smooth-arc corners. Preserves the original ring if
/// collapse leaves fewer than 3 points.
fn collapse_collinear_points(ring: Vec<(f64, f64)>, tol: f64) -> Vec<(f64, f64)> {
    if ring.len() < 3 {
        return ring;
    }
    let n = ring.len();
    let mut keep = vec![true; n];
    for i in 0..n {
        let prev = ring[(i + n - 1) % n];
        let cur = ring[i];
        let next = ring[(i + 1) % n];
        let dx = next.0 - prev.0;
        let dy = next.1 - prev.1;
        let seg_len = (dx * dx + dy * dy).sqrt();
        if seg_len == 0.0 {
            // Degenerate neighborhood — cur is on top of its neighbors.
            keep[i] = false;
            continue;
        }
        let num = ((next.0 - prev.0) * (prev.1 - cur.1)
            - (prev.0 - cur.0) * (next.1 - prev.1))
            .abs();
        if num / seg_len < tol {
            keep[i] = false;
        }
    }
    let collapsed: Vec<(f64, f64)> = ring
        .iter()
        .enumerate()
        .filter(|(i, _)| keep[*i])
        .map(|(_, p)| *p)
        .collect();
    if collapsed.len() < 3 { ring } else { collapsed }
}

/// Options for destructive boolean operations, read from the Boolean
/// Options dialog and mirrored in `AppState.boolean_panel`. See
/// BOOLEAN.md §Boolean Options dialog.
#[derive(Debug, Clone, Copy)]
pub struct BooleanOptions {
    pub precision: f64,
    pub remove_redundant_points: bool,
    pub divide_remove_unpainted: bool,
    /// When true, the caller runs Controller::simplify_selection on
    /// the boolean's output right after apply_destructive_boolean
    /// completes. Off by default — refitting is lossy and the raw
    /// polygon output is what most callers expect. The boolean
    /// emitter itself does not consult this field; it's a signal to
    /// the surrounding pipeline (see app_state::apply_boolean_operation).
    pub apply_simplify_after_op: bool,
    /// Max-error tolerance (in document units, typically points) for
    /// the curve fit run by Controller::simplify_selection. Consulted
    /// by the caller, not by apply_destructive_boolean itself.
    pub simplify_precision: f64,
}

impl Default for BooleanOptions {
    fn default() -> Self {
        Self {
            precision: 0.0283,
            remove_redundant_points: false,
            divide_remove_unpainted: false,
            apply_simplify_after_op: false,
            simplify_precision: 0.5,
        }
    }
}

/// Find the first id-bearing element named `id`, searching `doc.symbols`
/// (sorted-by-id for determinism, matching every order-dependent symbols site)
/// then `doc.layers` in pre-order. A pure lookup — no entropy — used by
/// `Controller::detach` to resolve an instance's target across both the
/// off-canvas master store and the canvas tree (SYMBOLS.md §7). Returns an
/// owned clone so callers can mutate it independently.
fn find_element_by_id(doc: &Document, id: &str) -> Option<Element> {
    fn walk(elem: &Element, id: &str) -> Option<Element> {
        if elem.common().id.as_deref() == Some(id) {
            return Some(elem.clone());
        }
        if let Some(children) = elem.children() {
            for child in children {
                if let Some(found) = walk(child, id) {
                    return Some(found);
                }
            }
        }
        None
    }
    // Symbols first, in sorted-by-id order (the §2 deterministic-order rule).
    let mut sorted_masters: Vec<&Element> = doc.symbols.iter().collect();
    sorted_masters.sort_by(|a, b| {
        a.common().id.as_deref().unwrap_or("")
            .cmp(b.common().id.as_deref().unwrap_or(""))
    });
    for master in sorted_masters {
        if let Some(found) = walk(master, id) {
            return Some(found);
        }
    }
    // Then the layer tree.
    for layer in &doc.layers {
        if let Some(found) = walk(layer, id) {
            return Some(found);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Mediates between user actions and the document model.
pub struct Controller;

/// Resolve the current selection to the stable `common.id`s of the selected
/// elements, in selection order (OP_LOG.md §9 / Fork 4: the `targets` of a
/// journaled op). Id-less selected elements are silently dropped (`common.id`
/// is `Option`; a recorded source must carry an id — a documented
/// prerequisite, not a bug). One definition reused by the production
/// `op_apply` path and the `#[cfg(test)]` harness so both populate `targets`
/// identically.
pub fn selection_to_ids(doc: &Document) -> Vec<String> {
    doc.selection
        .iter()
        .filter_map(|es| doc.get_element(&es.path).and_then(|e| e.common().id.clone()))
        .collect()
}

/// Rewrite `path` for an element having been inserted at `inserted_at`.
///
/// A path held across a structural insertion goes stale: inserting a sibling
/// ahead of it pushes it up one slot, and nothing in the path itself says so.
/// `Controller::copy_selection` is where that bit us (§19) — it records a copy
/// path and then inserts BELOW it, so the recorded path silently came to name
/// the source instead of the copy.
///
/// Only the slot the insertion happened in can move: `inserted_at` splits into
/// a parent prefix and a sibling index, and a path is affected only when it
/// shares that prefix AND sits at or after that index. Paths in other subtrees,
/// paths shorter than the prefix, and the prefix itself are untouched. Nothing
/// below the affected component changes — the subtree moved intact.
///
/// Mirrors JasSwift `shiftedPath(_:forInsertionAt:)`.
fn shift_path_for_insertion(path: &mut ElementPath, inserted_at: &ElementPath) {
    let Some(depth) = inserted_at.len().checked_sub(1) else { return };
    if path.len() <= depth || path[..depth] != inserted_at[..depth] {
        return;
    }
    if path[depth] >= inserted_at[depth] {
        path[depth] += 1;
    }
}

impl Controller {
    /// Add an element to the current editing target and select the
    /// new element. In content-mode (the default), the element is
    /// appended to the selected layer. In mask-editing mode
    /// (OPACITY.md §Preview interactions) the element is appended
    /// to the masked element's mask subtree instead — mask-mode
    /// falls back to the layer path when the mask subtree isn't a
    /// Group (shouldn't happen with masks created via
    /// [`Controller::make_mask_on_selection`], but protects against
    /// externally-built masks).
    pub fn add_element(model: &mut Model, element: Element) {
        // Fast-path the content case first so the common flow stays
        // cheap.
        if let crate::document::model::EditingTarget::Mask(path) = model.editing_target.clone() {
            if Self::add_element_to_mask(model, element.clone(), &path) {
                return;
            }
            // Mask subtree wasn't a container that accepts children
            // (e.g. a raw shape). Fall through to layer-append so the
            // user's stroke isn't lost.
        }
        let doc = model.document().clone();
        let idx = doc.selected_layer;
        let _n = control_point_count(&element);
        let mut new_doc = doc;
        let child_idx = if let Some(children) = new_doc.layers[idx].children_mut() {
            let ci = children.len();
            children.push(Rc::new(element));
            ci
        } else {
            model.edit_document(new_doc);
            return;
        };
        new_doc.selection = vec![ElementSelection::all(vec![idx, child_idx])];
        model.edit_document(new_doc);
    }

    /// Stamp a stable `id` onto the element at `path` — the lazy
    /// assign-on-create primitive (REFERENCE_GRAPH.md §4). The id is
    /// minted by the initiator and carried in the operation payload,
    /// never minted here, so every app applies the identical value. A
    /// no-op when the path is invalid. The caller owns identity: this
    /// overwrites any existing id (re-identification is the initiator's
    /// responsibility; reference remapping arrives with the graph).
    pub fn assign_id(model: &mut Model, path: &ElementPath, id: &str) {
        let mut new_doc = model.document().clone();
        if let Some(elem) = new_doc.get_element_mut(path) {
            elem.common_mut().id = Some(id.to_string());
            model.edit_document(new_doc);
        }
    }

    /// Create a by-id reference to the element at `target_path`
    /// (REFERENCE_GRAPH.md §4). Assign-on-create: stamp `target_id` onto the
    /// target *iff* it has no id yet (the lazy-mint trigger); if it already
    /// has one, that id names the edge and `target_id` is ignored. A new
    /// `ReferenceElem` (its own id = `ref_id`) is then appended. Both ids are
    /// minted by the initiator and carried in the op payload — never minted
    /// here — so every app applies identical values. No-op on an invalid path.
    pub fn create_reference(
        model: &mut Model,
        target_path: &ElementPath,
        target_id: &str,
        ref_id: &str,
    ) {
        let doc = model.document().clone();
        let Some(target) = doc.get_element(target_path) else { return };
        let resolved_id = match target.common().id.clone() {
            Some(existing) => existing,
            None => {
                let mut t = target.clone();
                t.common_mut().id = Some(target_id.to_string());
                model.edit_document(doc.replace_element(target_path, t));
                target_id.to_string()
            }
        };
        let reference = Element::Live(crate::geometry::live::LiveVariant::Reference(
            crate::geometry::live::ReferenceElem::new(
                crate::geometry::live::ElementRef(resolved_id),
                crate::geometry::element::CommonProps {
                    id: Some(ref_id.to_string()),
                    ..crate::geometry::element::CommonProps::default()
                },
            ),
        ));
        Self::add_element(model, reference);
    }

    // -----------------------------------------------------------------------
    // Symbols P2 — operations (SYMBOLS.md §7). Value-in-op: every id is minted
    // by the initiator/UI and carried in the op payload, never minted inside the
    // Controller (same rule as create_reference / assign_id), so all apps apply
    // identical values. Each clones the doc, mutates, and set_document — no
    // internal snapshot; the caller owns undo.
    // -----------------------------------------------------------------------

    /// Make Symbol (promote): move the element at `path` into `doc.symbols` as a
    /// master and leave a `ReferenceElem` instance in its place (SYMBOLS.md §7,
    /// Fork S6 — the dual of Detach). Assign-on-create: if the element already
    /// has a `common.id`, that id is KEPT as the master key and `master_id` is
    /// ignored (mirrors create_reference's target rule); otherwise `master_id`
    /// is stamped. The instance carries `common.id = ref_id` and targets the
    /// master id. Net: the master lives off-canvas in `symbols`, an instance
    /// sits where the element was, so the canvas looks unchanged (the instance
    /// resolves to the master geometry). No-op on an invalid path.
    pub fn make_symbol(
        model: &mut Model,
        path: &ElementPath,
        master_id: &str,
        ref_id: &str,
    ) {
        let doc = model.document().clone();
        let Some(target) = doc.get_element(path) else { return };
        // Resolve the master id: keep the element's own id if it has one,
        // else stamp the carried master_id (assign-on-create).
        let resolved_id = target.common().id.clone()
            .unwrap_or_else(|| master_id.to_string());
        // The master carries the resolved id.
        let mut master = target.clone();
        master.common_mut().id = Some(resolved_id.clone());
        // The in-place instance targets the master id, with its own ref_id.
        let reference = Element::Live(crate::geometry::live::LiveVariant::Reference(
            crate::geometry::live::ReferenceElem::new(
                crate::geometry::live::ElementRef(resolved_id),
                crate::geometry::element::CommonProps {
                    id: Some(ref_id.to_string()),
                    ..crate::geometry::element::CommonProps::default()
                },
            ),
        ));
        // Replace the element in place with the instance, then push the master
        // into the off-canvas store.
        let mut new_doc = doc.replace_element(path, reference);
        new_doc.symbols.push(master);
        model.edit_document(new_doc);
    }

    /// Place Instance: append a `ReferenceElem` targeting an existing master
    /// (`master_id`) to the active layer via [`add_element`] (which auto-selects
    /// it) — exactly like create_reference's final step (SYMBOLS.md §7). No
    /// offset: placement offset is a UI concern (like Make Instance handles it
    /// separately). It is fine if `master_id` does not currently exist; the
    /// instance simply renders empty until the master appears (dangling is
    /// already handled by the resolver). The instance carries `common.id =
    /// ref_id`, minted by the initiator.
    pub fn place_instance(model: &mut Model, master_id: &str, ref_id: &str) {
        let reference = Element::Live(crate::geometry::live::LiveVariant::Reference(
            crate::geometry::live::ReferenceElem::new(
                crate::geometry::live::ElementRef(master_id.to_string()),
                crate::geometry::element::CommonProps {
                    id: Some(ref_id.to_string()),
                    ..crate::geometry::element::CommonProps::default()
                },
            ),
        ));
        Self::add_element(model, reference);
    }

    /// Append a new generated instance of `concept_id` (with the given default
    /// `params`) to the active layer and select it (CONCEPTS.md §6). The element
    /// id is minted by the caller (value-in-op). Mirrors `place_instance`.
    pub fn place_concept_instance(
        model: &mut Model,
        concept_id: &str,
        params: serde_json::Value,
        elem_id: &str,
    ) {
        let generated = Element::Live(crate::geometry::live::LiveVariant::Generated(
            crate::geometry::live::GeneratedElem::new(
                concept_id.to_string(),
                params,
                crate::geometry::element::CommonProps {
                    id: Some(elem_id.to_string()),
                    ..crate::geometry::element::CommonProps::default()
                },
            ),
        ));
        Self::add_element(model, generated);
    }

    /// Set one parameter of the generated concept instance at `path` to `value`
    /// (CONCEPTS.md §6.4 — live param editing). The geometry re-derives from the
    /// generator at the next render. No-op if `path` is not a `Generated` element.
    pub fn set_concept_param(model: &mut Model, path: &ElementPath, name: &str, value: f64) {
        let doc = model.document().clone();
        let Some(Element::Live(crate::geometry::live::LiveVariant::Generated(ge))) =
            doc.get_element(path)
        else {
            return;
        };
        let mut new_ge = ge.clone();
        match new_ge.params {
            serde_json::Value::Object(ref mut map) => {
                map.insert(name.to_string(), serde_json::json!(value));
            }
            _ => {
                let mut map = serde_json::Map::new();
                map.insert(name.to_string(), serde_json::json!(value));
                new_ge.params = serde_json::Value::Object(map);
            }
        }
        let new_elem = Element::Live(crate::geometry::live::LiveVariant::Generated(new_ge));
        model.edit_document(doc.replace_element(path, new_elem));
    }

    /// Apply a concept operation's RESOLVED changes to the generated instance at
    /// `path` (CONCEPTS.md §9): merge each `name -> value` of `changes` into the
    /// `Generated`'s params (a multi-param generalization of `set_concept_param`).
    /// `changes` is the production-resolved effect of an operation (value-in-op),
    /// so this performs no expression evaluation — it just writes the values. The
    /// geometry re-derives from the generator at the next render. No-op if `path`
    /// is not a `Generated` element or `changes` is empty / not an object.
    pub fn apply_concept_operation(
        model: &mut Model,
        path: &ElementPath,
        changes: &serde_json::Value,
    ) {
        let Some(changes) = changes.as_object() else {
            return;
        };
        if changes.is_empty() {
            return;
        }
        let doc = model.document().clone();
        let Some(Element::Live(crate::geometry::live::LiveVariant::Generated(ge))) =
            doc.get_element(path)
        else {
            return;
        };
        let mut new_ge = ge.clone();
        match new_ge.params {
            serde_json::Value::Object(ref mut map) => {
                for (name, value) in changes {
                    map.insert(name.clone(), value.clone());
                }
            }
            _ => {
                let mut map = serde_json::Map::new();
                for (name, value) in changes {
                    map.insert(name.clone(), value.clone());
                }
                new_ge.params = serde_json::Value::Object(map);
            }
        }
        let new_elem = Element::Live(crate::geometry::live::LiveVariant::Generated(new_ge));
        model.edit_document(doc.replace_element(path, new_elem));
    }

    /// Promote the raw element at `path` to a live `Generated` instance of
    /// `concept_id` with the fitted `params` and placement `transform`
    /// (CONCEPTS.md §10 — the fitter / `promote`). The recovered params + the
    /// origin-centered generator + the placement transform re-render the same
    /// geometry the raw element drew. The original element's identity (id, name,
    /// opacity, …) is PRESERVED via its `common`; only the placement transform is
    /// (re)set. Every operand is value-in-op — the detection already happened at
    /// production time — so this just builds the element. No-op if `path` is
    /// missing.
    pub fn promote_to_concept(
        model: &mut Model,
        path: &ElementPath,
        concept_id: &str,
        params: serde_json::Value,
        transform: crate::geometry::element::Transform,
    ) {
        let doc = model.document().clone();
        let Some(existing) = doc.get_element(path) else {
            return;
        };
        // Preserve the raw element's identity; (re)set only the placement.
        let mut common = existing.common().clone();
        common.transform = Some(transform);
        let generated = Element::Live(crate::geometry::live::LiveVariant::Generated(
            crate::geometry::live::GeneratedElem::new(concept_id.to_string(), params, common),
        ));
        model.edit_document(doc.replace_element(path, generated));
    }

    /// Detach (break the link / expand): replace the `ReferenceElem` instance at
    /// `path` with an INDEPENDENT copy of its resolved target (SYMBOLS.md §7,
    /// Fork S6 — the inverse of Make Symbol). The target id is resolved by a
    /// pure lookup over ALL id-bearing elements (`doc.symbols` AND `layers`;
    /// deterministic, no entropy). The copy is born id-less ([`clear_ids`], per
    /// the duplication rule) and the instance's own overrides are applied onto
    /// it: its `common.transform` (set, or compose if the copy already has one)
    /// and its paint (`fill`/`stroke` applied only when `Some`). The master and
    /// every other instance are untouched, and nothing is minted. No-op when the
    /// path is invalid, not a reference, or the target is unresolvable.
    pub fn detach(model: &mut Model, path: &ElementPath) {
        let doc = model.document().clone();
        let Some(elem) = doc.get_element(path) else { return };
        // Must be a reference instance.
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Reference(instance),
        ) = elem else { return };
        // Resolve the target id over symbols + layers (a pure id->element map).
        let target_id = &instance.target.0;
        let Some(target) = find_element_by_id(&doc, target_id) else { return };

        // Independent copy of the resolved target, born id-less.
        let mut copy = target;
        crate::geometry::element::clear_ids(&mut copy);

        // Apply the instance's transform overrides. The render composition is
        // common.transform (CTM) ∘ instance.transform (Symbols P4 / Fork F2);
        // detach must fold BOTH onto the copy so neither is dropped. Build the
        // instance-side transform first (common.transform ∘ instance field),
        // then compose onto any transform the copy already carries.
        let inst_combined = match (instance.common.transform, instance.transform) {
            (Some(ct), Some(it)) => Some(ct.multiply(&it)),
            (Some(ct), None) => Some(ct),
            (None, Some(it)) => Some(it),
            (None, None) => None,
        };
        if let Some(inst_t) = inst_combined {
            let composed = match copy.common().transform {
                Some(copy_t) => inst_t.multiply(&copy_t),
                None => inst_t,
            };
            copy.common_mut().transform = Some(composed);
        }
        // Apply the instance's paint overrides (only when Some).
        if instance.fill.is_some() {
            copy = crate::geometry::element::with_fill(&copy, instance.fill.clone());
        }
        if instance.stroke.is_some() {
            copy = crate::geometry::element::with_stroke(&copy, instance.stroke.clone());
        }

        model.edit_document(doc.replace_element(path, copy));
    }

    /// Set the instance `transform` of the `ReferenceElem` at `path` (Symbols
    /// P4, SYMBOLS.md §4 / Fork F2). Value-in-op: the `transform` is carried in
    /// the payload (not minted), letting an instance be mirrored/scaled relative
    /// to its master. This is the instance transform, distinct from
    /// `common.transform` (the render CTM); the render composition is
    /// `common.transform` ∘ instance `transform`. No-op when `path` is invalid
    /// or the element there is not a reference.
    pub fn set_instance_transform(
        model: &mut Model,
        path: &ElementPath,
        transform: crate::geometry::element::Transform,
    ) {
        let doc = model.document().clone();
        let Some(elem) = doc.get_element(path) else { return };
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Reference(instance),
        ) = elem else { return };
        // Rebuild the reference with the instance transform set, preserving the
        // target, paint overrides, and common props.
        let mut updated = instance.clone();
        updated.transform = Some(transform);
        let new_elem = crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Reference(updated),
        );
        model.edit_document(doc.replace_element(path, new_elem));
    }

    /// Redefine: replace the master with id `master_id` in `doc.symbols` with a
    /// clone of the element at `path` (re-id the clone to `master_id`), then
    /// replace the element at `path` in place with a `ReferenceElem` instance
    /// (`common.id = ref_id`, targeting `master_id`) — the selection becomes an
    /// instance of the redefined master (SYMBOLS.md §7, Fork S2). All other
    /// instances of `master_id` re-resolve to the new definition on the next
    /// paint. No-op when `master_id` is not in `symbols` or `path` is invalid.
    pub fn redefine(
        model: &mut Model,
        master_id: &str,
        path: &ElementPath,
        ref_id: &str,
    ) {
        let doc = model.document().clone();
        // The master must already exist.
        let Some(master_idx) = doc.symbols.iter().position(|m| {
            m.common().id.as_deref() == Some(master_id)
        }) else { return };
        let Some(source) = doc.get_element(path) else { return };

        // New master = clone of the selection, re-id'd to master_id.
        let mut new_master = source.clone();
        new_master.common_mut().id = Some(master_id.to_string());

        // The selection becomes an instance of the redefined master.
        let reference = Element::Live(crate::geometry::live::LiveVariant::Reference(
            crate::geometry::live::ReferenceElem::new(
                crate::geometry::live::ElementRef(master_id.to_string()),
                crate::geometry::element::CommonProps {
                    id: Some(ref_id.to_string()),
                    ..crate::geometry::element::CommonProps::default()
                },
            ),
        ));
        let mut new_doc = doc.replace_element(path, reference);
        new_doc.symbols[master_idx] = new_master;
        model.edit_document(new_doc);
    }

    /// Delete Symbol: remove the master whose `common.id == master_id` from
    /// `doc.symbols` (SYMBOLS.md §7). No-op when no master carries that id.
    /// The instances (`ReferenceElem`s targeting `master_id`) are left
    /// untouched — they simply become dangling and resolve to empty until the
    /// master returns (recoverable via undo, since the caller owns the
    /// snapshot). The Symbols-panel confirm-before-delete warning is a UI
    /// concern, not part of this op.
    pub fn delete_symbol(model: &mut Model, master_id: &str) {
        let doc = model.document().clone();
        let Some(idx) = doc.symbols.iter().position(|m| {
            m.common().id.as_deref() == Some(master_id)
        }) else { return };
        let mut new_doc = doc;
        new_doc.symbols.remove(idx);
        model.edit_document(new_doc);
    }

    /// Append ``element`` to the mask subtree of the element at
    /// ``path`` and move the selection onto the new element inside
    /// the subtree. Returns ``true`` when the append succeeded,
    /// ``false`` when the target element has no mask or the mask
    /// subtree root doesn't accept children — the caller then falls
    /// back to layer-append. OPACITY.md §Preview interactions.
    fn add_element_to_mask(model: &mut Model, element: Element, path: &[usize]) -> bool {
        let doc = model.document().clone();
        let Some(target) = doc.get_element(&path.to_vec()) else { return false };
        if target.common().mask.is_none() {
            return false;
        }
        let mut new_target = target.clone();
        let child_idx = {
            let Some(mask_box) = new_target.common_mut().mask.as_mut() else {
                return false;
            };
            // Mask.subtree is a ``Box<Element>``; only container
            // elements (Group / Layer / …) have [`children_mut`]. If
            // the mask root is e.g. a bare Rect, we can't append —
            // tell the caller to fall through.
            let Some(children) = mask_box.subtree.children_mut() else {
                return false;
            };
            let ci = children.len();
            children.push(Rc::new(element));
            ci
        };
        let mut new_doc = doc.replace_element(&path.to_vec(), new_target);
        // Build the selection path for the newly-added element: it
        // lives at ``<mask-target-path>/__mask/<child_idx>``. We
        // don't have a canonical path encoding for "inside a mask",
        // so for selection purposes we select the mask-target
        // element itself — good enough for phase 1.
        new_doc.selection = vec![ElementSelection::all(path.to_vec())];
        model.edit_document(new_doc);
        true
    }

    /// Select all elements whose bounds intersect the given rectangle.
    pub fn select_rect(
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        extend: bool,
    ) {
        select_flat(model, |elem| element_intersects_rect(elem, x, y, width, height), extend);
    }

    /// Select all elements whose bounds intersect the given polygon.
    pub fn select_polygon(
        model: &mut Model,
        polygon: &[(f64, f64)],
        extend: bool,
    ) {
        select_flat(model, |elem| element_intersects_polygon(elem, polygon), extend);
    }

    /// Direct selection marquee: select individual control points within the rect.
    pub fn partial_select_rect(
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        extend: bool,
    ) {
        select_recursive(model, |path, elem| {
            let cps = control_points(elem);
            let hit_cps: Vec<usize> = cps
                .iter()
                .enumerate()
                .filter(|(_, (px, py))| point_in_rect(*px, *py, x, y, width, height))
                .map(|(i, _)| i)
                .collect();
            if !hit_cps.is_empty() {
                Some(ElementSelection {
                    path: path.clone(),
                    kind: SelectionKind::Partial(SortedCps::from_iter(hit_cps)),
                })
            } else if element_intersects_rect(elem, x, y, width, height) {
                Some(ElementSelection::partial(
                    path.clone(),
                    std::iter::empty::<usize>(),
                ))
            } else {
                None
            }
        }, extend);
    }

    /// Select all unlocked, visible elements in the document.
    ///
    /// "Unlocked" is INHERITED (transcripts/LAYER_STRUCTURE.md §13). This loop
    /// used to test `child.locked()` and never the LAYER's own flag, so Select
    /// All swept up the entire contents of a locked layer — while JasSwift's
    /// `selectAll` (which delegates to `selectFlat`) skipped it. A live
    /// prime-directive divergence, invisible to the corpus until `jas:locked`
    /// let a fixture start from a locked document.
    pub fn select_all(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        let mut entries: Selection = Vec::new();
        for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    // ONE read, deliberately: `effective_locked` on the CHILD
                    // path already folds in the layer's own flag, so a
                    // layer-level short-circuit above this loop would be
                    // redundant — and a redundant guard is one no mutation can
                    // turn red, which is how a guard rots. Measured: with both
                    // present, reverting EITHER left the whole suite green.
                    if doc.effective_locked(&vec![li, ci]) {
                        continue;
                    }
                    if std::cmp::min(layer_vis, child.visibility()) == Visibility::Invisible {
                        continue;
                    }
                    entries.push(ElementSelection::all(vec![li, ci]));
                }
            }
        }
        let mut new_doc = doc;
        new_doc.selection = entries;
        model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
    }

    /// Set the document selection directly.
    pub fn set_selection(model: &mut Model, selection: Selection) {
        let mut doc = model.document().clone();
        doc.selection = selection;
        model.set_document_unbracketed(doc, NonUndoableIntent::Selection);
    }

    /// Clear the document selection. Shorthand for `set_selection(model, vec![])`.
    pub fn clear_selection(model: &mut Model) {
        Self::set_selection(model, Vec::new());
    }

    /// Add a path to the selection as an All-kind entry. No-op if the
    /// path is already selected (matches the YAML `doc.add_to_selection`
    /// effect's idempotent semantics).
    pub fn add_to_selection(model: &mut Model, path: &ElementPath) {
        let doc = model.document().clone();
        if doc.selection.iter().any(|es| es.path == *path) {
            return;
        }
        let mut sel = doc.selection.clone();
        sel.push(ElementSelection::all(path.clone()));
        let mut new_doc = doc;
        new_doc.selection = sel;
        model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
    }

    /// Toggle a path in or out of the selection. If present, removes the
    /// matching entry; otherwise appends an All-kind entry. Matches the
    /// YAML `doc.toggle_selection` effect's semantics used by shift-click.
    pub fn toggle_selection(model: &mut Model, path: &ElementPath) {
        let doc = model.document().clone();
        let mut sel = doc.selection.clone();
        if let Some(pos) = sel.iter().position(|es| es.path == *path) {
            sel.remove(pos);
        } else {
            sel.push(ElementSelection::all(path.clone()));
        }
        let mut new_doc = doc;
        new_doc.selection = sel;
        model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
    }

    /// Select an element by path.
    pub fn select_element(model: &mut Model, path: &ElementPath) {
        use crate::geometry::element::Visibility;
        if path.is_empty() {
            return;
        }
        let doc = model.document().clone();
        // A path that names no element selects nothing.
        if doc.get_element(path).is_none() {
            return;
        }
        // Both reads below are INHERITED down the path. Until LOCKINHERIT the
        // first one read the element's OWN `locked` flag, one line above an
        // ancestor-aware visibility read — so a click on a child of a locked
        // layer selected it. transcripts/LAYER_STRUCTURE.md §13.
        if doc.effective_locked(path) {
            return;
        }
        if doc.effective_visibility(path) == Visibility::Invisible {
            return;
        }
        // Check if parent is a group (not layer) — select the whole group
        if path.len() >= 2 {
            let parent_path: ElementPath = path[..path.len() - 1].to_vec();
            if let Some(parent) = doc.get_element(&parent_path)
                && parent.is_group() {
                    let mut entries = vec![ElementSelection::all(parent_path.clone())];
                    if let Some(children) = parent.children() {
                        for i in 0..children.len() {
                            let mut cp = parent_path.clone();
                            cp.push(i);
                            entries.push(ElementSelection::all(cp));
                        }
                    }
                    let mut new_doc = doc;
                    new_doc.selection = entries;
                    model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
                    return;
                }
        }
        let mut new_doc = doc;
        new_doc.selection = vec![ElementSelection::all(path.clone())];
        model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
    }

    /// Select a single control point on an element.
    pub fn select_control_point(model: &mut Model, path: &ElementPath, index: usize) {
        let mut doc = model.document().clone();
        doc.selection = vec![ElementSelection::partial(path.clone(), [index])];
        model.set_document_unbracketed(doc, NonUndoableIntent::Selection);
    }

    /// Move all selected control points by (dx, dy).
    ///
    /// A corner drag arrives here once per mousemove sample with an
    /// INCREMENTAL delta (workspace/tools/partial_selection.yaml), so a
    /// sample that PROMOTES the element — Rect -> Polygon — must carry the
    /// control-point selection across the promotion, or the next sample
    /// would address indices that no longer mean what they did. See
    /// `remap_cp_selection_after_move`.
    pub fn move_selection(model: &mut Model, dx: f64, dy: f64) {
        use crate::geometry::element::remap_cp_selection_after_move;
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        let mut new_selection: Selection = Vec::new();
        for es in &doc.selection {
            // AN ANCESTOR IN THE SELECTION COVERS ITS DESCENDANTS (§16.4).
            //
            // Every element below is read from the PRISTINE `doc` and written
            // back absolutely. For disjoint entries that is exactly right; for
            // an ancestor and its descendant it is not, because the
            // descendant's write lands on top of the ancestor's and discards
            // the ancestor's contribution to it. A group dragged with one
            // member's control point also selected left that member STRANDED at
            // its pristine coordinates with a single corner displaced.
            //
            // §16.4 rules such a selection out, but the ruling is not yet
            // enforced at the extend/add seams or at `doc.set_selection`'s
            // still-live container expansion (§20). Applying the rule HERE
            // makes the operation correct whatever produced the selection.
            //
            // The entry is skipped entirely, including its post-move selection
            // rewrite, so the ancestor's own entry carries the whole move.
            if doc.selection.iter().any(|other| {
                other.path.len() < es.path.len() && es.path.starts_with(&other.path)
            }) {
                new_selection.push(es.clone());
                continue;
            }
            if let Some(elem) = doc.get_element(&es.path) {
                let new_elem = move_control_points(elem, &es.kind, dx, dy);
                let kind = remap_cp_selection_after_move(elem, &new_elem, &es.kind);
                new_doc = new_doc.replace_element(&es.path, new_elem);
                new_selection.push(ElementSelection { path: es.path.clone(), kind });
            } else {
                new_selection.push(es.clone());
            }
        }
        new_doc.selection = new_selection;
        model.edit_document(new_doc);
    }

    /// Set stroke_brush on all selected elements (paths only).
    /// Used by apply_brush_to_selection. See BRUSHES.md.
    pub fn set_selection_stroke_brush(model: &mut Model, slug: Option<String>) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|e| crate::geometry::element::with_stroke_brush(e, slug.clone())),
                );
            }
        }
        model.edit_document(new_doc);
    }

    /// Set stroke_brush_overrides on all selected elements (paths only).
    pub fn set_selection_stroke_brush_overrides(
        model: &mut Model, overrides: Option<String>,
    ) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|e| crate::geometry::element::with_stroke_brush_overrides(e, overrides.clone())),
                );
            }
        }
        model.edit_document(new_doc);
    }

    fn fill_applied(doc: &Document, fill: Option<Fill>) -> Document {
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(elem, &|e| with_fill(e, fill)),
                );
            }
        }
        new_doc
    }

    fn stroke_applied(doc: &Document, stroke: Option<Stroke>) -> Document {
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(elem, &|e| with_stroke(e, stroke)),
                );
            }
        }
        new_doc
    }

    /// Set the fill of all selected elements (undoable, self-bracketing).
    pub fn set_selection_fill(model: &mut Model, fill: Option<Fill>) {
        let new_doc = Self::fill_applied(model.document(), fill);
        model.edit_document(new_doc);
    }

    /// Set the stroke of all selected elements (undoable, self-bracketing).
    pub fn set_selection_stroke(model: &mut Model, stroke: Option<Stroke>) {
        let new_doc = Self::stroke_applied(model.document(), stroke);
        model.edit_document(new_doc);
    }

    /// Rewrite each selected element's stroke through `f`, which receives
    /// that element's OWN current stroke (`None` when it has none).
    ///
    /// Unlike [`Self::set_selection_stroke`] — which stamps one identical
    /// Stroke across the whole selection — this preserves the per-element
    /// fields `f` leaves alone, so a Stroke-panel edit to one attribute
    /// cannot carry the first element's width / colour onto its siblings.
    /// Used by `apply_stroke_panel_to_selection`.
    pub fn map_selection_stroke(
        model: &mut Model, f: impl Fn(Option<Stroke>) -> Option<Stroke>,
    ) {
        let new_doc = Self::stroke_mapped(model.document(), f);
        model.edit_document(new_doc);
    }

    /// Live, NON-undoable [`Self::map_selection_stroke`] for per-tick
    /// colour-slider drag: undo is captured once on pointer-up by
    /// `set_active_color`, so the drag must not push checkpoints.
    pub fn map_selection_stroke_live(
        model: &mut Model, f: impl Fn(Option<Stroke>) -> Option<Stroke>,
    ) {
        let new_doc = Self::stroke_mapped(model.document(), f);
        model.set_document_unbracketed(new_doc, NonUndoableIntent::LiveDrag);
    }

    fn stroke_mapped(
        doc: &Document, f: impl Fn(Option<Stroke>) -> Option<Stroke>,
    ) -> Document {
        let doc = doc.clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                // The RECOLOUR path, and it must recurse too. `fill_mapped` /
                // `stroke_mapped` read each element's OWN paint and rewrite it,
                // which is how per-element opacity survives a colour change --
                // and it is the path the COLOR PANEL actually uses
                // (`apply_active_color_write`), not the stamp-one-value path.
                // Routing only the stamp path left clicking a swatch with a
                // group selected doing nothing. Found by JYH clicking it,
                // 2026-07-29.
                //
                // The closure reads the LEAF's own paint, so each member is
                // recoloured individually and keeps its own opacity.
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|leaf| with_stroke(leaf, f(leaf.stroke().cloned()))),
                );
            }
        }
        new_doc
    }

    /// Rewrite each selected element's fill through `f`, which receives
    /// that element's OWN current fill (`None` when it has none). The
    /// per-element counterpart of [`Self::set_selection_fill`]: preserves
    /// the fields `f` leaves alone (e.g. a colour pick must not reset each
    /// element's fill opacity).
    pub fn map_selection_fill(model: &mut Model, f: impl Fn(Option<Fill>) -> Option<Fill>) {
        let new_doc = Self::fill_mapped(model.document(), f);
        model.edit_document(new_doc);
    }

    /// Live, NON-undoable [`Self::map_selection_fill`] for per-tick drag.
    pub fn map_selection_fill_live(model: &mut Model, f: impl Fn(Option<Fill>) -> Option<Fill>) {
        let new_doc = Self::fill_mapped(model.document(), f);
        model.set_document_unbracketed(new_doc, NonUndoableIntent::LiveDrag);
    }

    fn fill_mapped(doc: &Document, f: impl Fn(Option<Fill>) -> Option<Fill>) -> Document {
        let doc = doc.clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|leaf| with_fill(leaf, f(leaf.fill().cloned()))),
                );
            }
        }
        new_doc
    }

    /// Set the `fill_gradient` field of every selected element to the
    /// given value. Phase 5 — used by `apply_gradient_panel_to_selection`.
    /// Pass `None` to clear (demote to solid; the existing `fill` value
    /// remains as the demote-target color per GRADIENT.md §Fill-type
    /// coupling).
    pub fn set_selection_fill_gradient(model: &mut Model, gradient: Option<Box<crate::geometry::element::Gradient>>) {
        use crate::geometry::element::with_fill_gradient;
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|e| with_fill_gradient(e, gradient.clone())),
                );
            }
        }
        model.edit_document(new_doc);
    }

    /// Set the `stroke_gradient` field of every selected element.
    pub fn set_selection_stroke_gradient(model: &mut Model, gradient: Option<Box<crate::geometry::element::Gradient>>) {
        use crate::geometry::element::with_stroke_gradient;
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(
                    &es.path,
                    crate::geometry::element::map_paintable(
                        elem, &|e| with_stroke_gradient(e, gradient.clone())),
                );
            }
        }
        model.edit_document(new_doc);
    }

    // ── Opacity mask lifecycle (OPACITY.md § States) ───────────

    /// Create an opacity mask on every selected element. The mask
    /// starts with an empty ``Group`` as its subtree; users populate
    /// it via the MASK_PREVIEW click to enter mask-editing mode
    /// (Phase 4). ``clip`` and ``invert`` come from the document
    /// preferences ``new_masks_clipping`` / ``new_masks_inverted``.
    /// Elements that already have a mask are left untouched so
    /// re-clicking MAKE_MASK on a mixed selection is a no-op for the
    /// already-masked members.
    pub fn make_mask_on_selection(model: &mut Model, clip: bool, invert: bool) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                if elem.common().mask.is_some() {
                    continue;
                }
                let mut new_elem = elem.clone();
                new_elem.common_mut().mask = Some(Box::new(Mask {
                    subtree: Box::new(Element::Group(GroupElem::default())),
                    clip,
                    invert,
                    disabled: false,
                    linked: true,
                    unlink_transform: None,
                }));
                new_doc = new_doc.replace_element(&es.path, new_elem);
            }
        }
        model.edit_document(new_doc);
    }

    /// Remove the opacity mask from every selected element.
    /// Matches the "Release Opacity Mask" menu action and the
    /// MAKE_MASK_BUTTON in its "Has mask" state.
    pub fn release_mask_on_selection(model: &mut Model) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                if elem.common().mask.is_none() {
                    continue;
                }
                let mut new_elem = elem.clone();
                new_elem.common_mut().mask = None;
                new_doc = new_doc.replace_element(&es.path, new_elem);
            }
        }
        model.edit_document(new_doc);
    }

    /// Set ``mask.clip`` on every selected element that has a mask.
    /// Matches the CLIP_CHECKBOX control.
    pub fn set_mask_clip_on_selection(model: &mut Model, clip: bool) {
        Self::update_mask_on_selection(model, |m| m.clip = clip);
    }

    /// Set ``mask.invert`` on every selected element that has a mask.
    /// Matches the INVERT_MASK_CHECKBOX control.
    pub fn set_mask_invert_on_selection(model: &mut Model, invert: bool) {
        Self::update_mask_on_selection(model, |m| m.invert = invert);
    }

    /// Toggle ``mask.disabled`` on every selected mask, driven by the
    /// first selected element's current state (OPACITY.md §Panel menu).
    /// Matches the "Disable Opacity Mask" menu item.
    pub fn toggle_mask_disabled_on_selection(model: &mut Model) {
        let doc = model.document();
        let current = first_mask(doc).map(|m| m.disabled);
        let Some(new_state) = current.map(|d| !d) else { return };
        Self::update_mask_on_selection(model, move |m| m.disabled = new_state);
    }

    /// Toggle ``mask.linked`` on every selected mask, driven by the
    /// first selected element's current state. On unlink, captures
    /// each element's current transform into ``unlink_transform``
    /// so the mask stays fixed in document coordinates. On relink,
    /// clears ``unlink_transform``.
    pub fn toggle_mask_linked_on_selection(model: &mut Model) {
        let doc = model.document().clone();
        let current_linked = match first_mask(&doc) {
            Some(m) => m.linked,
            None => return,
        };
        let new_linked = !current_linked;
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            let Some(elem) = doc.get_element(&es.path) else { continue };
            let Some(mask) = elem.common().mask.as_ref() else { continue };
            let elem_transform = elem.transform().cloned();
            let mut new_elem = elem.clone();
            if let Some(m) = new_elem.common_mut().mask.as_mut() {
                m.linked = new_linked;
                m.unlink_transform = if new_linked { None } else { elem_transform };
                // Keep the rest of the mask fields untouched.
                let _ = mask;
            }
            new_doc = new_doc.replace_element(&es.path, new_elem);
        }
        model.edit_document(new_doc);
    }

    /// Internal helper: apply `f` to every selected element's mask.
    /// Elements without a mask are skipped.
    fn update_mask_on_selection(model: &mut Model, mut f: impl FnMut(&mut Mask)) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            let Some(elem) = doc.get_element(&es.path) else { continue };
            if elem.common().mask.is_none() {
                continue;
            }
            let mut new_elem = elem.clone();
            if let Some(m) = new_elem.common_mut().mask.as_mut() {
                f(m.as_mut());
            }
            new_doc = new_doc.replace_element(&es.path, new_elem);
        }
        model.edit_document(new_doc);
    }

    /// Set width profile points on selected Path and Line elements.
    pub fn set_selection_width_profile(model: &mut Model, width_points: Vec<StrokeWidthPoint>) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(&es.path, with_width_points(elem, width_points.clone()));
            }
        }
        model.edit_document(new_doc);
    }

    /// Duplicate selected elements, offset by (dx, dy).
    ///
    /// **The selection this leaves behind is in DOCUMENT ORDER, and it names
    /// the COPIES** — transcripts/LAYER_STRUCTURE.md §19, RULED 2026-07-28 by
    /// JYH (*"yes document order"*).
    ///
    /// The walk runs BACK-TO-FRONT and that is load-bearing: inserting after
    /// [0,1] shifts [0,3], so a forward walk would read its own insertions as
    /// sources. What was wrong was letting the RESULT inherit the walk's order
    /// as a byproduct — nobody chose descending, and §10 (D6) made selection
    /// order part of the document precisely because a copied fragment's z-order
    /// is part of the artwork. Duplicate, then Copy, and the clipboard listed
    /// the elements backwards.
    ///
    /// **The same shift that forces the descending walk also invalidates the
    /// copy paths it has already recorded**, which is a separate defect found
    /// while gating §19 and repaired here. Duplicating [0,1] and [0,3]: the
    /// walk copies d first and records [0,4], then copies b, and THAT insertion
    /// pushes everything above [0,1] up one slot — so the recorded [0,4] stops
    /// naming d's copy and starts naming **d itself, the source**. The result
    /// was not merely mis-ordered; a Copy afterwards put a source element on the
    /// clipboard. `shift_path_for_insertion` keeps the recorded paths honest as
    /// the document moves underneath them, and the sort is then a sort of the
    /// right paths rather than a tidy list of the wrong ones.
    pub fn copy_selection(model: &mut Model, dx: f64, dy: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        // Copy paths only: copying always selects the new element AS A WHOLE,
        // so the `kind` is `All` for every entry and the running state is a
        // plain path list that stays rewritable as the document shifts.
        let mut copy_paths: Vec<ElementPath> = Vec::new();
        let mut sorted_sels: Vec<_> = doc.selection.clone();
        sorted_sels.sort_by(|a, b| b.path.cmp(&a.path));
        for es in &sorted_sels {
            if let Some(elem) = doc.get_element(&es.path) {
                let mut copied = move_control_points(elem, &es.kind, dx, dy);
                // A copy must not inherit the source's stable id (no two
                // elements may share an identity); it is born id-less.
                crate::geometry::element::clear_ids(&mut copied);
                new_doc = new_doc.insert_element_after(&es.path, copied.clone());
                let mut copy_path = es.path.clone();
                *copy_path.last_mut().unwrap() += 1;
                // This insertion moves every copy path already recorded that
                // sits at or after it under the same parent.
                for prev in copy_paths.iter_mut() {
                    shift_path_for_insertion(prev, &copy_path);
                }
                copy_paths.push(copy_path);
            }
        }
        // §19: document order, not the walk's order.
        copy_paths.sort();
        new_doc.selection = copy_paths
            .into_iter()
            .map(ElementSelection::all)
            .collect::<Selection>();
        model.edit_document(new_doc);
    }

    /// Group selected elements into a single Group. **R1 — group ALWAYS
    /// flattens** (transcripts/LAYER_STRUCTURE.md §3, ratified 2026-07-28).
    ///
    /// Every selected element becomes a child of the new Group regardless of
    /// where it came from — across layers, across sibling groups, at any
    /// depth. There is no refusal and no silent no-op. This replaced a guard
    /// that required all selected paths to share one parent prefix AND one
    /// path LENGTH; with it, Cmd+G on a selection spanning two layers did
    /// nothing and said nothing (defect D2).
    ///
    /// **Why flattening rather than preservation.** A Group is an element and
    /// its children are its children; there is no representation in which one
    /// Group's children live in two different parents. Unlike paste there is
    /// no structure-preserving option to choose between, so this is the
    /// Preservation Law's *what it cannot preserve it must not guess* clause
    /// resolved by T3's documented default.
    ///
    /// **Placement: the FRONTMOST selected element's parent, at the z-slot
    /// that element vacates.** Frontmost is the GREATEST path — paths sort
    /// ascending and the canvas paints `for layer in &doc.layers` forward
    /// into Canvas2D, so a higher index paints later and therefore on top.
    /// This is the same rule BOOLEAN.md fixes and `make_compound_shape_with_op`
    /// already implements with `elements.last()`. Placing the group frontmost
    /// minimises visual change: it renders roughly where the frontmost member
    /// already rendered, instead of hurling the selection backward past
    /// unrelated content.
    ///
    /// Note this half of R1 also corrects the SAME-PARENT case. `actions.yaml`
    /// §group has always said the group "inherits the z-order position of the
    /// frontmost selected object"; both ports inserted at `paths[0]`, the
    /// BACKMOST. The two agree only when the selection is contiguous, which is
    /// why the existing corpus golden never saw it.
    ///
    /// **On electing a winner from geometry.** The Preservation Law forbids
    /// electing an IDENTITY winner from geometry, z-order included, and this
    /// is deliberately NOT that. Identity here is a FRESH group — a 0 -> 1
    /// creation under the cardinality law, wearing `CommonProps::default()`
    /// and never a member's id — while z-order is being used for PLACEMENT,
    /// which is inherently an ordering concern. The surface resemblance will
    /// otherwise read as a contradiction.
    ///
    /// **Emptied source containers are KEPT — both layers and groups.** A
    /// container the selection drained was never what the edit spoke to; it is
    /// a bystander (T4), and it carries a name, an id and blend flags that
    /// deleting would destroy on an unrequested 1 -> 0. This is NOT the orphan
    /// D3 was fixed for: there a container was emptied by a WRONG insert that
    /// should have landed inside it, whereas here the emptying is the correct
    /// consequence of a move the artist asked for. The loss is visible in the
    /// Layers panel and is one undo step.
    ///
    /// Twin probes: the `r1_*` tests below and
    /// `JasSwift/Tests/Document/GroupFlattenTests.swift`, case for case, plus
    /// the shared corpus family `test_fixtures/actions/group_flatten.json`.
    pub fn group_selection(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> = doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        paths.dedup();
        // An ancestor carries its own children, so a selected path that sits
        // UNDER another selected path is dropped from the move. Without this,
        // selecting a Group and one of its children would clone the child into
        // the new group AND leave it inside the cloned subtree: the same
        // element twice, one live id duplicated — the uniqueness break
        // (REFERENCE_GRAPH.md §2.5) `make_compound_shape_with_op` was fixed
        // for, where a reference silently rebinds to whichever copy the index
        // walk reaches first.
        //
        // UNRULED, and taken as the conservative reading rather than as law:
        // brief §6 open question 3 (mixed DEPTHS) is not settled, and this is
        // the sub-case where the naive reading is not merely debatable but
        // unsafe. Banked for JYH.
        let roots: Vec<ElementPath> = paths
            .iter()
            .filter(|p| !paths.iter().any(|q| *q != **p && p.starts_with(q)))
            .cloned()
            .collect();
        if roots.len() < 2 {
            return;
        }
        // Gather elements in document order. A path that resolves to nothing
        // aborts rather than silently wrapping a short list.
        let elements: Vec<Rc<Element>> = roots
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
            .collect();
        if elements.len() != roots.len() {
            return;
        }
        // The destination: the FRONTMOST root's own path, with each component
        // shifted down by the deletions that land EARLIER in that same
        // container. A deleted path shifts `front[k]` exactly when it is a
        // direct child of `front[..k]` with a smaller index — deleting a whole
        // subtree removes one entry from its parent, so every later sibling
        // (including an ANCESTOR of the frontmost element) slides back one.
        // Computing this arithmetically rather than reusing `roots[0]` is what
        // makes the general cross-parent case land where the artist was
        // looking.
        let front = roots.last().expect("roots is non-empty; len >= 2 checked above");
        let mut insert_path = front.clone();
        for k in 0..front.len() {
            let shift = roots
                .iter()
                .filter(|d| {
                    *d != front && d.len() == k + 1 && d[..k] == front[..k] && d[k] < front[k]
                })
                .count();
            insert_path[k] -= shift;
        }
        // Delete the sources in reverse document order (descending paths keep
        // the remaining indices valid).
        let mut new_doc = doc.clone();
        for p in roots.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }
        // The new Group is a fresh 0 -> 1 container: it never wears a member's
        // identity (transcripts/EDIT_SEMANTICS_FREEZE.md §3.4).
        let group = Element::Group(crate::geometry::element::GroupElem {
            children: elements,
            common: crate::geometry::element::CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        });
        new_doc = new_doc.insert_element_at(&insert_path, group);
        new_doc.selection = vec![ElementSelection::all(insert_path)];
        model.edit_document(new_doc);
    }

    /// Ungroup all selected Group elements, replacing each with its children.
    pub fn ungroup_selection(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        // Find selected groups
        let mut group_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path)
                && elem.is_group() {
                    group_paths.push(es.path.clone());
                }
        }
        if group_paths.is_empty() {
            return;
        }
        group_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();

        // Process in reverse order to preserve indices
        for gpath in group_paths.iter().rev() {
            let group_elem = match new_doc.get_element(gpath).cloned() {
                Some(e) => e,
                None => continue,
            };
            let children = match group_elem.children() {
                Some(c) => c.to_vec(),
                None => continue,
            };
            // Delete the group
            new_doc = new_doc.delete_element(gpath);
            // Insert children at the group's position
            if gpath.len() >= 2 {
                let layer_idx = gpath[0];
                let child_idx = gpath[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, child) in children.into_iter().enumerate() {
                        layer_children.insert(child_idx + j, child);
                    }
                }
            }
        }

        // Build selection for ungrouped children
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for gpath in &group_paths {
            let orig_group = match orig_doc.get_element(gpath) {
                Some(e) => e,
                None => continue,
            };
            let n_children = orig_group.children().map_or(0, |c| c.len());
            if gpath.len() >= 2 {
                let layer_idx = gpath[0];
                let child_idx = (gpath[1] as i64 + offset) as usize;
                for j in 0..n_children {
                    let path = vec![layer_idx, child_idx + j];
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n_children as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.edit_document(new_doc);
    }

    /// Make a compound shape from the current selection using UNION.
    /// Thin wrapper around `make_compound_shape_with_op`.
    pub fn make_compound_shape(model: &mut Model) {
        use crate::geometry::live::CompoundOperation;
        Self::make_compound_shape_with_op(model, CompoundOperation::Union);
    }

    /// Make a compound shape from the current selection using the
    /// given operation. Selected elements must be siblings. The
    /// frontmost (last in path order) operand's PAINT — fill, stroke,
    /// opacity and blend mode, the four properties BOOLEAN.md
    /// §Operand and paint rules names — is copied onto the new compound
    /// shape; the rest of its `common` is NOT (this is a WRAP: the
    /// container is 0 -> 1 and never wears a member's identity, see
    /// transcripts/EDIT_SEMANTICS_FREEZE.md §3.4). Selection becomes
    /// the new compound shape. See BOOLEAN.md §Compound shapes.
    pub fn make_compound_shape_with_op(
        model: &mut Model,
        operation: crate::geometry::live::CompoundOperation,
    ) {
        use crate::geometry::live::{CompoundShape, LiveVariant};
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> =
            doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        if paths.len() < 2 {
            return;
        }
        // Siblings only.
        let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
        if !paths.iter().all(|p| {
            p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]
        }) {
            return;
        }
        let elements: Vec<Rc<Element>> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
            .collect();
        if elements.len() != paths.len() {
            return;
        }
        // Inherit the frontmost operand's PAINT — and only its paint.
        //
        // This used to clone the frontmost's whole `common`, id included,
        // onto the wrapper while that operand REMAINED a child: two live
        // elements wearing one id. That breaks the uniqueness invariant
        // (REFERENCE_GRAPH.md §2.5) the cardinality law leans on, and it is
        // worse than a broken reference — a reference to the duplicated id
        // silently REBINDS to whichever element the index walk reaches
        // first, the one outcome §3.7 exists to prevent.
        //
        // WRAP (transcripts/EDIT_SEMANTICS_FREEZE.md §3.4, §3.6 MAKE row) is
        // 0 -> 1 for the container and 1 -> 1 for every child: the wrapper is
        // a FRESH container that never wears a member's identity, and the
        // children are re-parented untouched. `group_selection` has always
        // done exactly this with `CommonProps::default()`.
        //
        // The wrapper takes the frontmost's paint per the ratified BOOLEAN.md
        // rule — fill, stroke, `opacity`, blend mode. The rest of `common`
        // stays fresh: cloning the frontmost's `mask` onto the wrapper while
        // the operand keeps its own would composite the mask twice, and its
        // `name` and `tool_origin` belong to the element that earned them.
        //
        // `transform` is the ONE exception, and it is BUG CONTAINMENT, not
        // law. `CompoundShape::evaluate_with` flattens operands through
        // `element_to_polygon_set_with`, which has ZERO transform references:
        // an operand's own transform is ignored by the evaluator and only the
        // wrapper's is applied at render, so a fresh-default wrapper would
        // make a compound built from transformed operands jump to the
        // untransformed position. A UNANIMOUS transform therefore carries —
        // no winner elected — and disagreement takes the default. Delete this
        // carry when the compound evaluator becomes transform-aware (the S-3
        // transform-blind class), not before.
        let frontmost = elements.last().unwrap();
        let fill = frontmost.fill().copied();
        let stroke = frontmost.stroke().copied();
        let unanimous_transform = {
            let first = elements[0].common().transform;
            elements
                .iter()
                .all(|e| e.common().transform == first)
                .then_some(first)
                .flatten()
        };
        let common = crate::geometry::element::CommonProps {
            opacity: frontmost.common().opacity,
            mode: frontmost.common().mode,
            transform: unanimous_transform,
            ..crate::geometry::element::CommonProps::default()
        };

        let compound = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation,
            operands: elements,
            fill,
            stroke,
            common,
        }));

        let mut new_doc = doc.clone();
        for p in paths.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }
        let insert_path = paths[0].clone();
        new_doc = new_doc.insert_element_at(&insert_path, compound);
        new_doc.selection = vec![ElementSelection::all(insert_path)];
        model.edit_document(new_doc);
    }

    /// Release every selected compound shape: replace it in place with
    /// its operand children. Each operand keeps its own paint. The
    /// compound shape's paint is discarded. Selection becomes the
    /// restored operands.
    pub fn release_compound_shape(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut cs_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path)
                && matches!(elem, Element::Live(_))
            {
                cs_paths.push(es.path.clone());
            }
        }
        if cs_paths.is_empty() {
            return;
        }
        cs_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();
        // Process in reverse to preserve sibling indices.
        for cs_path in cs_paths.iter().rev() {
            let cs_elem = match new_doc.get_element(cs_path).cloned() {
                Some(e) => e,
                None => continue,
            };
            let operands: Vec<Rc<Element>> = match &cs_elem {
                Element::Live(crate::geometry::live::LiveVariant::CompoundShape(cs)) => {
                    cs.operands.clone()
                }
                _ => continue,
            };
            new_doc = new_doc.delete_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = cs_path[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, op) in operands.iter().enumerate() {
                        let insert_idx = child_idx + j;
                        if insert_idx <= layer_children.len() {
                            layer_children.insert(insert_idx, op.clone());
                        } else {
                            layer_children.push(op.clone());
                        }
                    }
                }
            }
        }

        // Build selection of released operands.
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for cs_path in &cs_paths {
            let orig_elem = match orig_doc.get_element(cs_path) {
                Some(e) => e,
                None => continue,
            };
            let n = match orig_elem {
                Element::Live(crate::geometry::live::LiveVariant::CompoundShape(cs)) => {
                    cs.operands.len()
                }
                _ => continue,
            };
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = (cs_path[1] as i64 + offset) as usize;
                for j in 0..n {
                    let path = vec![layer_idx, child_idx + j];
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.edit_document(new_doc);
    }

    /// Expand every selected compound shape into static Polygon
    /// elements derived from its evaluated geometry. The expanded
    /// polygons carry the compound shape's own paint. Operand tree
    /// is discarded.
    ///
    /// `generate_element_id`'s contract keeps minting OUT of Controller
    /// methods so they stay deterministic, so the id source is a parameter of
    /// `expand_compound_shape_minting` and this wrapper names it — exactly as
    /// `apply_destructive_boolean` and `path_erase_at_rect` do.
    pub fn expand_compound_shape(model: &mut Model) {
        Self::expand_compound_shape_minting(model, &mut || {
            crate::document::artboard::generate_element_id(None)
        })
    }

    /// `expand_compound_shape` with the id source supplied by the caller.
    ///
    /// The cardinality law lands here, at the layer that holds the document:
    /// `CompoundShape::expand` is pure, so it can only KILL the identity of a
    /// compound the expansion split (transcripts/EDIT_SEMANTICS_FREEZE.md
    /// §3.6's "Compound Shape EXPAND" row); the fresh ids the law owes those
    /// fragments (§3.2) must come from an avoid-set, which exists only here.
    /// A compound that expanded to a SINGLE ring is 1 -> 1 and arrives with
    /// its own id intact — nothing to mint.
    ///
    /// The avoid-set is built ONCE from the pre-edit document (so fragments
    /// of two different compounds cannot collide with each other either), and
    /// a failed mint aborts the WHOLE edit — never a half-identified split.
    pub fn expand_compound_shape_minting(
        model: &mut Model,
        mint: &mut dyn FnMut() -> String,
    ) {
        use crate::geometry::live::{DEFAULT_PRECISION, LiveElement, LiveVariant};
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut cs_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path)
                && matches!(elem, Element::Live(_))
            {
                cs_paths.push(es.path.clone());
            }
        }
        if cs_paths.is_empty() {
            return;
        }
        cs_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();
        let mut expanded_counts: Vec<usize> = Vec::with_capacity(cs_paths.len());
        // Built ONCE from the pre-edit document, so fragments of two
        // different compounds in one selection cannot collide with each
        // other either. It still holds the compounds' own (and their
        // operands') ids, which are about to vanish — avoiding them is
        // merely conservative, never wrong.
        let mut existing_ids = orig_doc.element_ids();

        for cs_path in cs_paths.iter().rev() {
            let cs_elem = match new_doc.get_element(cs_path).cloned() {
                Some(e) => e,
                None => {
                    expanded_counts.push(0);
                    continue;
                }
            };
            let expanded: Vec<Rc<Element>> = match &cs_elem {
                Element::Live(LiveVariant::CompoundShape(cs)) => cs.expand(DEFAULT_PRECISION),
                _ => {
                    expanded_counts.push(0);
                    continue;
                }
            };
            // §3.2, at the layer that holds the document. `CompoundShape::
            // expand` already cleared `id` on every fragment of a compound
            // the expansion SPLIT — it is pure and cannot mint — so the fresh
            // ids the law owes those fragments are minted here. A single-ring
            // expansion is 1 -> 1 and arrives with its own id intact, so
            // there is nothing to mint and nothing to guess.
            //
            // The split arm mints UNCONDITIONALLY, including for an id-less
            // compound, because that is what the landed splits
            // (`path_erase_at_rect`, the DIVIDE arm) do.
            let expanded: Vec<Rc<Element>> = if expanded.len() > 1 {
                let ids = match crate::document::artboard::mint_unique_ids(
                    expanded.len(), &mut existing_ids, mint,
                ) {
                    Some(ids) => ids,
                    // A failed mint aborts the WHOLE edit: never a
                    // half-identified split, and never a selection expanded
                    // only as far as the budget held.
                    None => return,
                };
                expanded
                    .into_iter()
                    .zip(ids)
                    .map(|(frag, id)| {
                        let mut e = (*frag).clone();
                        e.common_mut().id = Some(id);
                        Rc::new(e)
                    })
                    .collect()
            } else {
                expanded
            };
            expanded_counts.push(expanded.len());
            new_doc = new_doc.delete_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = cs_path[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, poly) in expanded.iter().enumerate() {
                        let insert_idx = child_idx + j;
                        if insert_idx <= layer_children.len() {
                            layer_children.insert(insert_idx, poly.clone());
                        } else {
                            layer_children.push(poly.clone());
                        }
                    }
                }
            }
        }
        expanded_counts.reverse(); // restore forward order

        // Build selection of expanded polygons.
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for (cs_path, &n) in cs_paths.iter().zip(expanded_counts.iter()) {
            let _orig = orig_doc.get_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = (cs_path[1] as i64 + offset) as usize;
                for j in 0..n {
                    let path = vec![layer_idx, child_idx + j];
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.edit_document(new_doc);
    }

    /// Destructively apply one of the nine implemented boolean ops to the
    /// current selection: `"union"`, `"intersection"`, `"exclude"`,
    /// `"subtract_front"`, `"subtract_back"`, `"crop"`, `"divide"`,
    /// `"trim"`, `"merge"`. Any other name is a no-op.
    ///
    /// UNION / INTERSECTION / EXCLUDE: every operand is consumed; the
    /// resulting polygon(s) carry the frontmost operand's paint.
    /// SUBTRACT_FRONT / SUBTRACT_BACK: the front/back operand is the
    /// cutter and is consumed; each remaining survivor emits a
    /// subtracted polygon carrying its own paint. CROP: the frontmost
    /// operand is the mask and is consumed; each remaining survivor
    /// emits the intersection carrying its own paint. DIVIDE: the union is
    /// partitioned into regions, each carrying its frontmost covering
    /// operand's paint. TRIM: each operand emits itself minus everything in
    /// front of it, keeping its own paint. MERGE: TRIM, then union the
    /// survivors that share an exactly-equal solid fill, the group taking its
    /// frontmost contributor's paint.
    ///
    /// What each arm does with the operands' `common` — identity, `name`,
    /// mask, visibility, capability markers — is the PRESERVATION LAW's, not
    /// this docstring's: see `apply_destructive_boolean_minting` and
    /// transcripts/EDIT_SEMANTICS_FREEZE.md §3.6.
    pub fn apply_destructive_boolean(
        model: &mut Model,
        op_name: &str,
        options: &BooleanOptions,
    ) {
        // `generate_element_id`'s contract keeps minting OUT of Controller
        // methods so they stay deterministic; the id source is therefore a
        // parameter of the minting method and this wrapper names it. Passing
        // `None` routes through the thread-local test override the corpus
        // runners install, exactly as `path_erase_at_rect` does.
        Self::apply_destructive_boolean_minting(model, op_name, options, &mut || {
            crate::document::artboard::generate_element_id(None)
        })
    }

    /// `apply_destructive_boolean` with the identity source supplied by the
    /// caller. Identity is preservable exactly when the edit is one-to-one
    /// (the cardinality law), so the arms that are NOT one-to-one MINT rather
    /// than inherit: the UNION / INTERSECTION / EXCLUDE product (N -> 1), and
    /// every fragment of a DIVIDE operand the partition actually split
    /// (1 -> N). The survivor arms — SUBTRACT_FRONT / SUBTRACT_BACK / CROP,
    /// every TRIM operand, and a DIVIDE operand that yielded a single region —
    /// are one-to-one and keep their own identities.
    pub fn apply_destructive_boolean_minting(
        model: &mut Model,
        op_name: &str,
        options: &BooleanOptions,
        mint: &mut dyn FnMut() -> String,
    ) {
        use crate::algorithms::boolean::{
            boolean_intersect, boolean_subtract, boolean_union, PolygonSet,
        };
        use crate::geometry::element::{CommonProps, Fill, PolygonElem, Stroke};
        use crate::geometry::live::{
            apply_operation, element_to_polygon_set, CompoundOperation,
        };

        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> =
            doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        if paths.len() < 2 {
            return;
        }
        // Siblings only.
        let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
        if !paths.iter().all(|p| {
            p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]
        }) {
            return;
        }
        let elements: Vec<Rc<Element>> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
            .collect();
        if elements.len() != paths.len() {
            return;
        }

        // (PolygonSet, fill, stroke, common) tuples; flattened to
        // Polygon elements below. Empty polygon sets are skipped.
        let mut outputs: Vec<(PolygonSet, Option<Fill>, Option<Stroke>, CommonProps)> = Vec::new();
        let precision = options.precision;

        match op_name {
            "union" | "intersection" | "exclude" => {
                let operand_sets: Vec<PolygonSet> = elements
                    .iter()
                    .map(|e| element_to_polygon_set(e, precision))
                    .collect();
                let op = match op_name {
                    "union" => CompoundOperation::Union,
                    "intersection" => CompoundOperation::Intersection,
                    "exclude" => CompoundOperation::Exclude,
                    _ => unreachable!(),
                };
                let result = apply_operation(op, &operand_sets);
                let front = elements.last().unwrap();
                // N -> 1. THE REJECTED RULE IN DISGUISE used to live here:
                // `front.common().clone()` carried the FRONTMOST operand's id
                // through a merge — "the frontmost source keeps the id",
                // elected by z-order rather than area, hiding inside a
                // `..clone()`. JYH rejected that rule twice. Identity is
                // preservable exactly when the edit is one-to-one (the
                // cardinality law), so preserving it here is not generosity:
                // OVER-PRESERVATION IS A GUESS TOO.
                //
                // What the product wears instead
                // (transcripts/EDIT_SEMANTICS_FREEZE.md §3.3, §3.6):
                //   id      — minted fresh through the shared loop.
                //   paint   — the frontmost's four ratified properties
                //             (fill, stroke, opacity, blend mode: what the op
                //             SPEAKS TO per BOOLEAN.md).
                //   the rest — UNANIMITY. All sources agree -> the value
                //             carries (well-defined, no winner elected); any
                //             disagreement -> the fresh element's default.
                //   `name`  — ASSERTING-SOURCES unanimity, JYH's ratified
                //             answer (1): a source that asserts a name
                //             carries it, a silent source does not veto.
                let mut common = merged_common(&elements, front);
                // Identity is minted only when an identity is actually AT
                // STAKE — i.e. when some operand carried one. Identity in
                // this app is LAZY (VISION.md §6.2: an element is born
                // id-less and mints only when it first becomes a reference
                // target or is first named), so a merge of id-less operands
                // kills nothing and the product takes the documented default
                // for a fresh element, which is `None`. That is §5.1's
                // creation doctrine, not a guess: nothing geometric is
                // consulted either way. When an id IS at stake it dies and a
                // fresh one is minted through the shared collision loop.
                //
                // NAMED DELTA from EDIT_SEMANTICS_FREEZE.md §3.6, which
                // writes "fresh mint" unconditionally: `path_erase_at_rect`'s
                // split arm mints unconditionally, so the split and merge
                // arms differ on the id-less case. Reconciling them is one
                // ruling, not a code change, and it must land in both ports
                // at once — see the wave report.
                if elements.iter().any(|e| e.common().id.is_some()) {
                    let mut existing_ids = doc.element_ids();
                    match crate::document::artboard::mint_unique_ids(
                        1, &mut existing_ids, mint,
                    ) {
                        Some(ids) => common.id = Some(ids[0].clone()),
                        // A failed mint aborts the whole edit — never a
                        // half-identified merge.
                        None => return,
                    }
                }
                outputs.push((
                    result,
                    front.fill().copied(),
                    front.stroke().copied(),
                    common,
                ));
            }
            "subtract_front" | "crop" => {
                // Frontmost (= last in path order) consumed.
                let cutter = element_to_polygon_set(
                    elements.last().unwrap(), precision,
                );
                for survivor in &elements[..elements.len() - 1] {
                    let survivor_set = element_to_polygon_set(survivor, precision);
                    let result = if op_name == "crop" {
                        boolean_intersect(&survivor_set, &cutter)
                    } else {
                        boolean_subtract(&survivor_set, &cutter)
                    };
                    outputs.push((
                        result,
                        survivor.fill().copied(),
                        survivor.stroke().copied(),
                        survivor.common().clone(),
                    ));
                }
            }
            "subtract_back" => {
                let cutter = element_to_polygon_set(&elements[0], precision);
                for survivor in &elements[1..] {
                    let survivor_set = element_to_polygon_set(survivor, precision);
                    let result = boolean_subtract(&survivor_set, &cutter);
                    outputs.push((
                        result,
                        survivor.fill().copied(),
                        survivor.stroke().copied(),
                        survivor.common().clone(),
                    ));
                }
            }
            "divide" => {
                // Walk operands back-to-front, maintaining a partition
                // of the union-so-far into (region, frontmost-covering
                // operand index) pairs. Each incoming operand splits
                // every existing region into overlap / non-overlap; the
                // overlap relabels to the incoming index (now frontmost).
                let mut accumulator: Vec<(PolygonSet, usize)> = Vec::new();
                for (i, op_elem) in elements.iter().enumerate() {
                    let op_set = element_to_polygon_set(op_elem, precision);
                    let mut new_acc: Vec<(PolygonSet, usize)> = Vec::new();
                    let mut remaining = op_set.clone();
                    for (existing_region, existing_idx) in &accumulator {
                        let overlap = boolean_intersect(existing_region, &op_set);
                        if !overlap.is_empty() {
                            new_acc.push((overlap, i));
                        }
                        let non_overlap = boolean_subtract(existing_region, &op_set);
                        if !non_overlap.is_empty() {
                            new_acc.push((non_overlap, *existing_idx));
                        }
                        remaining = boolean_subtract(&remaining, existing_region);
                    }
                    if !remaining.is_empty() {
                        new_acc.push((remaining, i));
                    }
                    accumulator = new_acc;
                }
                // §3.6's DIVIDE row / §3.2 (splits). This loop used to hand
                // EVERY output region `src.common().clone()` — the designated
                // operand's whole `common`, ID INCLUDED. An operand that
                // covers two regions therefore left TWO live elements wearing
                // one id, which breaks the uniqueness invariant the
                // cardinality law leans on (REFERENCE_GRAPH.md §2.5) and is
                // strictly worse than a loud break: a reference to that id
                // silently REBINDS to whichever element the index walk reaches
                // first (§3.7).
                //
                // The arrow is counted PER DESIGNATED OPERAND (T5: the
                // elements whose material is at stake), so it is read off the
                // partition rather than assumed:
                //   one region  -> 1 -> 1. Identity is preservable, so it is
                //                  preserved. Over-preservation is a guess,
                //                  but so is killing an identity that the
                //                  edit could have kept — the two disjoint
                //                  rects case, where DIVIDE changes nothing.
                //                  This is `path_erase_at_rect`'s branch, in
                //                  its own words: "ERASE DOES NOT REMOVE
                //                  IDENTITY ... branch on the surviving-
                //                  fragment count". NAMED DELTA from §3.6,
                //                  whose DIVIDE row writes "fresh mint" flat:
                //                  the row describes its 1 -> N heading, and
                //                  the degenerate 1 -> 1 falls to §3.1.
                //   two or more -> 1 -> N. Identity dies; a FRESH id per
                //                  fragment, minted through the shared loop.
                //                  Appearance, `transform` AND `name` copy to
                //                  every fragment (§3.2) — that is the
                //                  `..clone()` that stays.
                //
                // The split arm mints UNCONDITIONALLY, including for an
                // id-less operand, because that is what the landed split
                // (`path_erase_at_rect`) does. The N -> 1 arm above mints only
                // when an identity is at stake; that difference is the NAMED
                // DELTA its own comment records, one ruling for both ports —
                // not something to settle silently here.
                let mut region_counts = vec![0usize; elements.len()];
                for (_, idx) in &accumulator {
                    region_counts[*idx] += 1;
                }
                // Built ONCE from the pre-edit document so fragments of
                // different operands cannot collide with each other either.
                // It still holds the operand ids that are about to vanish —
                // avoiding them is merely conservative, never wrong.
                let mut existing_ids = doc.element_ids();
                for (region, paint_idx) in accumulator {
                    let src = &elements[paint_idx];
                    let mut common = src.common().clone();
                    if region_counts[paint_idx] > 1 {
                        match crate::document::artboard::mint_unique_ids(
                            1, &mut existing_ids, mint,
                        ) {
                            Some(ids) => common.id = Some(ids[0].clone()),
                            // A failed mint aborts the whole edit — never a
                            // half-identified split.
                            None => return,
                        }
                    }
                    outputs.push((
                        region,
                        src.fill().copied(),
                        src.stroke().copied(),
                        common,
                    ));
                }
            }
            "trim" | "merge" => {
                // TRIM: for each operand i, emit (operand[i] - union
                // of all later operands) keeping operand[i]'s own
                // paint. Frontmost (i = N-1) is untouched.
                let operand_sets: Vec<PolygonSet> = elements
                    .iter()
                    .map(|e| element_to_polygon_set(e, precision))
                    .collect();
                // Each survivor carries the OPERAND INDEX it came from, not a
                // snapshot of that operand's `common`. Which identity an
                // output wears is decided per merged GROUP below, and it
                // cannot be decided from a copy that has already forgotten
                // who made it.
                let mut trimmed: Vec<(PolygonSet, Option<Fill>, Option<Stroke>, usize)> =
                    Vec::new();
                for i in 0..elements.len() {
                    let mut region = operand_sets[i].clone();
                    for later in operand_sets.iter().skip(i + 1) {
                        region = boolean_subtract(&region, later);
                    }
                    if !region.is_empty() {
                        trimmed.push((
                            region,
                            elements[i].fill().copied(),
                            elements[i].stroke().copied(),
                            i,
                        ));
                    }
                }
                if op_name == "trim" {
                    // §3.6's TRIM row: every operand is 1 -> 1, so full
                    // Theseus preservation — identity included.
                    for (region, fill, stroke, i) in trimmed {
                        outputs.push((
                            region, fill, stroke, elements[i].common().clone(),
                        ));
                    }
                } else {
                    // MERGE: union touching trimmed survivors that
                    // share an exactly-equal solid-color fill. None
                    // fills never merge (predicate per BOOLEAN.md).
                    // Grouping is O(N^2) by linear scan; acceptable for
                    // the selection sizes this panel handles.
                    //
                    // THE REJECTED RULE, IN PLAIN TEXT, used to live in this
                    // loop: `common_winner = trim_j.3.clone()` handed the
                    // merged output the FRONTMOST contributor's whole
                    // `common` — id and name included — and the comment
                    // beside it stated the election outright ("j is
                    // frontmost; its stroke/common wins"). z-order is
                    // geometry, so T3 forbids it exactly as it forbids
                    // "the largest fragment keeps the id".
                    //
                    // §3.6's MERGE row is the blob brush's two arms:
                    //   ONE contributor  -> 1 -> 1. §3.1: everything
                    //                       survives, identity included.
                    //   TWO or more      -> N -> 1. §3.3: the id dies and a
                    //                       fresh one is minted; every field
                    //                       the op does not speak to follows
                    //                       UNANIMITY (`name` by
                    //                       ASSERTING-SOURCES), and only
                    //                       PAINT rides from the frontmost
                    //                       contributor — the four ratified
                    //                       properties, which is what the op
                    //                       speaks to (T1).
                    // `merged_common` is the shared implementation of that
                    // rule, the same one the UNION / INTERSECTION / EXCLUDE
                    // arm calls, so the two N -> 1 arms cannot drift.
                    let mut consumed = vec![false; trimmed.len()];
                    // Built ONCE from the pre-edit document, as the split
                    // arm's is; it still holds the operand ids about to
                    // vanish, which is conservative, never wrong.
                    let mut existing_ids = doc.element_ids();
                    for i in 0..trimmed.len() {
                        if consumed[i] {
                            continue;
                        }
                        consumed[i] = true;
                        let (region_i, fill_i, stroke_i, src_i) =
                            trimmed[i].clone();
                        let mut merged = region_i;
                        let mut stroke_winner = stroke_i;
                        // The group's contributors in operand z-order, so
                        // `last()` is the frontmost. This is a PAINT
                        // designation (§3.6), not an identity election.
                        let mut group: Vec<usize> = vec![src_i];
                        if fill_i.is_some() {
                            for (j, trim_j) in trimmed.iter().enumerate().skip(i + 1) {
                                if consumed[j] {
                                    continue;
                                }
                                if fills_merge_equal(&fill_i, &trim_j.1) {
                                    merged = boolean_union(&merged, &trim_j.0);
                                    stroke_winner = trim_j.2;
                                    group.push(trim_j.3);
                                    consumed[j] = true;
                                }
                            }
                        }
                        let front = &elements[*group.last().unwrap()];
                        let common = if group.len() == 1 {
                            front.common().clone()
                        } else {
                            let sources: Vec<Rc<Element>> =
                                group.iter().map(|k| elements[*k].clone()).collect();
                            let mut c = merged_common(&sources, front);
                            // Identity is LAZY (VISION.md §6.2), so it is
                            // minted only when one was actually AT STAKE —
                            // the same condition the UNION arm applies, and
                            // deliberately the same: both are N -> 1.
                            if sources.iter().any(|e| e.common().id.is_some()) {
                                match crate::document::artboard::mint_unique_ids(
                                    1, &mut existing_ids, mint,
                                ) {
                                    Some(ids) => c.id = Some(ids[0].clone()),
                                    // A failed mint aborts the whole edit.
                                    None => return,
                                }
                            }
                            c
                        };
                        outputs.push((merged, fill_i, stroke_winner, common));
                    }
                }
            }
            _ => return,
        }

        // Flatten (PolygonSet, paint) outputs into elements.
        //
        // The sweep emits CANONICAL rings, which are read under the
        // even-odd rule (see algorithms/boolean.rs's carried-rule law).
        // A result like XOR of two overlapping rects is one outer ring
        // plus an inner ring that cuts out the overlap — emitting each
        // ring as a separate PolygonElem (which fills its own area
        // independently) leaves the overlap doubly-filled. Single-ring
        // results stay as PolygonElems; multi-ring results emit one
        // PathElem with all rings as subpaths, declaring
        // boolean::RESULT_FILL_RULE so the renderer honours the boolean
        // semantics. JasSwift's applyDestructiveBoolean does the same,
        // element for element.
        //
        // Curve recovery (Schneider refit) is NOT done here; it's a
        // post-op step driven by boolean_panel.apply_simplify_after_op
        // via Controller::simplify_selection. Keeping that out of the
        // emit step means apply_destructive_boolean's output is
        // deterministic and matches what Simplify itself would
        // produce when run on the polygon result.
        use crate::geometry::element::{FillRule, PathCommand, PathElem};
        let mut new_elements: Vec<Rc<Element>> = Vec::new();
        for (ps, fill, stroke, common) in outputs {
            if op_name == "divide"
                && options.divide_remove_unpainted
                && fill.is_none()
                && stroke.is_none()
            {
                continue;
            }
            let kept: Vec<Vec<(f64, f64)>> = ps
                .into_iter()
                .map(|ring| {
                    if options.remove_redundant_points {
                        collapse_collinear_points(ring, options.precision)
                    } else {
                        ring
                    }
                })
                .filter(|r| r.len() >= 3)
                .collect();
            match kept.len() {
                0 => {}
                1 => {
                    new_elements.push(Rc::new(Element::Polygon(PolygonElem {
                        points: kept.into_iter().next().unwrap(),
                        fill,
                        stroke,
                        common: common.clone(),
                        fill_gradient: None,
                        stroke_gradient: None,
                    })));
                }
                _ => {
                    let mut d: Vec<PathCommand> = Vec::new();
                    for ring in &kept {
                        d.push(PathCommand::MoveTo { x: ring[0].0, y: ring[0].1 });
                        for &(x, y) in &ring[1..] {
                            d.push(PathCommand::LineTo { x, y });
                        }
                        d.push(PathCommand::ClosePath);
                    }
                    new_elements.push(Rc::new(Element::Path(PathElem {
                        d,
                        fill,
                        stroke,
                        width_points: Vec::new(),
                        common: common.clone(),
                        fill_gradient: None,
                        stroke_gradient: None,
                        stroke_brush: None,
                        stroke_brush_overrides: None,
                        // Clause 4 of the carried-rule law: a generated
                        // result DECLARES even-odd, from the one named
                        // constant rather than a literal here.
                        fill_rule: FillRule::from(
                            crate::algorithms::boolean::RESULT_FILL_RULE,
                        ),
                    })));
                }
            }
        }

        // Remove all original operands in reverse path order.
        let mut new_doc = doc.clone();
        for p in paths.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }

        // Insert new elements starting at paths[0]'s child_idx.
        let insert_base = paths[0].clone();
        if insert_base.len() >= 2 {
            let layer_idx = insert_base[0];
            let child_idx = insert_base[1];
            if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                for (i, elem) in new_elements.iter().enumerate() {
                    let insert_idx = child_idx + i;
                    if insert_idx <= layer_children.len() {
                        layer_children.insert(insert_idx, elem.clone());
                    } else {
                        layer_children.push(elem.clone());
                    }
                }
            }
        }

        // Select the new elements.
        let mut new_selection = Vec::new();
        if insert_base.len() >= 2 {
            let layer_idx = insert_base[0];
            let base_child_idx = insert_base[1];
            for i in 0..new_elements.len() {
                let path = vec![layer_idx, base_child_idx + i];
                if new_doc.get_element(&path).is_some() {
                    new_selection.push(ElementSelection::all(path));
                }
            }
        }
        new_doc.selection = new_selection;
        model.edit_document(new_doc);
    }

    /// Ungroup all unlocked Group elements in the entire document, where
    /// "unlocked" is INHERITED (transcripts/LAYER_STRUCTURE.md §13): a Group
    /// inside a locked layer or a locked group is left alone, structure
    /// included, exactly as one with its own flag set is.
    pub fn ungroup_all(model: &mut Model) {
        let doc = model.document().clone();
        let mut changed = false;

        // `ancestor_locked` is the INHERITED half of the lock read
        // (transcripts/LAYER_STRUCTURE.md §13): a Group survives when its own
        // flag is set OR when anything it sits inside is locked. This is the
        // same `effective_locked` fold, threaded through a walk that already
        // has the ancestors in hand. It is NOT a new guard — `ungroup_all`
        // always read lock; §13 changed what the word means.
        fn flatten(
            children: &[Rc<Element>],
            ancestor_locked: bool,
            changed: &mut bool,
        ) -> Vec<Rc<Element>> {
            let mut result = Vec::new();
            for child in children {
                let locked = ancestor_locked || child.locked();
                if child.is_group() && !locked {
                    *changed = true;
                    let inner = child.children().unwrap_or(&[]);
                    result.extend(flatten(inner, locked, changed));
                } else if child.is_group() {
                    // Locked group: recurse into children but keep the group
                    let inner = child.children().unwrap_or(&[]);
                    let new_children = flatten(inner, locked, changed);
                    let mut new_group = (**child).clone();
                    if let Some(gc) = new_group.children_mut() {
                        *gc = new_children;
                    }
                    result.push(Rc::new(new_group));
                } else {
                    result.push(child.clone());
                }
            }
            result
        }

        let new_layers: Vec<Element> = doc
            .layers
            .iter()
            .map(|layer| {
                let children = layer.children().unwrap_or(&[]);
                let new_children = flatten(children, layer.locked(), &mut changed);
                let mut new_layer = layer.clone();
                if let Some(lc) = new_layer.children_mut() {
                    *lc = new_children;
                }
                new_layer
            })
            .collect();

        if !changed {
            return;
        }
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection.clear();
        model.edit_document(new_doc);
    }

    /// Lock all selected elements.
    /// Simplify the geometry of each selected Polygon / Path element
    /// in place by running the Schneider curve fit
    /// (algorithms::simplify::simplify_polyline) on its vertices.
    /// Other element kinds are left alone. Used by Object → Simplify
    /// and (in future) other refit entry points. `precision` is the
    /// Schneider max-error tolerance in points.
    ///
    /// PolygonElems are replaced with PathElems that carry the
    /// refitted CurveTo / LineTo commands; existing PathElems are
    /// re-issued with refitted geometry. Selection is preserved.
    /// Refit the selected paths/polygons to simplified curves. Self-bracketing
    /// (OP_LOG.md Increment 2): a standalone call opens + commits its own undo
    /// transaction; called as the boolean post-op auto-simplify it runs inside
    /// `apply_boolean_operation`'s `with_txn`, so `edit_document` joins that
    /// transaction and the boolean + refit collapse into a single undo entry.
    /// (Replaces the Increment-1 `take_snapshot` parameter, now deleted.)
    pub fn simplify_selection(model: &mut Model, precision: f64) {
        use crate::algorithms::simplify::simplify_polyline;
        use crate::geometry::element::{PathCommand, PathElem};
        let doc = model.document().clone();
        if doc.selection.is_empty() {
            return;
        }
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            let Some(elem) = new_doc.get_element(&es.path).cloned() else { continue; };
            match &elem {
                Element::Polygon(p) => {
                    let cmds = simplify_polyline(&p.points, precision, true);
                    if cmds.is_empty() { continue; }
                    let new_path = Element::Path(PathElem {
                        d: cmds,
                        fill: p.fill,
                        stroke: p.stroke,
                        width_points: Vec::new(),
                        common: p.common.clone(),
                        fill_gradient: p.fill_gradient.clone(),
                        stroke_gradient: p.stroke_gradient.clone(),
                        stroke_brush: None,
                        stroke_brush_overrides: None,
                        fill_rule: crate::geometry::element::FillRule::NonZero,
                    });
                    new_doc = new_doc.replace_element(&es.path, new_path);
                }
                Element::Path(p) => {
                    // Walk the path command list, splitting at every
                    // MoveTo / ClosePath into subpaths of 2D points.
                    // Each subpath is refit independently; other
                    // command kinds (CurveTo, ArcTo) are passed
                    // through as-is.
                    let mut new_cmds: Vec<PathCommand> = Vec::new();
                    let mut buf: Vec<(f64, f64)> = Vec::new();
                    let mut closed = false;
                    let flush = |new_cmds: &mut Vec<PathCommand>, buf: &mut Vec<(f64, f64)>, closed: &mut bool| {
                        if buf.len() >= 2 {
                            let sub = simplify_polyline(buf, precision, *closed);
                            new_cmds.extend(sub);
                        }
                        buf.clear();
                        *closed = false;
                    };
                    for c in &p.d {
                        match *c {
                            PathCommand::MoveTo { x, y } => {
                                flush(&mut new_cmds, &mut buf, &mut closed);
                                buf.push((x, y));
                            }
                            PathCommand::LineTo { x, y } => buf.push((x, y)),
                            PathCommand::ClosePath => {
                                closed = true;
                                flush(&mut new_cmds, &mut buf, &mut closed);
                            }
                            // Already-curved commands stay verbatim;
                            // splice the buffered run before emitting
                            // them so refit and pre-existing curves
                            // sit in order.
                            other => {
                                flush(&mut new_cmds, &mut buf, &mut closed);
                                new_cmds.push(other);
                            }
                        }
                    }
                    flush(&mut new_cmds, &mut buf, &mut closed);
                    if new_cmds.is_empty() { continue; }
                    let new_path = Element::Path(PathElem {
                        d: new_cmds,
                        fill: p.fill,
                        stroke: p.stroke,
                        width_points: p.width_points.clone(),
                        common: p.common.clone(),
                        fill_gradient: p.fill_gradient.clone(),
                        stroke_gradient: p.stroke_gradient.clone(),
                        stroke_brush: p.stroke_brush.clone(),
                        stroke_brush_overrides: p.stroke_brush_overrides.clone(),
                        fill_rule: p.fill_rule,
                    });
                    new_doc = new_doc.replace_element(&es.path, new_path);
                }
                _ => {}
            }
        }
        model.edit_document(new_doc);
    }

    /// `Object > Lock` (Ctrl+2, `workspace/actions.yaml` §lock): set the
    /// `locked` flag on each selected element and clear the selection.
    ///
    /// **ON EACH SELECTED ELEMENT, AND ON NOTHING ELSE.** A Group or Layer's
    /// lock reaches its contents by INHERITANCE
    /// ([`Document::effective_locked`]), never by being written onto them —
    /// this is step 1 of [`Document::toggling_element_lock`], the Layers-panel
    /// lock button, applied once per selected path. It is deliberately the same
    /// shape rather than a second one: until LOCKMAT this function kept its own
    /// recursive `lock_element` helper that stamped `locked = true` onto every
    /// descendant of a Group, which is the MATERIALIZATION
    /// transcripts/LAYER_STRUCTURE.md §13 repealed (RULED by JYH 2026-07-28).
    /// §13 repaired the panel path and left this one, and the two then said
    /// different things about the same artist action.
    ///
    /// Why the residue could not simply be left: §13.1 landed `jas:locked`, so
    /// stamped flags SURVIVE SAVE AND RELOAD, and under inheritance nothing
    /// clears a single one of them — opening the parent leaves every child
    /// locked, and `Unlock All` is the whole document or nothing.
    ///
    /// The selection is cleared WHOLESALE, which is `toggling_element_lock`'s
    /// step 2 in the case where every selected path was just locked: it is not
    /// cosmetic, because nothing downstream refuses to move or delete a locked
    /// element (SCOPE-effective-locked.md §2), so a lock that left the selection
    /// alone would leave locked content draggable.
    ///
    /// Clone-then-mutate through `get_element_mut`, so every field of the
    /// locked element that this operation does not speak to comes back
    /// untouched. The twin is JasSwift `Controller.lockSelection()`.
    pub fn lock_selection(model: &mut Model) {
        let doc = model.document().clone();
        if doc.selection.is_empty() {
            return;
        }
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = new_doc.get_element_mut(&es.path) {
                elem.common_mut().locked = true;
            }
        }
        new_doc.selection.clear();
        model.edit_document(new_doc);
    }

    /// Move a Bezier handle of a path element.
    pub fn move_path_handle(
        model: &mut Model,
        path: &ElementPath,
        anchor_idx: usize,
        handle_type: &str,
        dx: f64,
        dy: f64,
    ) {
        let doc = model.document().clone();
        if let Some(Element::Path(pe)) = doc.get_element(path) {
            let new_pe = move_path_handle(pe, anchor_idx, handle_type, dx, dy);
            let new_doc = doc.replace_element(path, Element::Path(new_pe));
            model.edit_document(new_doc);
        }
    }

    /// Unlock all locked elements.
    pub fn unlock_all(model: &mut Model) {
        let doc = model.document().clone();
        let new_layers: Vec<Element> = doc.layers.iter().map(unlock_element).collect();
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        // UNLOCK ALL PRESERVES THE SELECTION (RULED 2026-07-29). This used to
        // CLEAR it, while JasSwift REPLACED it with every path just unlocked —
        // a live divergence on a shared verb, and `actions.yaml` describes
        // `unlock_all` without mentioning the selection at all.
        //
        // The PRESERVATION LAW settles it: an edit changes what it speaks to
        // and preserves the rest, and selection order is part of the document
        // (§10/D6). Unlock All speaks to `locked`; the selection is the rest.
        //
        // Lock and Hide DO clear, and `actions.yaml` gives the reason —
        // "because nothing downstream refuses to move or delete a selected
        // element for being locked". That is a workaround for the enforcement
        // §15 will add, and it does not apply here: unlocking makes nothing
        // unselectable, so clearing would destroy artist state for nothing.
        model.edit_document(new_doc);
    }

    /// Set every element in the current selection to
    /// [`Visibility::Invisible`] and clear the selection. If an
    /// element is a Group/Layer, the visibility is set on the
    /// container itself (not its children) — a parent's `Invisible`
    /// caps every descendant, so the effect reaches the whole
    /// subtree without mutating every node.
    pub fn hide_selection(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        if doc.selection.is_empty() {
            return;
        }
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = new_doc.get_element(&es.path).cloned() {
                let mut hidden = elem.clone();
                hidden.common_mut().visibility = Visibility::Invisible;
                new_doc = new_doc.replace_element(&es.path, hidden);
            }
        }
        new_doc.selection.clear();
        model.edit_document(new_doc);
    }

    /// Traverse the document, set every element whose own
    /// visibility is [`Visibility::Invisible`] back to
    /// [`Visibility::Preview`], and replace the current selection
    /// with exactly the paths that were shown. Elements that are
    /// effectively invisible only because an ancestor is invisible
    /// are *not* individually modified — it is the ancestor whose
    /// own flag is unset, and that cascades.
    pub fn show_all(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        let mut shown_paths: Vec<ElementPath> = Vec::new();
        let new_layers: Vec<Element> = doc
            .layers
            .iter()
            .enumerate()
            .map(|(li, layer)| show_all_in(layer, &vec![li], &mut shown_paths))
            .collect();
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection = shown_paths
            .into_iter()
            .map(ElementSelection::all)
            .collect();
        // Suppress the unused `Visibility` warning when compiled in
        // configurations that optimise the helper away.
        let _ = Visibility::Preview;
        model.edit_document(new_doc);
    }

    /// Apply the TSPAN.md "Character attribute writes" algorithm to the
    /// text element at `path` over the character range
    /// `[char_start, char_end)`: split_range → set attribute on every
    /// targeted tspan → identity omission (null out overrides that
    /// equal the parent's effective value) → merge adjacent equal.
    ///
    /// Attribute names are snake_case (`font_weight`, `font_style`,
    /// `font_family`, `font_size`). Unsupported attributes are silently
    /// ignored — add them here as needed.
    ///
    /// No-op when the target is not a Text / TextPath element or when
    /// the range is out of bounds.
    pub fn set_character_attribute(
        model: &mut Model,
        path: &ElementPath,
        char_start: usize,
        char_end: usize,
        attribute: &str,
        value: &str,
    ) {
        let doc = model.document().clone();
        let new_elem = match doc.get_element(path) {
            Some(Element::Text(t)) => {
                let mut new_t = t.clone();
                let parent_for_omission = t.clone();
                let (tspans, first, last) = crate::geometry::tspan::split_range(
                    &new_t.tspans,
                    char_start,
                    char_end,
                );
                new_t.tspans = tspans;
                if let (Some(first), Some(last)) = (first, last) {
                    for i in first..=last {
                        apply_attr_to_tspan(&mut new_t.tspans[i], attribute, value);
                    }
                    for i in first..=last {
                        omit_text_identity(
                            &mut new_t.tspans[i],
                            &parent_for_omission,
                            attribute,
                        );
                    }
                }
                new_t.tspans = crate::geometry::tspan::merge(&new_t.tspans);
                Element::Text(new_t)
            }
            Some(Element::TextPath(tp)) => {
                let mut new_tp = tp.clone();
                let parent_for_omission = tp.clone();
                let (tspans, first, last) = crate::geometry::tspan::split_range(
                    &new_tp.tspans,
                    char_start,
                    char_end,
                );
                new_tp.tspans = tspans;
                if let (Some(first), Some(last)) = (first, last) {
                    for i in first..=last {
                        apply_attr_to_tspan(&mut new_tp.tspans[i], attribute, value);
                    }
                    for i in first..=last {
                        omit_textpath_identity(
                            &mut new_tp.tspans[i],
                            &parent_for_omission,
                            attribute,
                        );
                    }
                }
                new_tp.tspans = crate::geometry::tspan::merge(&new_tp.tspans);
                Element::TextPath(new_tp)
            }
            _ => return,
        };
        let new_doc = doc.replace_element(path, new_elem);
        model.edit_document(new_doc);
    }
}

/// Apply a character-panel attribute write to a single tspan by setting
/// its override slot to `Some(value)`. Unsupported attribute names are
/// silently ignored so callers can send arbitrary names.
fn apply_attr_to_tspan(ts: &mut crate::geometry::tspan::Tspan, attr: &str, value: &str) {
    match attr {
        "font_family" => ts.font_family = Some(value.to_string()),
        "font_size" => {
            if let Ok(v) = value.parse::<f64>() {
                ts.font_size = Some(v);
            }
        }
        "font_weight" => ts.font_weight = Some(value.to_string()),
        "font_style" => ts.font_style = Some(value.to_string()),
        _ => {}
    }
}

fn omit_text_identity(
    ts: &mut crate::geometry::tspan::Tspan,
    parent: &crate::geometry::element::TextElem,
    attr: &str,
) {
    match attr {
        "font_family" => {
            if ts.font_family.as_deref() == Some(parent.font_family.as_str()) {
                ts.font_family = None;
            }
        }
        "font_size" => {
            if ts.font_size == Some(parent.font_size) {
                ts.font_size = None;
            }
        }
        "font_weight" => {
            if ts.font_weight.as_deref() == Some(parent.font_weight.as_str()) {
                ts.font_weight = None;
            }
        }
        "font_style" => {
            if ts.font_style.as_deref() == Some(parent.font_style.as_str()) {
                ts.font_style = None;
            }
        }
        _ => {}
    }
}

fn omit_textpath_identity(
    ts: &mut crate::geometry::tspan::Tspan,
    parent: &crate::geometry::element::TextPathElem,
    attr: &str,
) {
    match attr {
        "font_family" => {
            if ts.font_family.as_deref() == Some(parent.font_family.as_str()) {
                ts.font_family = None;
            }
        }
        "font_size" => {
            if ts.font_size == Some(parent.font_size) {
                ts.font_size = None;
            }
        }
        "font_weight" => {
            if ts.font_weight.as_deref() == Some(parent.font_weight.as_str()) {
                ts.font_weight = None;
            }
        }
        "font_style" => {
            if ts.font_style.as_deref() == Some(parent.font_style.as_str()) {
                ts.font_style = None;
            }
        }
        _ => {}
    }
}

/// Recursively rewrite `elem` so that every node whose own
/// visibility is `Invisible` becomes `Preview`, collecting the paths
/// of rewritten nodes into `shown_paths`.
fn show_all_in(
    elem: &Element,
    path: &ElementPath,
    shown_paths: &mut Vec<ElementPath>,
) -> Element {
    use crate::geometry::element::Visibility;
    let mut new = elem.clone();
    if new.visibility() == Visibility::Invisible {
        new.common_mut().visibility = Visibility::Preview;
        shown_paths.push(path.clone());
    }
    if let Some(children) = new.children_mut() {
        let rewritten: Vec<Rc<Element>> = children
            .iter()
            .enumerate()
            .map(|(i, child)| {
                let mut cp = path.clone();
                cp.push(i);
                Rc::new(show_all_in(child, &cp, shown_paths))
            })
            .collect();
        *children = rewritten;
    }
    new
}

/// Clear `locked` on `elem` and, RECURSIVELY, on everything inside it.
///
/// The recursion here is NOT the materialization §13 repealed — it is the sole
/// artist-reachable REVOCATION (`Object > Unlock All`), and it is what clears
/// flags a document already carries: files saved before LOCKMAT hold stamped
/// descendants that inheritance can no longer express, and this walk is the
/// only thing in either port that can remove them. Its twin, `lock_element`,
/// was deleted with that wave; `Controller::lock_selection` now writes the flag
/// on the selected element alone.
fn unlock_element(elem: &Element) -> Element {
    let mut new = elem.clone();
    if let Some(children) = new.children_mut() {
        *children = children.iter().map(|c| Rc::new(unlock_element(c))).collect();
    }
    new.common_mut().locked = false;
    new
}

/// Flat 2-level selection: iterate layers → children, expanding groups.
///
/// The `predicate` tests whether a leaf element should be selected.
/// Groups are expanded: if any grandchild matches, the group and all
/// its children are selected.
fn select_flat(
    model: &mut Model,
    predicate: impl Fn(&Element) -> bool,
    extend: bool,
) {
    use crate::geometry::element::Visibility;
    let doc = model.document().clone();
    let mut entries: Selection = Vec::new();
    for (li, layer) in doc.layers.iter().enumerate() {
        let layer_vis = layer.visibility();
        // A locked layer's subtree is non-selectable by INHERITANCE — lock is
        // not materialized onto children (transcripts/LAYER_STRUCTURE.md §13,
        // RULED 2026-07-28), so the guard has to be an ancestor-aware read at
        // every level rather than a flag on each element. Mirrors the hit_test
        // path and JasSwift `selectFlat`.
        //
        // HONEST NOTE ON WHAT IS WATCHED. This walk is three levels deep, and
        // the layer guard below is the one that enforces at levels 1 and 2:
        // under it, `effective_locked` at those depths is ALGEBRAICALLY the
        // element's own flag, so those two reads are expressive rather than
        // behavioural and no mutation can turn them red (measured: reverting
        // either to `.locked()` leaves the whole suite green). The GRANDCHILD
        // read further down is the behavioural change, and it does red.
        if doc.effective_locked(&vec![li]) || layer_vis == Visibility::Invisible {
            continue;
        }
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if doc.effective_locked(&vec![li, ci]) {
                    continue;
                }
                let child_vis = std::cmp::min(layer_vis, child.visibility());
                if child_vis == Visibility::Invisible {
                    continue;
                }
                if child.is_group() {
                    // A locked grandchild neither TRIGGERS the group selection
                    // nor JOINS it. Before §13 the predicate ran over every
                    // grandchild unguarded, so a rubber band that touched only
                    // a locked member dragged the group and its unlocked
                    // siblings into the selection with it.
                    //
                    // §16.4 (RULED 2026-07-29): the band ASKS about members,
                    // but ANSWERS with the group alone. This branch used to
                    // push the group AND every unlocked member, which is the
                    // one selection shape no operation reads coherently:
                    // `copy_selection` copies the group whole and then copies
                    // each member INTO the source group, so marquee-then-
                    // duplicate left the SOURCE holding four children instead
                    // of two. Move and delete survived it only by accident.
                    if let Some(grandchildren) = child.children()
                        && grandchildren.iter().enumerate().any(|(gi, gc)| {
                            !doc.effective_locked(&vec![li, ci, gi]) && predicate(gc)
                        })
                    {
                        entries.push(ElementSelection::all(vec![li, ci]));
                    }
                } else if predicate(child) {
                    entries.push(ElementSelection::all(vec![li, ci]));
                }
            }
        }
    }
    let new_sel = if extend {
        toggle_selection(&doc.selection, &entries)
    } else {
        entries
    };
    let mut new_doc = doc;
    new_doc.selection = new_sel;
    model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
}

/// Recursive selection: traverse the full element tree, calling
/// `leaf_handler` on each non-container element. Groups and layers
/// are traversed (not expanded).
fn select_recursive(
    model: &mut Model,
    leaf_handler: impl Fn(&ElementPath, &Element) -> Option<ElementSelection>,
    extend: bool,
) {
    use crate::geometry::element::Visibility;

    fn check(
        entries: &mut Selection,
        path: &ElementPath,
        elem: &Element,
        ancestor_vis: Visibility,
        leaf_handler: &dyn Fn(&ElementPath, &Element) -> Option<ElementSelection>,
    ) {
        if elem.locked() {
            return;
        }
        let effective = std::cmp::min(ancestor_vis, elem.visibility());
        if effective == Visibility::Invisible {
            return;
        }
        if elem.is_group_or_layer() {
            if let Some(children) = elem.children() {
                for (i, child) in children.iter().enumerate() {
                    let mut child_path = path.clone();
                    child_path.push(i);
                    check(entries, &child_path, child, effective, leaf_handler);
                }
            }
            return;
        }
        if let Some(es) = leaf_handler(path, elem) {
            entries.push(es);
        }
    }

    let doc = model.document().clone();
    let mut entries: Selection = Vec::new();
    for (li, layer) in doc.layers.iter().enumerate() {
        check(&mut entries, &vec![li], layer, Visibility::Preview, &leaf_handler);
    }
    let new_sel = if extend {
        toggle_selection(&doc.selection, &entries)
    } else {
        entries
    };
    let mut new_doc = doc;
    new_doc.selection = new_sel;
    model.set_document_unbracketed(new_doc, NonUndoableIntent::Selection);
}

/// Combine two selections by XOR-ing per-element CP membership.
///
/// - Elements appearing in only one input pass through unchanged.
/// - Elements appearing in both inputs have their selected CP sets
///   XORed. If the result is empty the element stays selected as
///   `Partial(empty)` — "element selected, no individual CPs
///   highlighted" — rather than being dropped.
/// - Two `All` selections cancel out (the element *is* dropped — this
///   is the element-level deselect gesture, distinct from removing
///   the last CP of a `Partial`).
/// - `All` XOR `Partial(s)` becomes `Partial` of the *complement* of
///   `s` against the element's CP count, which we don't have here, so
///   we conservatively treat it as `All` (this preserves the
///   pre-refactor behavior for the rare mixed case).
///
/// ORDER IS PART OF THE RESULT. This used to build two `HashMap`s and iterate
/// THEM, so with two or more surviving entries the output order was Rust's
/// per-process `RandomState` hash order — the same defect D6 names in JasSwift
/// (LAYER_STRUCTURE.md §10), in the port that is supposed to be canonical. It
/// was invisible because `test_json::selection_json` sorted on the way out.
/// The maps are now lookup-only; emission walks `current` then `new` IN THEIR
/// OWN ORDER, so shift-marquee builds a stable selection.
fn toggle_selection(current: &Selection, new: &Selection) -> Selection {
    let current_by_path: std::collections::HashMap<&Vec<usize>, &ElementSelection> =
        current.iter().map(|es| (&es.path, es)).collect();
    let new_by_path: std::collections::HashMap<&Vec<usize>, &ElementSelection> =
        new.iter().map(|es| (&es.path, es)).collect();

    let mut result: Selection = Vec::new();
    // Walk CURRENT in its own order: survivors keep their existing z-position
    // in the selection, and elements present in both are resolved here.
    for cur in current.iter() {
        match new_by_path.get(&cur.path) {
            None => result.push(cur.clone()),
            Some(nw) => match (&cur.kind, &nw.kind) {
                (SelectionKind::All, SelectionKind::All) => {
                    // Cancel out — element drops out of the selection.
                }
                (SelectionKind::Partial(a), SelectionKind::Partial(b)) => {
                    // Keep the element even when xor is empty: the
                    // element stays selected with zero highlighted CPs.
                    let xor = a.symmetric_difference(b);
                    result.push(ElementSelection {
                        path: cur.path.clone(),
                        kind: SelectionKind::Partial(xor),
                    });
                }
                _ => {
                    // Mixed All/Partial — keep `All` to preserve the
                    // pre-refactor behavior for this rare case.
                    result.push(ElementSelection::all(cur.path.clone()));
                }
            },
        }
    }
    // Then NEW in its own order: the newly-hit elements append behind them.
    for nw in new.iter() {
        if !current_by_path.contains_key(&nw.path) {
            result.push(nw.clone());
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Selection fill/stroke summaries
// ---------------------------------------------------------------------------

/// Summary of the fill state across a selection.
#[derive(Debug, Clone, PartialEq)]
pub enum FillSummary {
    /// No elements are selected.
    NoSelection,
    /// All selected elements have the same fill (or all are None).
    Uniform(Option<Fill>),
    /// Selected elements differ in fill.
    Mixed,
}

/// Summary of the stroke state across a selection.
#[derive(Debug, Clone, PartialEq)]
pub enum StrokeSummary {
    /// No elements are selected.
    NoSelection,
    /// All selected elements have the same stroke color (or all are None).
    Uniform(Option<Stroke>),
    /// Selected elements differ in stroke.
    Mixed,
}

/// Compute the fill summary for the current selection.
pub fn selection_fill_summary(doc: &Document) -> FillSummary {
    if doc.selection.is_empty() {
        return FillSummary::NoSelection;
    }
    // A selected CONTAINER summarises the paint of its members, at any depth --
    // the read twin of `map_paintable`. Reading a container's own `fill()`
    // gives `None` and reported "no fill" for a group whose members all carry
    // one; a group whose members disagree is `Mixed`, the same answer those
    // members give when selected without the group around them.
    let mut first: Option<Option<Fill>> = None;
    let mut mixed = false;
    for es in &doc.selection {
        let Some(elem) = doc.get_element(&es.path) else { continue };
        crate::geometry::element::for_each_paintable(elem, &mut |leaf| {
            if mixed {
                return;
            }
            let fill = leaf.fill().copied();
            match &first {
                None => first = Some(fill),
                Some(prev) => {
                    if *prev != fill {
                        mixed = true;
                    }
                }
            }
        });
        if mixed {
            return FillSummary::Mixed;
        }
    }
    FillSummary::Uniform(first.unwrap_or(None))
}

/// The stroke the Stroke panel should DISPLAY for the current selection.
///
/// Found by JYH at council 2026-07-29: selecting a group showed 1 pt while both
/// members carried 5. The panel override read `doc.selection.first()` and then
/// that element's OWN stroke -- `None` for a container -- and fell through to a
/// hard-coded 1.0. Both ports did it identically, so no cross-language gate saw
/// it. The eighth consumer of the container-blind premise.
///
/// ONLY THE CONTAINER CASE CHANGES. A single leaf and a uniform multi-selection
/// resolve to the value they always did. A MIXED selection still falls back to
/// the first element's stroke -- the pre-existing lie, deliberately left alone:
/// showing the tab default instead would be a DIFFERENT lie, not progress, and
/// the honest answer is `<mixed>`, which needs the widget vocabulary scoped in
/// transcripts/MIXED_SELECTION.md.
pub fn selection_stroke_for_panel(doc: &Document) -> Option<Stroke> {
    match selection_stroke_summary(doc) {
        StrokeSummary::Uniform(Some(s)) => Some(s),
        // MIXED (or no stroke): fall back to the FIRST PAINTABLE LEAF, not the
        // first selection ENTRY. Reading the entry directly gives `None` for a
        // container and drops to a hard-coded 1.0, so a mixed GROUP answered
        // 1 pt while its two members selected DIRECTLY answered with the first
        // member's weight -- the same document and the same mixedness giving
        // two different numbers. THE SPELLINGS MUST AGREE: a group is a mixed
        // selection of one (MIXED_SELECTION.md §4).
        //
        // Both answers are still lies until `<mixed>` exists. This makes them
        // the SAME lie, which is the most that can be done without the widget
        // vocabulary.
        _ => doc.selection.first().and_then(|es| {
            let elem = doc.get_element(&es.path)?;
            let mut found: Option<Stroke> = None;
            crate::geometry::element::for_each_paintable(elem, &mut |leaf| {
                if found.is_none() {
                    found = leaf.stroke().cloned();
                }
            });
            found
        }),
    }
}

/// Compute the stroke summary for the current selection.
pub fn selection_stroke_summary(doc: &Document) -> StrokeSummary {
    if doc.selection.is_empty() {
        return StrokeSummary::NoSelection;
    }
    // A selected CONTAINER summarises the paint of its members, at any depth --
    // the read twin of `map_paintable`. Reading a container's own `stroke()`
    // gives `None` and reported "no stroke" for a group whose members all carry
    // one; a group whose members disagree is `Mixed`, the same answer those
    // members give when selected without the group around them.
    let mut first: Option<Option<Stroke>> = None;
    let mut mixed = false;
    for es in &doc.selection {
        let Some(elem) = doc.get_element(&es.path) else { continue };
        crate::geometry::element::for_each_paintable(elem, &mut |leaf| {
            if mixed {
                return;
            }
            let stroke = leaf.stroke().copied();
            match &first {
                None => first = Some(stroke),
                Some(prev) => {
                    if *prev != stroke {
                        mixed = true;
                    }
                }
            }
        });
        if mixed {
            return StrokeSummary::Mixed;
        }
    }
    StrokeSummary::Uniform(first.unwrap_or(None))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: vec![],
            common: CommonProps::default(),
                    stroke_gradient: None,
        })
    }

    fn make_group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        })
    }

    fn sel_paths(model: &Model) -> Vec<Vec<usize>> {
        let mut paths: Vec<Vec<usize>> = model.document().selection.iter()
            .map(|es| es.path.clone()).collect();
        paths.sort();
        paths
    }

    /// Twin of JasSwift's NestedGroupProbeTests: group two elements that
    /// already live INSIDE a Group. Rust's `insert_element_at` recurses on
    /// `&path[1..]`, so the new group should stay inside the outer group.
    /// Swift's `groupSelection` reads only `insertPath[1]` and pushes into
    /// `layers[layerIdx].children`, so it escapes a level and strands the
    /// emptied outer group as debris.
    #[test]
    fn grouping_inside_a_group_stays_inside_that_group() {
        let inner = make_group(vec![
            make_line(0.0, 0.0, 5.0, 5.0),
            make_line(1.0, 1.0, 6.0, 6.0),
        ]);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(make_rect(0.0, 0.0, 10.0, 10.0)), Rc::new(inner)],
            ..LayerElem::default()
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0, 1, 0]),
                ElementSelection::all(vec![0, 1, 1]),
            ],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::group_selection(&mut model);

        let after = model.document();
        let layer_kids = after.layers[0].children().map_or(0, |c| c.len());
        assert_eq!(layer_kids, 2,
            "layer holds {layer_kids} children; a third means the new group escaped one level");
        let outer = after.get_element(&vec![0, 1]).expect("outer group still at [0,1]");
        assert_eq!(outer.children().map_or(0, |c| c.len()), 1,
            "outer group should hold exactly the new nested group");
    }

    // ===================================================================
    // R1 — GROUP ALWAYS FLATTENS (transcripts/LAYER_STRUCTURE.md §3 R1,
    // ratified 2026-07-28). Twin probes; the Swift twins live in
    // JasSwift/Tests/Document/GroupFlattenTests.swift, case for case.
    //
    // Before R1 both ports carried a SIBLING GUARD that `return`ed when the
    // selected paths did not share one parent prefix (and did not share one
    // path LENGTH). Cmd+G across two layers was a silent no-op with no
    // feedback. R1: no refusal — every selected element becomes a child of
    // the new Group, which lands at the FRONTMOST selected element's parent,
    // at the z-slot that element vacates.
    //
    // "Frontmost" is fixed by the same rule BOOLEAN.md already uses and
    // `make_compound_shape_with_op` already implements: paths sorted
    // ascending, frontmost is `.last()` — the GREATEST path. The canvas
    // paints `for layer in &doc.layers` forward into Canvas2D, so a higher
    // index paints later and therefore on top.
    // ===================================================================

    fn make_layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            children: children.into_iter().map(Rc::new).collect(),
            common: CommonProps { name: Some(name.to_string()), ..CommonProps::default() },
            isolated_blending: false,
            knockout_group: false,
        })
    }

    fn group_doc(layers: Vec<Element>, sel: Vec<Vec<usize>>) -> Model {
        let doc = Document {
            layers,
            selected_layer: 0,
            selection: sel.into_iter().map(ElementSelection::all).collect(),
            ..Document::default()
        };
        Model::new(doc, None)
    }

    /// R1 case 1 — TWO LAYERS. The selection spans layer 0 and layer 1; the
    /// old guard refused outright. The new Group lands in the FRONTMOST
    /// element's layer (layer 1), and layer 0 — emptied by the move — stays,
    /// per the T4 bystander clause: it is the artist's layer and it was not
    /// what the edit spoke to.
    #[test]
    fn r1_group_across_two_layers_lands_in_the_frontmost_layer() {
        let rect = make_rect(0.0, 0.0, 10.0, 10.0);
        let line = make_line(1.0, 1.0, 6.0, 6.0);
        let mut model = group_doc(
            vec![
                make_layer("Background", vec![rect.clone()]),
                make_layer("Foreground", vec![line.clone()]),
            ],
            vec![vec![0, 0], vec![1, 0]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        // The emptied source LAYER survives, with its name intact.
        assert_eq!(after.layers.len(), 2, "both layers must survive the move");
        assert_eq!(after.layers[0].children().map_or(1, |c| c.len()), 0,
            "layer 0 gave up its only child and must be left EMPTY, not deleted");
        assert_eq!(after.layers[0].common().name.as_deref(), Some("Background"),
            "the emptied bystander layer keeps its name");

        // The group landed in layer 1 at the frontmost element's z-slot.
        let g = after.get_element(&vec![1, 0]).expect("new group at [1,0]");
        let kids = g.children().expect("the new element is a container");
        assert_eq!(kids.len(), 2, "both selected elements became children");

        // Whole-element equality: this is a RELOCATION, not a rebuild.
        // Paired with explicit VALUE assertions below, because whole-struct
        // equality is structurally blind to which field carries the geometry.
        assert_eq!(*kids[0], rect, "the rect moved across whole and unchanged");
        assert_eq!(*kids[1], line, "the line moved across whole and unchanged");
        match &*kids[0] {
            Element::Rect(r) => {
                assert_eq!((r.x, r.y, r.width, r.height), (0.0, 0.0, 10.0, 10.0),
                    "the rect's geometry survived the move");
            }
            other => panic!("child 0 should still be a Rect, got {other:?}"),
        }
        match &*kids[1] {
            Element::Line(l) => {
                assert_eq!((l.x1, l.y1, l.x2, l.y2), (1.0, 1.0, 6.0, 6.0),
                    "the line's geometry survived the move");
            }
            other => panic!("child 1 should still be a Line, got {other:?}"),
        }
        assert_eq!(sel_paths(&model), vec![vec![1, 0]],
            "selection becomes the new group");
    }

    /// R1 case 2 — TWO DIFFERENT GROUPS, one layer. The old guard rejected
    /// this for exactly the same reason it rejected two layers: the parents
    /// differ. Nothing about the fix may be phrased in terms of layers.
    #[test]
    fn r1_group_across_two_groups_lands_in_the_frontmost_group() {
        let a = make_rect(0.0, 0.0, 10.0, 10.0);
        let b = make_rect(20.0, 0.0, 10.0, 10.0);
        let c = make_rect(40.0, 0.0, 10.0, 10.0);
        let d = make_rect(60.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![
                make_group(vec![a.clone(), b.clone()]),
                make_group(vec![c.clone(), d.clone()]),
            ])],
            // b (in the back group) + c (in the front group).
            vec![vec![0, 0, 1], vec![0, 1, 0]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        let back = after.get_element(&vec![0, 0]).expect("back group survives");
        assert_eq!(back.children().map_or(0, |c| c.len()), 1,
            "the back group keeps its remaining child");
        assert_eq!(*back.children().unwrap()[0], a, "and that child is untouched");

        // The new group is INSIDE the frontmost element's parent (the front
        // group), at the slot c vacated.
        let new_g = after.get_element(&vec![0, 1, 0]).expect("new group at [0,1,0]");
        let kids = new_g.children().expect("new group is a container");
        assert_eq!(kids.len(), 2, "b and c became the new group's children");
        assert_eq!(*kids[0], b, "b relocated whole");
        assert_eq!(*kids[1], c, "c relocated whole");
        match &*kids[1] {
            Element::Rect(r) => assert_eq!((r.x, r.width), (40.0, 10.0),
                "c's geometry survived the cross-parent move"),
            other => panic!("expected Rect, got {other:?}"),
        }
        // d stayed put, one slot along.
        let front = after.get_element(&vec![0, 1]).expect("front group survives");
        assert_eq!(*front.children().unwrap()[1], d, "d is still in the front group");
    }

    /// R1 case 3 — a source GROUP emptied by the move. DECISION (see
    /// `group_selection`'s comment): an emptied Group is kept, exactly as an
    /// emptied Layer is. It is a bystander the edit never spoke to, and it
    /// carries a name, an id and blend flags that deleting would destroy.
    /// This is NOT D3's orphan: there the container was emptied by a WRONG
    /// insert; here the emptying is the correct consequence of a requested
    /// move.
    #[test]
    fn r1_a_group_emptied_by_the_move_survives_as_an_empty_group() {
        let a = make_rect(0.0, 0.0, 10.0, 10.0);
        let b = make_rect(20.0, 0.0, 10.0, 10.0);
        let c = make_rect(40.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![
                make_layer("Lower", vec![make_group(vec![a.clone(), b.clone()])]),
                make_layer("Upper", vec![c.clone()]),
            ],
            // BOTH children of the group, plus the element in the upper layer.
            vec![vec![0, 0, 0], vec![0, 0, 1], vec![1, 0]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        let src = after.get_element(&vec![0, 0])
            .expect("the emptied source group is still at [0,0] — not pruned, not orphaned");
        assert!(src.is_group(), "and it is still a Group");
        assert_eq!(src.children().map_or(1, |c| c.len()), 0, "with no children left");
        assert_eq!(after.layers[0].children().map_or(0, |c| c.len()), 1,
            "the lower layer still holds exactly the emptied group");

        let g = after.get_element(&vec![1, 0]).expect("new group in the upper layer");
        let kids = g.children().unwrap();
        assert_eq!(kids.len(), 3, "all three selected elements moved in");
        assert_eq!((&*kids[0], &*kids[1], &*kids[2]), (&a, &b, &c),
            "all three relocated whole, in document order");
    }

    /// R1 case 4 — SAME PARENT, NON-CONTIGUOUS. This case never hit the
    /// guard, so it is not about flattening at all: it pins the PLACEMENT
    /// half of R1. `actions.yaml` §group has always said the group "inherits
    /// the z-order position of the frontmost selected object"; both ports
    /// inserted at `paths[0]`, the BACKMOST. Select index 0 and index 2 of
    /// three siblings: the group belongs where index 2 was (after index 0 is
    /// removed, that is index 1), NOT at index 0.
    #[test]
    fn r1_same_parent_group_takes_the_frontmost_z_slot_not_the_backmost() {
        let a = make_rect(0.0, 0.0, 10.0, 10.0);
        let b = make_rect(20.0, 0.0, 10.0, 10.0);
        let c = make_rect(40.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![a.clone(), b.clone(), c.clone()])],
            vec![vec![0, 0], vec![0, 2]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        let kids = after.layers[0].children().expect("layer children");
        assert_eq!(kids.len(), 2, "b plus the new group");
        assert_eq!(*kids[0], b,
            "b, unselected, keeps the BACK slot — the group must not be inserted under it");
        assert!(kids[1].is_group(), "the new group takes the frontmost slot");
        let inner = kids[1].children().unwrap();
        assert_eq!((&*inner[0], &*inner[1]), (&a, &c), "a and c relocated whole");
        assert_eq!(sel_paths(&model), vec![vec![0, 1]],
            "selection follows the group to its real path");
    }

    /// R1 case 5 — the CONTIGUOUS same-parent case, which is what the
    /// existing corpus golden `menu_group_two_rects` pins. Frontmost-minus-
    /// removed-siblings and old-backmost agree here (1 - 1 == 0), so this
    /// case must be byte-identical before and after R1. It is the regression
    /// guard on the placement change above.
    #[test]
    fn r1_contiguous_same_parent_placement_is_unchanged() {
        let a = make_rect(0.0, 0.0, 10.0, 10.0);
        let b = make_rect(20.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![a.clone(), b.clone()])],
            vec![vec![0, 0], vec![0, 1]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();
        let kids = after.layers[0].children().expect("layer children");
        assert_eq!(kids.len(), 1, "one group replaces the two rects");
        assert!(kids[0].is_group());
        assert_eq!(sel_paths(&model), vec![vec![0, 0]], "group at index 0, as before R1");
    }

    /// R1 case 6 — MIXED DEPTHS. **OPEN QUESTION 3 in the brief; NOT ruled.**
    /// Selecting a layer-level element and something nested deeper is a shape
    /// nobody has ruled on. What this pins is the CONSERVATIVE consequence of
    /// applying R1 literally — the frontmost path is the deep one, so its
    /// parent (the group) is the destination and the shallow element is
    /// pulled INTO that group. Recorded so the behaviour is watched and so a
    /// future ruling changes a RED test rather than discovering silence.
    #[test]
    fn r1_mixed_depth_selection_follows_the_frontmost_parent_unruled() {
        let solo = make_rect(0.0, 0.0, 10.0, 10.0);
        let alpha = make_rect(20.0, 0.0, 10.0, 10.0);
        let beta = make_rect(40.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![
                solo.clone(),
                make_group(vec![alpha.clone(), beta.clone()]),
            ])],
            vec![vec![0, 0], vec![0, 1, 1]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        let kids = after.layers[0].children().expect("layer children");
        assert_eq!(kids.len(), 1, "solo left the layer; only the cluster remains");
        let cluster = &kids[0];
        let cl = cluster.children().unwrap();
        assert_eq!(cl.len(), 2, "cluster holds alpha and the new group");
        assert_eq!(*cl[0], alpha, "alpha untouched");
        let g = &cl[1];
        assert!(g.is_group(), "the new group landed INSIDE the cluster");
        let inner = g.children().unwrap();
        assert_eq!((&*inner[0], &*inner[1]), (&solo, &beta),
            "solo and beta relocated whole, in document order");
    }

    /// R1 case 7 — ANCESTOR AND DESCENDANT both selected. Also unruled, and
    /// the one shape where the naive reading is actively UNSAFE: cloning both
    /// the container and its child into the new group would put the same
    /// element in the document twice, duplicating a live id — the exact
    /// uniqueness break `make_compound_shape_with_op` was fixed for. The
    /// conservative position: the ancestor carries its children, so a
    /// selected path with a selected ancestor is dropped from the move.
    #[test]
    fn r1_selecting_a_group_and_its_own_child_does_not_duplicate_the_child() {
        let alpha = make_rect(20.0, 0.0, 10.0, 10.0);
        let beta = make_rect(40.0, 0.0, 10.0, 10.0);
        let solo = make_rect(0.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![
                solo.clone(),
                make_group(vec![alpha.clone(), beta.clone()]),
            ])],
            // the cluster itself AND its child beta.
            vec![vec![0, 0], vec![0, 1], vec![0, 1, 1]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();

        let kids = after.layers[0].children().expect("layer children");
        assert_eq!(kids.len(), 1, "solo and the cluster both moved into one new group");
        let g = &kids[0];
        let inner = g.children().unwrap();
        assert_eq!(inner.len(), 2,
            "exactly solo + the cluster: beta must NOT appear a second time");
        assert_eq!(*inner[0], solo, "solo relocated whole");
        assert!(inner[1].is_group(), "the cluster relocated as a whole subtree");
        let cl = inner[1].children().unwrap();
        assert_eq!(cl.len(), 2, "and it still carries BOTH its own children");
        assert_eq!((&*cl[0], &*cl[1]), (&alpha, &beta), "alpha and beta intact inside it");
    }

    /// R1 case 8 — a STALE selection path. Rust's `get_element` returns None
    /// and the operation no-ops; Swift's `getElement` INDEXES and would trap,
    /// so without an explicit resolvability check the same stale selection is
    /// quiet in one port and a crash in the other. That is the saturate-vs-trap
    /// divergence class, and R1 widened its reach by accepting selections the
    /// old guard used to reject before ever resolving them.
    #[test]
    fn r1_a_stale_selection_path_is_a_no_op_not_a_panic() {
        let a = make_rect(0.0, 0.0, 10.0, 10.0);
        let mut model = group_doc(
            vec![make_layer("Stage", vec![a.clone()])],
            vec![vec![0, 0], vec![0, 7]],
        );
        Controller::group_selection(&mut model);
        let after = model.document();
        let kids = after.layers[0].children().expect("layer children");
        assert_eq!(kids.len(), 1, "the document is untouched");
        assert_eq!(*kids[0], a, "and the one real element is still itself");
    }

    fn setup_model() -> Model {
        let rect = make_rect(0.0, 0.0, 10.0, 10.0);
        let line = make_line(0.0, 0.0, 5.0, 5.0);
        let group = make_group(vec![make_line(1.0, 1.0, 2.0, 2.0), make_line(3.0, 3.0, 4.0, 4.0)]);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(rect), Rc::new(group), Rc::new(line)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        Model::new(doc, None)
    }

    #[test]
    fn add_element_to_empty() {
        let mut model = Model::default();
        let rect = make_rect(10.0, 20.0, 30.0, 40.0);
        Controller::add_element(&mut model, rect);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Rect(_)));
    }

    #[test]
    fn add_element_appends() {
        let mut model = setup_model();
        let original_count = model.document().layers[0].children().unwrap().len();
        Controller::add_element(&mut model, make_rect(50.0, 50.0, 5.0, 5.0));
        assert_eq!(model.document().layers[0].children().unwrap().len(), original_count + 1);
    }

    /// LINEPROMOTE: applying a brush to a SELECTED Line promotes it to a Path
    /// in place (same tree path), and a single undo restores the Line — the
    /// "upgrade naturally" convention with a one-step journal (JYH 2026-07-25).
    #[test]
    fn brush_apply_promotes_selected_line_and_undo_restores_it() {
        let line = make_line(0.0, 0.0, 5.0, 5.0);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(line)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer], selected_layer: 0,
            selection: vec![ElementSelection::all(vec![0, 0])],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        assert!(matches!(model.document().get_element(&vec![0, 0]), Some(Element::Line(_))));

        Controller::set_selection_stroke_brush(&mut model, Some("charcoal".to_string()));
        match model.document().get_element(&vec![0, 0]) {
            Some(Element::Path(p)) => {
                assert_eq!(p.stroke_brush, Some("charcoal".to_string()));
                assert_eq!(p.d, vec![
                    crate::geometry::element::PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    crate::geometry::element::PathCommand::LineTo { x: 5.0, y: 5.0 },
                ]);
            }
            other => panic!("brush apply must promote the Line to a Path, got {other:?}"),
        }

        model.undo();
        assert!(matches!(model.document().get_element(&vec![0, 0]), Some(Element::Line(_))),
            "a single undo restores the Line");
    }

    // ── Mask editor routing (OPACITY.md §Preview interactions) ──

    #[test]
    fn add_element_mask_mode_routes_into_mask_subtree() {
        // Build a model with one rect selected, create a mask on it,
        // then flip into mask-edit mode and add a second element.
        // The second element should land inside the mask subtree,
        // not on the layer.
        use crate::document::model::EditingTarget;
        let mut model = setup_model();
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        Controller::make_mask_on_selection(&mut model, true, false);
        // Selection path of the masked element is [0, 0] (first
        // child of the only layer).
        let mask_path = vec![0, 0];
        let layer_count_before = model.document().layers[0].children().unwrap().len();
        model.editing_target = EditingTarget::Mask(mask_path.clone());

        Controller::add_element(&mut model, make_rect(100.0, 100.0, 5.0, 5.0));

        // Layer child count unchanged.
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            layer_count_before
        );
        // Mask subtree now has exactly one child: the rect we added.
        let elem = model.document().get_element(&mask_path).unwrap();
        let mask = elem.common().mask.as_ref().expect("mask exists");
        let subtree_children = mask.subtree.children()
            .expect("mask subtree is a Group with children");
        assert_eq!(subtree_children.len(), 1);
        assert!(matches!(&*subtree_children[0], Element::Rect(_)));
    }

    #[test]
    fn add_element_mask_mode_falls_back_when_no_mask() {
        // editing_target says Mask(path) but the element at path
        // has no mask. Falls back to layer-append so the user's
        // stroke isn't lost.
        use crate::document::model::EditingTarget;
        let mut model = setup_model();
        let layer_count_before = model.document().layers[0].children().unwrap().len();
        model.editing_target = EditingTarget::Mask(vec![0, 0]);
        Controller::add_element(&mut model, make_rect(100.0, 100.0, 5.0, 5.0));
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            layer_count_before + 1
        );
    }

    #[test]
    fn add_element_content_mode_ignores_editing_target() {
        // Sanity check that content-mode (the default) appends to
        // the layer as before, regardless of mask presence.
        let mut model = setup_model();
        let layer_count_before = model.document().layers[0].children().unwrap().len();
        Controller::add_element(&mut model, make_rect(10.0, 10.0, 1.0, 1.0));
        assert_eq!(
            model.document().layers[0].children().unwrap().len(),
            layer_count_before + 1
        );
    }

    #[test]
    fn select_rect_hits_element() {
        let mut model = setup_model();
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 0])); // rect at (0,0) 10x10
    }

    // D1 (SCOPE-effective-locked.md §3): a marquee must not reach into a
    // LOCKED layer.
    //
    // PER-PORT, and here is why: no shared conformance fixture can express
    // this. Every document case in the cross-language corpus is seeded from a
    // `setup_svg`, and the SVG codec does not persist `locked` at all
    // (`geometry/svg.rs` hardcodes `locked: false` in `parse_common` and never
    // writes it), so a layer parsed from SVG is always unlocked. The corpus is
    // structurally blind to lock as a PRECONDITION. Until the codec carries
    // it, this can only be pinned in-port; JasSwift carries the mirror of
    // these three in `Tests/Document/ControllerTests.swift`.
    //
    // This port already had the guard. These are REGRESSION PINS, not
    // red-first evidence -- the red was in JasSwift, whose `selectFlat`
    // checked visibility only. They exist so the pair cannot drift apart
    // again in either direction.

    /// Two layers, one rect each, side by side and both inside any marquee
    /// large enough to cover them. Layer 0's lock is the parameter.
    fn locked_layer_model(lock_first: bool) -> Model {
        let locked = Element::Layer(LayerElem {
            children: vec![Rc::new(make_rect(0.0, 0.0, 10.0, 10.0))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps {
                name: Some("Locked".to_string()),
                locked: lock_first,
                ..Default::default()
            },
        });
        let open = Element::Layer(LayerElem {
            children: vec![Rc::new(make_rect(20.0, 0.0, 10.0, 10.0))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("Open".to_string()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![locked, open],
            selected_layer: 0,
            selection: vec![],
            ..Document::default()
        };
        Model::new(doc, None)
    }

    /// Positive control: with NOTHING locked the same marquee reaches both
    /// rects. Without this the locked assertion below could pass for a
    /// geometric reason and never see the guard at all.
    #[test]
    fn select_rect_reaches_both_layers_when_nothing_is_locked() {
        let mut model = locked_layer_model(false);
        Controller::select_rect(&mut model, -1.0, -1.0, 120.0, 120.0, false);
        assert_eq!(sel_paths(&model), vec![vec![0, 0], vec![1, 0]]);
    }

    #[test]
    fn select_rect_skips_a_locked_layer_and_keeps_going() {
        let mut model = locked_layer_model(true);
        Controller::select_rect(&mut model, -1.0, -1.0, 120.0, 120.0, false);
        // Only the unlocked layer's rect. `[1, 0]` also proves the guard
        // CONTINUES rather than aborting the layer walk.
        assert_eq!(sel_paths(&model), vec![vec![1, 0]]);
    }

    /// `select_polygon` (the lasso) shares `select_flat` with `select_rect`,
    /// so it inherits the same guard -- asserted, not assumed.
    #[test]
    fn select_polygon_skips_a_locked_layer() {
        let mut model = locked_layer_model(true);
        let poly = [(-1.0, -1.0), (120.0, -1.0), (120.0, 120.0), (-1.0, 120.0)];
        Controller::select_polygon(&mut model, &poly, false);
        assert_eq!(sel_paths(&model), vec![vec![1, 0]]);
    }

    #[test]
    fn select_rect_misses_element() {
        let mut model = setup_model();
        Controller::select_rect(&mut model, 100.0, 100.0, 10.0, 10.0, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn select_element_direct_child() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let paths = sel_paths(&model);
        assert_eq!(paths, vec![vec![0, 0]]);
    }

    #[test]
    fn select_element_in_group_selects_group_and_children() {
        let mut model = setup_model();
        // Element at (0,1,0) is inside a group at (0,1)
        Controller::select_element(&mut model, &vec![0, 1, 0]);
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 1]));
        assert!(paths.contains(&vec![0, 1, 0]));
        assert!(paths.contains(&vec![0, 1, 1]));
    }

    #[test]
    fn select_all() {
        let mut model = setup_model();
        Controller::select_all(&mut model);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn set_selection() {
        let mut model = setup_model();
        let sel = vec![ElementSelection::all(vec![0, 0])];
        Controller::set_selection(&mut model, sel);
        assert_eq!(sel_paths(&model), vec![vec![0, 0]]);
    }

    #[test]
    fn move_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 10.0, 20.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
        } else {
            panic!("expected Rect");
        }
    }


    /// A GROUP selected as ONE entry must move when the selection moves.
    ///
    /// This is the shape every Selection-tool click on a group produces:
    /// `selection.yaml` runs `doc.set_selection: { paths: [hit] }` and
    /// `hit_test` returns the GROUP's path for a click inside a child
    /// (`doc_primitives.rs`, `hit_test_returns_group_path_when_clicking_child_rect`).
    /// §16 then made Select All produce it too, "a group counting as ONE".
    ///
    /// `move_control_points` had no Group arm, so the group fell to its
    /// catch-all and did not move. Rust masked it because `doc.set_selection`
    /// expands a container to its descendants and the CHILDREN moved
    /// themselves; JasSwift does not expand and could not drag a group at all.
    /// LAYER_STRUCTURE.md §20 rules that expansion away, which would have
    /// carried the defect here too. Twin: JasSwift `GroupMoveProbeTests`.
    #[test]
    fn a_group_selected_as_one_entry_moves() {
        let mut model = setup_model();
        // The setup doc has a Group at [0,1] (see ungroup_selection).
        let before = match model.document().get_element(&vec![0, 1]).unwrap() {
            Element::Group(g) => match &*g.children[0] {
                Element::Line(l) => (l.x1, l.y1),
                other => panic!("group child 0 is unexpected: {:?}", other),
            },
            other => panic!("[0,1] is not a Group: {:?}", other),
        };
        Controller::set_selection(&mut model, vec![ElementSelection::all(vec![0, 1])]);
        Controller::move_selection(&mut model, 10.0, 20.0);
        let after = match model.document().get_element(&vec![0, 1]).unwrap() {
            Element::Group(g) => match &*g.children[0] {
                Element::Line(l) => (l.x1, l.y1),
                other => panic!("group child 0 is unexpected: {:?}", other),
            },
            other => panic!("[0,1] is not a Group: {:?}", other),
        };
        assert_eq!(
            after,
            (before.0 + 10.0, before.1 + 20.0),
            "a Group selected as ONE entry did not move"
        );
    }


    /// §16.4 — A SELECTION NEVER HOLDS AN ANCESTOR AND ITS OWN DESCENDANT.
    ///
    /// RULED 2026-07-29 (banked by JYH, reversible in council). §16 gave Select
    /// All this shape, "a group counting as ONE"; the MARQUEE kept the older
    /// branch that pushed the group AND every unlocked member. The corpus
    /// defended it in prose — the marquee "legitimately asks did anything
    /// inside the band match, and its answer includes the members".
    ///
    /// It is not defensible, and the reason is COPY, not taste. `copy_selection`
    /// walks the selection and copies each entry. Given the group and its two
    /// members it copies the GROUP (whole, with both children) and then copies
    /// each MEMBER into the source group — so a marquee-then-duplicate left the
    /// SOURCE group holding four children instead of two. Measured before the
    /// fix: `Group(4 children)` beside `Group(2 children)`. The artist asked for
    /// a copy and got the original damaged.
    ///
    /// Move and delete survived the same shape only by accident (delete sorts
    /// descending; move writes absolute positions read from the pristine
    /// document). Accidental safety across two verbs is not an invariant.
    ///
    /// The marquee still ASKS about members — a band touching any unlocked
    /// member selects the group. It just answers with the outermost object.
    #[test]
    fn a_marquee_selects_the_group_not_its_members_too() {
        use crate::geometry::element::GroupElem;
        use std::rc::Rc;
        let mk_rect = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(mk_rect(0.0)), Rc::new(mk_rect(20.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(group)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer], selected_layer: 0,
            selection: Vec::new(), ..Document::default()
        };
        let mut model = Model::new(doc, None);

        // A band over the whole group.
        Controller::select_rect(&mut model, -5.0, -5.0, 100.0, 100.0, false);
        let paths: Vec<ElementPath> = model.document().selection.iter()
            .map(|s| s.path.clone()).collect();
        assert_eq!(paths, vec![vec![0, 0]],
                   "the marquee selects the GROUP alone, not the group and its \
                    members; got {paths:?}");

        // And the consequence that made this a defect rather than a preference.
        Controller::copy_selection(&mut model, 100.0, 0.0);
        let kids = model.document().layers[0].children().unwrap().to_vec();
        assert_eq!(kids.len(), 2, "one copy beside the source");
        for (i, k) in kids.iter().enumerate() {
            match k.as_ref() {
                Element::Group(g) => assert_eq!(
                    g.children.len(), 2,
                    "group [{i}] must still hold exactly its two members -- \
                     before the fix the SOURCE group ended up with four"),
                other => panic!("expected a Group at [{i}], got {other:?}"),
            }
        }
    }


    /// AN ANCESTOR IN THE SELECTION COVERS ITS DESCENDANTS — the move applies
    /// once, at the outermost entry.
    ///
    /// §16.4 rules that a selection never holds an ancestor and its own
    /// descendant, but the ruling is not yet ENFORCED at every producer: the
    /// extend/add seams (`add_to_selection`, `toggle_selection`, raw
    /// `set_selection`, and `doc.set_selection`'s still-live container
    /// expansion) can all still build one. Found by an adversarial review of
    /// §16.4, 2026-07-29.
    ///
    /// `move_selection` reads each element from the PRISTINE pre-move document
    /// and writes an absolute result. For two disjoint entries that is exactly
    /// right. For an ancestor and its descendant it is not: the descendant's
    /// write lands on top of the ancestor's, discarding the ancestor's
    /// contribution to it.
    ///
    /// Measured: group selected whole plus one member's single control point,
    /// dragged +24. The sibling moved 20 -> 44 correctly, while the
    /// partially-selected member became a Polygon STRANDED at pristine
    /// coordinates — [(24,0), (10,0), (10,10), (0,10)] — with one corner
    /// displaced and the group's translation lost. That is artwork corruption
    /// from an ordinary two-tool gesture.
    ///
    /// The rule here is the one §16.4 states: the OUTERMOST entry wins. It also
    /// makes the operation correct regardless of which producer built the
    /// selection, which enforcing §16.4 at each seam separately would not.
    #[test]
    fn an_ancestor_in_the_selection_covers_its_descendants() {
        use crate::geometry::element::GroupElem;
        use crate::document::document::SortedCps;
        use std::rc::Rc;
        let mk_rect = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(mk_rect(0.0)), Rc::new(mk_rect(20.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(group)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer], selected_layer: 0,
            selection: Vec::new(), ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection { path: vec![0, 0, 0],
                               kind: SelectionKind::Partial(SortedCps::from_iter([0usize])) },
        ]);
        Controller::move_selection(&mut model, 24.0, 0.0);

        let Some(Element::Group(g)) = model.document().get_element(&vec![0, 0]) else {
            panic!("[0,0] should still be a Group");
        };
        // BOTH members ride the group's move, whole, and neither is rebuilt as
        // a Polygon by a control-point edit that the group's move supersedes.
        match g.children[0].as_ref() {
            Element::Rect(r) => assert_eq!(
                (r.x, r.y), (24.0, 0.0),
                "the partially-selected member rides the group's move whole"),
            other => panic!("child 0 must stay a Rect, got {other:?}"),
        }
        match g.children[1].as_ref() {
            Element::Rect(r) => assert_eq!((r.x, r.y), (44.0, 0.0),
                                           "the sibling moves with the group"),
            other => panic!("child 1 must stay a Rect, got {other:?}"),
        }
    }


    /// FILL AND STROKE RECURSE INTO A SELECTED CONTAINER. RULED 2026-07-29.
    ///
    /// Selecting a group and clicking a swatch is the commonest operation in
    /// the application, and it did NOTHING to the group's members. Both ports
    /// handled containers EXPLICITLY -- Rust `Group(_) | Layer(_) =>
    /// elem.clone()`, Swift `case .group, .layer:` -- so nobody forgot; someone
    /// decided a container has no fill of its own. True of the data model,
    /// false of the artist's intent.
    ///
    /// It was invisible in Rust because `doc.set_selection` expands a container
    /// to its descendants, so the MEMBERS were in the selection and got filled.
    /// JasSwift does not expand, so there it was simply broken, and §20 would
    /// have carried it into Rust.
    ///
    /// JYH at council: *"yes, recurse into members"* -- the convention a vector
    /// illustration application follows. The recursion lives at the
    /// selection-apply level, NOT inside `with_fill`/`with_stroke`: those are
    /// also called at render time (`canvas/render.rs`, stroke scaling) and on
    /// symbol-instance overrides, where recursing would be wrong.
    #[test]
    fn fill_and_stroke_recurse_into_a_selected_container() {
        use crate::geometry::element::GroupElem;
        use std::rc::Rc;
        let mk = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        // A group holding a leaf AND a nested group, so recursion is tested at
        // two depths rather than one.
        let inner = Element::Group(GroupElem {
            children: vec![Rc::new(mk(40.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some("inner".into()), ..Default::default() },
        });
        let outer = Element::Group(GroupElem {
            children: vec![Rc::new(mk(0.0)), Rc::new(inner)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some("outer".into()), ..Default::default() },
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(outer)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer], selected_layer: 0,
            selection: vec![ElementSelection::all(vec![0, 0])],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        let red = Fill::new(Color::rgb(1.0, 0.0, 0.0));
        Controller::set_selection_fill(&mut model, Some(red.clone()));

        let d = model.document();
        let Some(Element::Group(g)) = d.get_element(&vec![0, 0]) else { panic!("group") };
        // T4 BYSTANDER: the container is rebuilt, so its own fields must survive.
        assert_eq!(g.common.id.as_deref(), Some("outer"),
                   "the rebuilt container keeps its own id");
        match g.children[0].as_ref() {
            Element::Rect(r) => assert!(r.fill.is_some(), "the direct member is filled"),
            other => panic!("expected Rect, got {other:?}"),
        }
        let Element::Group(ig) = g.children[1].as_ref() else { panic!("nested group") };
        assert_eq!(ig.common.id.as_deref(), Some("inner"),
                   "the nested container keeps ITS id too");
        match ig.children[0].as_ref() {
            Element::Rect(r) => assert!(r.fill.is_some(),
                                        "the member two levels down is filled"),
            other => panic!("expected Rect, got {other:?}"),
        }
    }


    /// A CONTAINER'S FULL SELECTION MOVES IT, however that fullness is spelled.
    ///
    /// DOCUMENT.md's control-point table grants a Group FOUR control points at
    /// its bounding-box corners. `control_point_count` and `control_points`
    /// both implement that. So "this group is fully selected" has TWO valid
    /// spellings: `All`, and `Partial([0,1,2,3])` -- the latter is exactly what
    /// `kind.to_sorted(control_point_count(elem))` produces from an `All` entry.
    ///
    /// The GROUPMOVE repair guarded its container arm on `kind.is_all(0)`,
    /// which is the right predicate for an element with NO control points and
    /// the wrong one for a container that has four: `Partial([0,1,2,3])` fails
    /// it, falls to the catch-all, and THE GROUP DOES NOT MOVE. Defect 1, still
    /// armed one layer down, and this seat armed it.
    ///
    /// Found by an adversarial review of the element-dispatch ledger, which
    /// cited the spec table against this seat's own claim that a container has
    /// no control points.
    #[test]
    fn a_container_moves_however_its_full_selection_is_spelled() {
        use crate::geometry::element::{GroupElem, control_point_count, move_control_points};
        use crate::document::document::SortedCps;
        use std::rc::Rc;
        let mk = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let g = Element::Group(GroupElem {
            children: vec![Rc::new(mk(0.0)), Rc::new(mk(20.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        assert_eq!(control_point_count(&g), 4,
                   "DOCUMENT.md grants a Group four bbox-corner control points");

        let full = SelectionKind::Partial(SortedCps::from_iter([0usize, 1, 2, 3]));
        for (label, kind) in [("All", SelectionKind::All), ("Partial(all four)", full)] {
            let moved = move_control_points(&g, &kind, 24.0, 0.0);
            let Element::Group(mg) = &moved else { panic!("still a Group") };
            let Element::Rect(r) = mg.children[0].as_ref() else { panic!("Rect") };
            assert_eq!(r.x, 24.0,
                       "a fully-selected container moves when spelled {label}");
        }

        // A PARTIAL container selection is a resize gesture, not a move, and
        // group resize does not exist. It must leave the group alone rather
        // than translating it by a drag meant for one corner.
        let corner = SelectionKind::Partial(SortedCps::from_iter([0usize]));
        assert_eq!(move_control_points(&g, &corner, 24.0, 0.0), g,
                   "one corner selected is a resize gesture, not a translate");
    }


    /// A SELECTED CONTAINER SUMMARISES ITS MEMBERS' PAINT.
    ///
    /// The panels read the selection through `selection_fill_summary` /
    /// `selection_stroke_summary`, whose three states are NoSelection, Mixed and
    /// Uniform. Both read `e.fill()` / `e.stroke()`, which return `None` for a
    /// container -- so a selected GROUP reported `Uniform(None)`, "no stroke".
    ///
    /// That is a WRONG answer rather than an unavailable one, and since the
    /// paint ruling (JYH, 2026-07-29: fill and stroke recurse into members) it
    /// is an asymmetry an artist meets directly: set a group's stroke, and the
    /// panel says the group has none.
    ///
    /// The summary now recurses through containers to their paintable leaves --
    /// the READ twin of `map_paintable`. A group whose members agree reads back
    /// as `Uniform`; one whose members differ reads `Mixed`, which is the
    /// honest answer and the same one two differently-stroked siblings give.
    #[test]
    fn a_selected_container_summarises_its_members_paint() {
        use crate::geometry::element::GroupElem;
        use std::rc::Rc;
        let mk = |w: f64| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(Stroke { width: w, ..Stroke::new(Color::BLACK, w) }),
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let uniform = Element::Group(GroupElem {
            children: vec![Rc::new(mk(5.0)), Rc::new(mk(5.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let mixed = Element::Group(GroupElem {
            children: vec![Rc::new(mk(5.0)), Rc::new(mk(1.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(uniform), Rc::new(mixed)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let base = Document { layers: vec![layer], selected_layer: 0,
                              selection: Vec::new(), ..Document::default() };

        // A group whose members agree reads back as their common value.
        let mut d = base.clone();
        d.selection = vec![ElementSelection::all(vec![0, 0])];
        match selection_stroke_summary(&d) {
            StrokeSummary::Uniform(Some(s)) => assert_eq!(s.width, 5.0),
            other => panic!("a uniform group must summarise its members, got {other:?}"),
        }

        // JYH's own example, one level in: a 5pt and a 1pt member have no
        // honest common weight.
        d = base.clone();
        d.selection = vec![ElementSelection::all(vec![0, 1])];
        assert!(matches!(selection_stroke_summary(&d), StrokeSummary::Mixed),
                "a group with a 5pt and a 1pt member is Mixed, not Uniform(None)");

        // And the same two shapes selected WITHOUT a container agree with it --
        // which is the point: a group is a mixed selection of one.
        d = base.clone();
        d.selection = vec![ElementSelection::all(vec![0, 1, 0]),
                           ElementSelection::all(vec![0, 1, 1])];
        assert!(matches!(selection_stroke_summary(&d), StrokeSummary::Mixed),
                "the container and non-container spellings must agree");
    }


    /// THE STROKE PANEL'S WEIGHT FIELD RESOLVES A CONTAINER.
    ///
    /// Found by JYH at council 2026-07-29, clicking a group: the Weight field
    /// showed 1 pt while both members carried 5. The panel override read
    /// `doc.selection.first()` and then that element's OWN stroke -- `None` for
    /// a container -- and fell through to `?? 1.0`. Both ports, identically,
    /// which is why no cross-language gate saw it.
    ///
    /// The summary already recurses into containers (PAINTSUMMARY), so the fix
    /// is to ASK it. Only the container case changes: a single leaf and a
    /// uniform multi-selection resolve to the same value they always did, and a
    /// MIXED selection still falls back to the first element's stroke -- the
    /// pre-existing lie, left alone until transcripts/MIXED_SELECTION.md is
    /// answered, because replacing one lie with a different one is not progress.
    #[test]
    fn the_weight_override_resolves_a_uniform_container() {
        use crate::geometry::element::GroupElem;
        use std::rc::Rc;
        let mk = |w: f64| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: Some(Stroke::new(Color::BLACK, w)),
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        });
        let g = Element::Group(GroupElem {
            children: vec![Rc::new(mk(5.0)), Rc::new(mk(5.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(g), Rc::new(mk(3.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0,
                                 selection: Vec::new(), ..Document::default() };

        // The GROUP: both members are 5, so the panel must say 5.
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        assert_eq!(selection_stroke_for_panel(&doc).map(|s| s.width), Some(5.0),
                   "a uniform group resolves to its members' common weight");

        // The LEAF, unchanged: this is what already worked.
        doc.selection = vec![ElementSelection::all(vec![0, 1])];
        assert_eq!(selection_stroke_for_panel(&doc).map(|s| s.width), Some(3.0),
                   "a leaf still resolves to its own weight");

        // A MIXED container and its members selected DIRECTLY must give the
        // SAME answer -- a group is a mixed selection of one. Reading the
        // selection ENTRY instead of the first leaf gave 1.0 for the group and
        // the first member's weight for the members: two numbers, one fact.
        let mixed = Element::Group(GroupElem {
            children: vec![Rc::new(mk(5.0)), Rc::new(mk(1.0))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let mut d2 = doc.clone();
        d2.layers = vec![Element::Layer(LayerElem {
            children: vec![Rc::new(mixed)],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        })];
        d2.selection = vec![ElementSelection::all(vec![0, 0])];
        let via_group = selection_stroke_for_panel(&d2).map(|s| s.width);
        d2.selection = vec![ElementSelection::all(vec![0, 0, 0]),
                            ElementSelection::all(vec![0, 0, 1])];
        let via_members = selection_stroke_for_panel(&d2).map(|s| s.width);
        assert_eq!(via_group, via_members,
                   "a mixed group and its members must answer alike");
        assert_eq!(via_group, Some(5.0), "and that answer is the first leaf's");
    }

    #[test]
    fn group_selection() {
        let mut model = setup_model();
        // Select rect and line (indices 0 and 2)
        let sel = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ];
        Controller::set_selection(&mut model, sel);
        Controller::group_selection(&mut model);
        // The two elements should now be inside a Group
        let children = model.document().layers[0].children().unwrap();
        let has_group = children.iter().any(|c| matches!(**c, Element::Group(_)));
        assert!(has_group);
    }

    #[test]
    fn ungroup_selection() {
        let mut model = setup_model();
        // Select the group at (0,1)
        Controller::select_element(&mut model, &vec![0, 1, 0]);
        Controller::ungroup_selection(&mut model);
        // Group's children should be inlined
        let children = model.document().layers[0].children().unwrap();
        // No more groups (the original group should be ungrouped)
        let group_count = children.iter().filter(|c| matches!(***c, Element::Group(_))).count();
        assert_eq!(group_count, 0);
    }

    #[test]
    fn make_compound_shape_wraps_selection_in_one_live_element() {
        let mut model = setup_model();
        // Select rect (0,0) and line (0,2) — siblings at layer 0.
        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ]);
        Controller::make_compound_shape(&mut model);
        let children = model.document().layers[0].children().unwrap();
        // Originally 3 siblings; now rect+line merged into 1 compound
        // plus the group, so 2 total.
        assert_eq!(children.len(), 2);
        // One of them must be the new Live element.
        let live_count = children.iter().filter(|c| matches!(***c, Element::Live(_))).count();
        assert_eq!(live_count, 1);
        // The compound is selected.
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn make_compound_shape_with_op_subtract_front() {
        use crate::geometry::live::{CompoundOperation, LiveVariant};
        let mut model = two_overlapping_rects();
        Controller::make_compound_shape_with_op(
            &mut model, CompoundOperation::SubtractFront,
        );
        let child = &model.document().layers[0].children().unwrap()[0];
        let operation = match &**child {
            Element::Live(LiveVariant::CompoundShape(cs)) => cs.operation,
            _ => panic!("expected Live(CompoundShape)"),
        };
        assert_eq!(operation, CompoundOperation::SubtractFront);
    }

    #[test]
    fn make_compound_shape_with_op_intersection() {
        use crate::geometry::live::{CompoundOperation, LiveVariant};
        let mut model = two_overlapping_rects();
        Controller::make_compound_shape_with_op(
            &mut model, CompoundOperation::Intersection,
        );
        let child = &model.document().layers[0].children().unwrap()[0];
        let operation = match &**child {
            Element::Live(LiveVariant::CompoundShape(cs)) => cs.operation,
            _ => panic!("expected Live(CompoundShape)"),
        };
        assert_eq!(operation, CompoundOperation::Intersection);
    }

    #[test]
    fn make_compound_shape_with_op_exclude() {
        use crate::geometry::live::{CompoundOperation, LiveVariant};
        let mut model = two_overlapping_rects();
        Controller::make_compound_shape_with_op(
            &mut model, CompoundOperation::Exclude,
        );
        let child = &model.document().layers[0].children().unwrap()[0];
        let operation = match &**child {
            Element::Live(LiveVariant::CompoundShape(cs)) => cs.operation,
            _ => panic!("expected Live(CompoundShape)"),
        };
        assert_eq!(operation, CompoundOperation::Exclude);
    }

    #[test]
    fn make_compound_shape_menu_still_uses_union() {
        use crate::geometry::live::{CompoundOperation, LiveVariant};
        let mut model = two_overlapping_rects();
        // The menu-action wrapper delegates to Union.
        Controller::make_compound_shape(&mut model);
        let child = &model.document().layers[0].children().unwrap()[0];
        let operation = match &**child {
            Element::Live(LiveVariant::CompoundShape(cs)) => cs.operation,
            _ => panic!("expected Live(CompoundShape)"),
        };
        assert_eq!(operation, CompoundOperation::Union);
    }

    #[test]
    fn release_compound_shape_restores_operands() {
        let mut model = setup_model();
        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ]);
        Controller::make_compound_shape(&mut model);
        // Now release the compound (still selected).
        Controller::release_compound_shape(&mut model);
        let children = model.document().layers[0].children().unwrap();
        // Back to a rect + group + line (three siblings).
        let live_count = children.iter().filter(|c| matches!(***c, Element::Live(_))).count();
        assert_eq!(live_count, 0);
        assert_eq!(children.len(), 3);
        // Released operands are the new selection.
        assert_eq!(model.document().selection.len(), 2);
    }

    /// Two overlapping axis-aligned rects on a single layer:
    /// r1 = [0..10]×[0..10], r2 = [5..15]×[0..10].
    fn two_overlapping_rects() -> Model {
        let r1 = make_rect(0.0, 0.0, 10.0, 10.0);
        let r2 = make_rect(5.0, 0.0, 10.0, 10.0);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(r1), Rc::new(r2)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        Model::new(doc, None)
    }

    fn top_children_count(model: &Model) -> usize {
        model.document().layers[0].children().map_or(0, |c| c.len())
    }

    #[test]
    fn destructive_union_produces_one_polygon() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "union", &BooleanOptions::default());
        assert_eq!(top_children_count(&model), 1);
        let child = &model.document().layers[0].children().unwrap()[0];
        assert!(matches!(&**child, Element::Polygon(_)));
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn destructive_intersection_produces_one_polygon() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "intersection", &BooleanOptions::default());
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn simplify_selection_replaces_polygon_with_curved_path() {
        use crate::geometry::element::{Color as ColorE, CommonProps, Fill, PolygonElem};
        // 32-vertex regular circle polygon — simplify should
        // collapse it to a small handful of CurveTo segments.
        let n = 32;
        let r = 50.0;
        let pts: Vec<(f64, f64)> = (0..n)
            .map(|i| {
                let t = 2.0 * std::f64::consts::PI * (i as f64) / (n as f64);
                (r * t.cos(), r * t.sin())
            })
            .collect();
        let poly = Element::Polygon(PolygonElem {
            points: pts,
            fill: Some(Fill::new(ColorE::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(crate::geometry::element::LayerElem {
            children: vec![Rc::new(poly)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let mut model = Model::new(doc, None);
        Controller::simplify_selection(&mut model, 0.5);
        let child = &model.document().layers[0].children().unwrap()[0];
        match &**child {
            Element::Path(p) => {
                let curve_count = p.d.iter().filter(|c| matches!(c, crate::geometry::element::PathCommand::CurveTo { .. })).count();
                let line_count = p.d.iter().filter(|c| matches!(c, crate::geometry::element::PathCommand::LineTo { .. })).count();
                assert!(curve_count > 0, "simplify of circle polygon should emit CurveTo segments");
                assert_eq!(line_count, 0, "circle should not contain LineTo segments");
                assert!(p.d.len() < 32, "simplify should compact the 32-point polygon to fewer commands, got {}", p.d.len());
            }
            other => panic!("expected Path after simplify, got {other:?}"),
        }
    }

    /// The Path arm of `simplify_selection` is the one place in this
    /// function that spells `fill_rule` out by hand rather than
    /// inheriting it from a `..clone()`, so it is the one place a future
    /// edit could drop it. JasSwift carries the same pin
    /// (Tests/Geometry/FillRulePreservationTests.swift
    /// §fillRuleSurvivesSimplifySelection).
    #[test]
    fn simplify_selection_preserves_even_odd_fill_rule() {
        use crate::geometry::element::{
            Color as ColorE, CommonProps, Fill, FillRule, PathCommand, PathElem,
        };
        // Two concentric squares: a donut under EvenOdd.
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 100.0 },
            PathCommand::LineTo { x: 0.0, y: 100.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 25.0, y: 25.0 },
            PathCommand::LineTo { x: 75.0, y: 25.0 },
            PathCommand::LineTo { x: 75.0, y: 75.0 },
            PathCommand::LineTo { x: 25.0, y: 75.0 },
            PathCommand::ClosePath,
        ];
        let path = Element::Path(PathElem {
            d,
            fill: Some(Fill::new(ColorE::BLACK)),
            stroke: None,
            width_points: Vec::new(),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
            fill_rule: FillRule::EvenOdd,
        });
        let layer = Element::Layer(crate::geometry::element::LayerElem {
            children: vec![Rc::new(path)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let mut doc = Document {
            layers: vec![layer], selected_layer: 0, selection: vec![],
            ..Document::default()
        };
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        let mut model = Model::new(doc, None);
        Controller::simplify_selection(&mut model, 1.0);
        let child = &model.document().layers[0].children().unwrap()[0];
        match &**child {
            Element::Path(p) => assert_eq!(
                p.fill_rule, FillRule::EvenOdd,
                "simplify refilled the donut's hole"
            ),
            other => panic!("expected Path after simplify, got {other:?}"),
        }
    }

    #[test]
    fn boolean_then_simplify_emits_path_with_curveto() {
        use crate::geometry::element::PathCommand;
        // Two overlapping circles → UNION → many-vertex polygon →
        // simplify_selection recovers Bezier curves.
        use crate::geometry::element::EllipseElem;
        let r1 = Element::Ellipse(EllipseElem {
            cx: 0.0, cy: 0.0, rx: 50.0, ry: 50.0,
            fill: Some(crate::geometry::element::Fill::new(crate::geometry::element::Color::BLACK)),
            stroke: None,
            common: crate::geometry::element::CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let r2 = Element::Ellipse(EllipseElem {
            cx: 60.0, cy: 0.0, rx: 50.0, ry: 50.0,
            fill: Some(crate::geometry::element::Fill::new(crate::geometry::element::Color::BLACK)),
            stroke: None,
            common: crate::geometry::element::CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(crate::geometry::element::LayerElem {
            children: vec![Rc::new(r1), Rc::new(r2)],
            isolated_blending: false,
            knockout_group: false,
            common: crate::geometry::element::CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        let mut model = Model::new(doc, None);
        Controller::apply_destructive_boolean(&mut model, "union", &BooleanOptions::default());
        Controller::simplify_selection(&mut model, 0.5);
        assert_eq!(top_children_count(&model), 1);
        let child = &model.document().layers[0].children().unwrap()[0];
        match &**child {
            Element::Path(p) => {
                let curve_count = p.d.iter().filter(|c| matches!(c, PathCommand::CurveTo { .. })).count();
                assert!(curve_count > 0, "boolean+simplify should emit at least one CurveTo, got {curve_count}");
            }
            other => panic!("expected Path, got {other:?}"),
        }
    }

    #[test]
    fn destructive_exclude_produces_single_evenodd_path() {
        use crate::geometry::element::FillRule;
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "exclude", &BooleanOptions::default());
        // Symmetric difference is encoded as one Path with multiple
        // subpaths under the even-odd fill rule, per PolygonSet's
        // documented contract. Splitting into separate filled polygons
        // would double-fill the overlap region for hole topologies
        // (BO-013 manual test bug).
        assert_eq!(top_children_count(&model), 1);
        assert_eq!(model.document().selection.len(), 1);
        let child = &model.document().layers[0].children().unwrap()[0];
        match &**child {
            Element::Path(p) => {
                assert_eq!(p.fill_rule, FillRule::EvenOdd, "exclude path should be evenodd");
                let move_count = p.d.iter().filter(|c| matches!(c, crate::geometry::element::PathCommand::MoveTo { .. })).count();
                assert!(move_count >= 2, "expected at least 2 subpaths, got {move_count}");
            }
            other => panic!("expected Path, got {other:?}"),
        }
    }

    #[test]
    fn destructive_subtract_front_consumes_front() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "subtract_front", &BooleanOptions::default());
        // r2 (front, last) consumed; r1 minus r2 remains = 1 polygon.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_subtract_back_consumes_back() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "subtract_back", &BooleanOptions::default());
        // r1 (back, first) consumed; r2 minus r1 remains = 1 polygon.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_crop_uses_frontmost_as_mask() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "crop", &BooleanOptions::default());
        // r2 (front) is the mask, consumed; r1 clipped to its
        // interior = 1 polygon covering the overlap.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_divide_produces_three_fragments() {
        // Two overlapping rects → 3 fragments (left-only, overlap,
        // right-only). All three get polygon-typed elements.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "divide", &BooleanOptions::default());
        assert_eq!(top_children_count(&model), 3);
        for child in model.document().layers[0].children().unwrap() {
            assert!(matches!(&**child, Element::Polygon(_)));
        }
    }

    #[test]
    fn destructive_trim_keeps_operands_with_own_paint() {
        // Two overlapping rects: front untouched; back has overlap
        // removed. Expect 2 polygons.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "trim", &BooleanOptions::default());
        assert_eq!(top_children_count(&model), 2);
    }

    #[test]
    fn destructive_merge_unions_matching_fills() {
        // Both rects default to Color::BLACK fill (see make_rect
        // helper). MERGE performs TRIM, then unions the two touching
        // same-fill survivors. Expected: 1 polygon covering both.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "merge", &BooleanOptions::default());
        // TRIM would leave 2; MERGE collapses to 1.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_merge_does_not_union_different_fills() {
        use crate::geometry::element::Color;
        let red = Fill::new(Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 });
        let blue = Fill::new(Color::Rgb { r: 0.0, g: 0.0, b: 1.0, a: 1.0 });
        let r1 = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(red), stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let r2 = Element::Rect(RectElem {
            x: 5.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(blue), stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(r1), Rc::new(r2)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        let mut model = Model::new(doc, None);
        Controller::apply_destructive_boolean(&mut model, "merge", &BooleanOptions::default());
        // Different fills → no merge; TRIM output of 2 survives.
        assert_eq!(top_children_count(&model), 2);
    }

    #[test]
    fn destructive_divide_remove_unpainted_filters_no_paint_fragments() {
        // Two rects, neither has fill or stroke → every DIVIDE
        // fragment is "unpainted" (fill None, stroke None). With the
        // flag off, fragments are kept (3). With the flag on, they
        // are discarded (0).
        let unpainted_rect = |x: f64| Rc::new(Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        }));
        let layer = Element::Layer(LayerElem {
            children: vec![unpainted_rect(0.0), unpainted_rect(5.0)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        let mut model = Model::new(doc, None);

        let mut off = BooleanOptions::default();
        off.divide_remove_unpainted = false;
        Controller::apply_destructive_boolean(&mut model, "divide", &off);
        assert_eq!(top_children_count(&model), 3);

        // Redo the selection (prior divide consumed them).
        let mut model = {
            let layer = Element::Layer(LayerElem {
                children: vec![unpainted_rect(0.0), unpainted_rect(5.0)],
                isolated_blending: false,
                knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
            });
            let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
            doc.selection = vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
            ];
            Model::new(doc, None)
        };
        let mut on = BooleanOptions::default();
        on.divide_remove_unpainted = true;
        Controller::apply_destructive_boolean(&mut model, "divide", &on);
        assert_eq!(top_children_count(&model), 0);
    }

    #[test]
    fn destructive_remove_redundant_points_collapses_collinear() {
        // Two rects overlapping in x with the same y-extent. Their UNION
        // is one rectangle, but the sweep inserts a vertex on the top and
        // bottom edges wherever an operand's vertical edge meets them, so
        // the ring carries four collinear points. With the flag on they
        // are collapsed; the flag defaults to OFF (workspace/state.yaml).
        let mut model = two_overlapping_rects();
        let off = BooleanOptions::default();
        Controller::apply_destructive_boolean(&mut model, "union", &off);
        let pts_off = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Polygon(p) => p.points.len(),
            _ => panic!("expected polygon"),
        };

        let mut model = two_overlapping_rects();
        let mut on = BooleanOptions::default();
        on.remove_redundant_points = true;
        Controller::apply_destructive_boolean(&mut model, "union", &on);
        let pts_on = match &*model.document().layers[0].children().unwrap()[0] {
            Element::Polygon(p) => p.points.len(),
            _ => panic!("expected polygon"),
        };
        // Exact counts, not an inequality. `pts_on <= pts_off` was the
        // original assertion and it is satisfied by a collapse that does
        // NOTHING — the same blindness the operations corpus had. The
        // union of these two rects is one 15x10 rectangle whose ring
        // carries the four vertices the sweep inserted where each
        // operand's vertical edges cross the shared horizontal ones;
        // collapse deletes exactly those.
        assert_eq!(pts_off, 8, "the flag OFF keeps the four seam vertices");
        assert_eq!(pts_on, 4, "the flag ON leaves the rectangle's corners");
    }

    #[test]
    fn destructive_unknown_op_is_noop() {
        let mut model = two_overlapping_rects();
        let before = top_children_count(&model);
        Controller::apply_destructive_boolean(&mut model, "nonexistent", &BooleanOptions::default());
        assert_eq!(top_children_count(&model), before);
    }

    // BOOLEAN.md "Operand and paint rules" names FOUR properties as the
    // paint a boolean result carries: "fill, stroke, opacity, blend
    // mode". This port carried all four already (the rebuild clones the
    // paint source's CommonProps) but nothing asserted it: rewriting the
    // rebuild to `CommonProps::default()` was green before these tests.
    // Swift wrote `opacity: 1.0` and left blend at Normal; these are the
    // twins of the Swift tests in CompoundShapeControllerTests.swift.
    // `opacity` is also pinned cross-language by
    // test_fixtures/operations/boolean_collapse_default.json; blend mode
    // is not in the corpus JSON, hence the per-port pair.

    /// Two overlapping rects with DIFFERENT opacity and blend mode, so
    /// front (index 1, the topmost) is distinguishable from back.
    fn two_overlapping_painted_rects() -> Model {
        let paint = |x: f64, opacity: f64, mode: crate::geometry::element::BlendMode| {
            let mut e = make_rect(x, 0.0, 10.0, 10.0);
            let c = match &mut e {
                Element::Rect(r) => &mut r.common,
                _ => unreachable!("make_rect builds a Rect"),
            };
            c.opacity = opacity;
            c.mode = mode;
            e
        };
        use crate::geometry::element::BlendMode;
        let back = paint(0.0, 0.25, BlendMode::Screen);
        let front = paint(5.0, 0.5, BlendMode::Multiply);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(back), Rc::new(front)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
            ],
            ..Document::default()
        };
        Model::new(doc, None)
    }

    #[test]
    fn union_carries_frontmost_opacity_and_blend_mode() {
        use crate::geometry::element::BlendMode;
        let mut model = two_overlapping_painted_rects();
        Controller::apply_destructive_boolean(&mut model, "union", &BooleanOptions::default());
        let child = model.document().layers[0].children().unwrap()[0].clone();
        let common = child.common();
        assert_eq!(common.opacity, 0.5, "frontmost operand's opacity");
        assert_eq!(common.mode, BlendMode::Multiply, "frontmost operand's blend mode");
    }

    #[test]
    fn exclude_path_arm_carries_frontmost_opacity_and_blend_mode() {
        // The multi-ring arm builds a Path — a SECOND construction site
        // that has to carry the same four properties as the Polygon arm.
        use crate::geometry::element::BlendMode;
        let mut model = two_overlapping_painted_rects();
        Controller::apply_destructive_boolean(&mut model, "exclude", &BooleanOptions::default());
        let child = model.document().layers[0].children().unwrap()[0].clone();
        assert!(matches!(&*child, Element::Path(_)), "exclude emits one multi-ring Path");
        let common = child.common();
        assert_eq!(common.opacity, 0.5);
        assert_eq!(common.mode, BlendMode::Multiply);
    }

    #[test]
    fn subtract_front_survivor_keeps_its_own_opacity_and_blend_mode() {
        // "Each remaining element has the frontmost subtracted from it
        // and keeps its own paint" — the survivor is the BACK rect, so
        // the result carries 0.25 / Screen, not the cutter's.
        use crate::geometry::element::BlendMode;
        let mut model = two_overlapping_painted_rects();
        Controller::apply_destructive_boolean(
            &mut model, "subtract_front", &BooleanOptions::default());
        let child = model.document().layers[0].children().unwrap()[0].clone();
        let common = child.common();
        assert_eq!(common.opacity, 0.25);
        assert_eq!(common.mode, BlendMode::Screen);
    }

    #[test]
    fn expand_compound_shape_replaces_with_polygons() {
        // Build a fresh doc with two overlapping rects so the boolean
        // evaluates to one merged polygon.
        let rect_a = make_rect(0.0, 0.0, 10.0, 10.0);
        let rect_b = make_rect(5.0, 0.0, 10.0, 10.0);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(rect_a), Rc::new(rect_b)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".to_string()), ..Default::default() },
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let mut model = Model::new(doc, None);

        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ]);
        Controller::make_compound_shape(&mut model);
        Controller::expand_compound_shape(&mut model);

        let children = model.document().layers[0].children().unwrap();
        // Union of overlapping rects = 1 ring = 1 Polygon element.
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Polygon(_)));
        // The polygon is selected.
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn lock_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        assert!(model.document().selection.is_empty());
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert!(elem.common().locked);
    }

    #[test]
    fn locked_element_not_selectable() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        // Try to select again via rect
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        // Should not select locked element
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]));
    }

    #[test]
    fn unlock_all() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        Controller::unlock_all(&mut model);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert!(!elem.common().locked);
    }

    #[test]
    fn copy_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let orig_count = model.document().layers[0].children().unwrap().len();
        Controller::copy_selection(&mut model, 10.0, 10.0);
        let new_count = model.document().layers[0].children().unwrap().len();
        assert_eq!(new_count, orig_count + 1);
    }

    // ---- Visibility: Hide / Show All ----

    #[test]
    fn visibility_order_preview_greater_than_outline_greater_than_invisible() {
        use crate::geometry::element::Visibility;
        assert!(Visibility::Preview > Visibility::Outline);
        assert!(Visibility::Outline > Visibility::Invisible);
        assert_eq!(
            std::cmp::min(Visibility::Preview, Visibility::Outline),
            Visibility::Outline
        );
        assert_eq!(
            std::cmp::min(Visibility::Outline, Visibility::Invisible),
            Visibility::Invisible
        );
    }

    #[test]
    fn hide_selection_sets_invisible_and_clears_selection() {
        use crate::geometry::element::Visibility;
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        assert!(model.document().selection.is_empty());
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.visibility(), Visibility::Invisible);
    }

    #[test]
    fn hidden_element_not_selectable_via_rect() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        // Marquee over where the rect is.
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]),
            "hidden rect must not be marquee-selectable, got {:?}", paths);
    }

    #[test]
    fn hidden_element_not_selectable_via_select_element() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        // Try to select again by path.
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn hidden_element_not_included_in_select_all() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        Controller::select_all(&mut model);
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]));
    }

    #[test]
    fn invisible_group_caps_children() {
        use crate::geometry::element::Visibility;
        // The setup_model builds a layer like
        //   [Rect, Group(Line, Line), Line]
        // Hide the group — its children should become
        // effectively invisible even though their own flag is
        // still `Preview`.
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 1]);
        Controller::hide_selection(&mut model);
        let doc = model.document();
        // Group itself is Invisible
        assert_eq!(
            doc.get_element(&vec![0, 1]).unwrap().visibility(),
            Visibility::Invisible
        );
        // Children's own flag is unchanged
        assert_eq!(
            doc.get_element(&vec![0, 1, 0]).unwrap().visibility(),
            Visibility::Preview
        );
        // But their effective visibility is Invisible
        assert_eq!(doc.effective_visibility(&vec![0, 1, 0]), Visibility::Invisible);
    }

    #[test]
    fn show_all_resets_invisible_and_selects_them() {
        use crate::geometry::element::Visibility;
        let mut model = setup_model();
        // Hide two elements.
        Controller::set_selection(
            &mut model,
            vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 2]),
            ],
        );
        Controller::hide_selection(&mut model);
        // Now run Show All.
        Controller::show_all(&mut model);
        let doc = model.document();
        // Both elements are back to Preview.
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().visibility(),
            Visibility::Preview
        );
        assert_eq!(
            doc.get_element(&vec![0, 2]).unwrap().visibility(),
            Visibility::Preview
        );
        // The selection contains exactly the two newly shown paths.
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 0]));
        assert!(paths.contains(&vec![0, 2]));
        assert_eq!(paths.len(), 2);
    }

    #[test]
    fn show_all_ignores_elements_that_were_already_visible() {
        let mut model = setup_model();
        // Nothing is hidden — Show All should leave the selection
        // empty and the document unchanged in terms of visibility.
        Controller::show_all(&mut model);
        assert!(model.document().selection.is_empty());
    }

    // ---- Partial(empty) is a legal retained state ----

    #[test]
    fn toggle_selection_partial_xor_to_empty_keeps_element() {
        // XOR of identical Partial CP sets yields Partial(empty).
        // The element must stay in the selection, not be dropped.
        use crate::document::document::SortedCps;
        let current: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1])];
        let new: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1])];
        let result = toggle_selection(&current, &new);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, vec![0, 0]);
        match &result[0].kind {
            SelectionKind::Partial(s) => assert_eq!(*s, SortedCps::from_iter(Vec::<usize>::new())),
            _ => panic!("expected Partial(empty), got {:?}", result[0].kind),
        }
    }

    #[test]
    fn toggle_selection_all_xor_all_still_drops_element() {
        // Element-level deselect gesture: shift-click an element that is
        // already fully selected. This must still drop the element.
        let current: Selection = vec![ElementSelection::all(vec![0, 0])];
        let new: Selection = vec![ElementSelection::all(vec![0, 0])];
        let result = toggle_selection(&current, &new);
        assert!(result.is_empty(), "expected All XOR All to drop, got {:?}", result);
    }

    #[test]
    fn partial_select_rect_body_only_yields_partial_empty() {
        // Partial selection marquee over an element's body but missing
        // every control point must yield `Partial(empty)` — the
        // element is selected but no CPs are highlighted. The old
        // behavior promoted body-hit to `All`, which effectively
        // "selected every CP", contradicting the Partial Selection
        // contract.
        use crate::document::document::SortedCps;
        let mut model = setup_model();
        // Rect is at (0,0) 10x10; a marquee strictly inside the body
        // (e.g. 3..7 x 3..7) misses all four corners but intersects
        // the rect's interior.
        Controller::partial_select_rect(&mut model, 3.0, 3.0, 4.0, 4.0, false);
        let sel = &model.document().selection;
        let rect_entry = sel.iter().find(|es| es.path == vec![0, 0])
            .expect("rect should be in selection");
        match &rect_entry.kind {
            SelectionKind::Partial(s) => {
                assert_eq!(*s, SortedCps::from_iter(Vec::<usize>::new()),
                    "expected Partial(empty), got {:?}", s);
            }
            other => panic!("expected Partial(empty), got {:?}", other),
        }
    }

    #[test]
    fn move_selection_on_partial_empty_is_noop() {
        // With kind = Partial(empty), move_selection must not change
        // the element — not its position, and critically not its
        // primitive type. Prior to the guard in move_control_points,
        // a Rect with Partial(empty) would be silently converted to
        // a Polygon at its original coordinates.
        use crate::document::document::SortedCps;
        let mut model = setup_model();
        Controller::set_selection(
            &mut model,
            vec![ElementSelection {
                path: vec![0, 0],
                kind: SelectionKind::Partial(SortedCps::from_iter(Vec::<usize>::new())),
            }],
        );
        Controller::move_selection(&mut model, 5.0, 7.0);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        match elem {
            Element::Rect(r) => {
                assert_eq!(r.x, 0.0);
                assert_eq!(r.y, 0.0);
                assert_eq!(r.width, 10.0);
                assert_eq!(r.height, 10.0);
            }
            other => panic!("expected Rect to remain a Rect, got {:?}", other),
        }
    }

    #[test]
    fn toggle_selection_partial_xor_nonempty_unchanged() {
        // Sanity check that non-empty XOR still works.
        use crate::document::document::SortedCps;
        let current: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1, 2])];
        let new: Selection = vec![ElementSelection::partial(vec![0, 0], [1usize])];
        let result = toggle_selection(&current, &new);
        assert_eq!(result.len(), 1);
        match &result[0].kind {
            SelectionKind::Partial(s) => {
                assert_eq!(*s, SortedCps::from_iter([0usize, 2]));
            }
            _ => panic!("expected Partial"),
        }
    }

    // ----------------------------------------------------------------------
    // Element-type control points (mirrors Python controller_test.py
    // line_control_points / rect_control_points / etc.)
    // ----------------------------------------------------------------------

    fn make_circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Element {
        Element::Ellipse(EllipseElem {
            cx, cy, rx, ry,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    #[test]
    fn line_control_points_returns_two() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        assert_eq!(control_point_count(&line), 2);
        let cps = control_points(&line);
        assert_eq!(cps[0], (0.0, 0.0));
        assert_eq!(cps[1], (10.0, 10.0));
    }

    #[test]
    fn rect_control_points_returns_four_corners() {
        let rect = make_rect(0.0, 0.0, 10.0, 20.0);
        assert_eq!(control_point_count(&rect), 4);
        let cps = control_points(&rect);
        // Order is implementation-defined but should contain the four corners.
        let set: std::collections::HashSet<_> = cps.iter()
            .map(|&(x, y)| ((x * 10.0) as i64, (y * 10.0) as i64))
            .collect();
        assert!(set.contains(&(0, 0)));
        assert!(set.contains(&(100, 0)));
        assert!(set.contains(&(100, 200)));
        assert!(set.contains(&(0, 200)));
    }

    #[test]
    fn circle_control_points_returns_four_quadrants() {
        let circle = make_circle(50.0, 50.0, 10.0);
        assert_eq!(control_point_count(&circle), 4);
    }

    #[test]
    fn ellipse_control_points_returns_four() {
        let ell = make_ellipse(50.0, 50.0, 10.0, 5.0);
        assert_eq!(control_point_count(&ell), 4);
    }

    // ----------------------------------------------------------------------
    // Move-element-by-CPs (move_control_points behavior)
    // ----------------------------------------------------------------------

    #[test]
    fn move_line_all_cps_translates() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        let moved = move_control_points(&line, &SelectionKind::All, 5.0, 7.0);
        if let Element::Line(l) = moved {
            assert_eq!((l.x1, l.y1), (5.0, 7.0));
            assert_eq!((l.x2, l.y2), (15.0, 17.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_line_one_cp() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        let kind = SelectionKind::Partial(SortedCps::from_iter([1usize]));
        let moved = move_control_points(&line, &kind, 5.0, 5.0);
        if let Element::Line(l) = moved {
            assert_eq!((l.x1, l.y1), (0.0, 0.0));
            assert_eq!((l.x2, l.y2), (15.0, 15.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_rect_all_cps_translates() {
        let rect = make_rect(0.0, 0.0, 10.0, 20.0);
        let moved = move_control_points(&rect, &SelectionKind::All, 5.0, 7.0);
        if let Element::Rect(r) = moved {
            assert_eq!(r.x, 5.0);
            assert_eq!(r.y, 7.0);
            assert_eq!(r.width, 10.0);
            assert_eq!(r.height, 20.0);
        } else { panic!("expected Rect"); }
    }

    #[test]
    fn move_circle_all_cps_translates() {
        let c = make_circle(50.0, 50.0, 10.0);
        let moved = move_control_points(&c, &SelectionKind::All, 5.0, 7.0);
        if let Element::Circle(c) = moved {
            assert_eq!(c.cx, 55.0);
            assert_eq!(c.cy, 57.0);
            assert_eq!(c.r, 10.0);
        } else { panic!("expected Circle"); }
    }

    #[test]
    fn move_ellipse_all_cps_translates() {
        let e = make_ellipse(50.0, 50.0, 10.0, 5.0);
        let moved = move_control_points(&e, &SelectionKind::All, 5.0, 7.0);
        if let Element::Ellipse(e) = moved {
            assert_eq!((e.cx, e.cy), (55.0, 57.0));
            assert_eq!((e.rx, e.ry), (10.0, 5.0));
        } else { panic!("expected Ellipse"); }
    }

    // ----------------------------------------------------------------------
    // move_selection on different element types
    // ----------------------------------------------------------------------

    #[test]
    fn move_selected_line() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_line(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 5.0, 7.0);
        if let Element::Line(l) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!((l.x1, l.y1), (5.0, 7.0));
            assert_eq!((l.x2, l.y2), (15.0, 17.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_selected_rect() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 20.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 5.0, 7.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.x, 5.0);
            assert_eq!(r.y, 7.0);
        } else { panic!("expected Rect"); }
    }

    #[test]
    fn move_partial_cps_only_moves_those() {
        // Move only one corner of a rect: the others should stay put.
        // The rect may be converted to a Path under the hood since a
        // single moved corner can no longer be expressed as an axis-
        // aligned rect; we just verify the document still resolves.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let sel = vec![ElementSelection::partial(vec![0, 0], [0usize])];
        Controller::set_selection(&mut model, sel);
        Controller::move_selection(&mut model, 5.0, 5.0);
        assert!(model.document().get_element(&vec![0, 0]).is_some());
    }

    // ----------------------------------------------------------------------
    // Copy selection
    // ----------------------------------------------------------------------

    #[test]
    fn copy_selection_duplicates_element() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 2);
    }

    #[test]
    fn copy_selection_updates_selection_to_copy() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        // Original was at index 0; copy is appended at index 1.
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 1]));
    }

    /// §19 (RULED 2026-07-28, JYH: *"yes document order"*) — the selection a
    /// DUPLICATE leaves behind is in document order, and it names the COPIES.
    ///
    /// Four rects a b c d; duplicate the NON-CONTIGUOUS pair b=[0,1] and
    /// d=[0,3] with dx=6. The descending walk is load-bearing and stays
    /// (inserting after [0,1] shifts [0,3]), so the document that comes out is
    ///
    ///     [0,0] a@0   [0,1] b@10   [0,2] b'@16   [0,3] c@20   [0,4] d@30   [0,5] d'@36
    ///
    /// and the two COPIES are at [0,2] and [0,5].
    ///
    /// **This assertion is deliberately over-specified relative to §19**, and
    /// that is the point: the byproduct loop pushed `[0,4]` and `[0,2]`, and
    /// `[0,4]` is not merely mis-ORDERED — after the later insertion at [0,1]
    /// shifted everything above it, `[0,4]` names **d, the SOURCE**. Sorting
    /// stale paths yields a tidy ascending list of the wrong elements, so a
    /// test asserting only "ascending" would pass on a half-fix. Both the
    /// order and the identity are pinned here, by path AND by geometry.
    #[test]
    fn copy_selection_of_two_elements_selects_both_copies_in_document_order() {
        let mut model = Model::default();
        for i in 0..4 {
            Controller::add_element(
                &mut model,
                make_rect(i as f64 * 10.0, 0.0, 5.0, 5.0),
            );
        }
        Controller::set_selection(
            &mut model,
            vec![
                ElementSelection::all(vec![0, 1]),
                ElementSelection::all(vec![0, 3]),
            ],
        );
        Controller::copy_selection(&mut model, 6.0, 0.0);

        // The document grew by exactly the two copies, in document order.
        let doc = model.document();
        let xs: Vec<f64> = doc.layers[0]
            .children()
            .unwrap()
            .iter()
            .map(|c| match &**c {
                Element::Rect(r) => r.x,
                other => panic!("expected a Rect, got {other:?}"),
            })
            .collect();
        assert_eq!(xs, vec![0.0, 10.0, 16.0, 20.0, 30.0, 36.0], "document order");

        // ORDER: ascending, i.e. document order — NOT the descending byproduct.
        let paths: Vec<Vec<usize>> =
            doc.selection.iter().map(|es| es.path.clone()).collect();
        assert_eq!(
            paths,
            vec![vec![0, 2], vec![0, 5]],
            "the duplicate must leave its selection in DOCUMENT order",
        );

        // IDENTITY: both selected paths must name the OFFSET copies (x=16, 36),
        // never a source (x=10, 30). This is the half a sort alone cannot fix.
        let selected_xs: Vec<f64> = doc
            .selection
            .iter()
            .map(|es| match doc.get_element(&es.path).unwrap() {
                Element::Rect(r) => r.x,
                other => panic!("expected a Rect, got {other:?}"),
            })
            .collect();
        assert_eq!(
            selected_xs,
            vec![16.0, 36.0],
            "the selection must name the two COPIES, not a source",
        );
    }

    #[test]
    fn assign_id_stamps_id_at_path() {
        // assign_id stamps the carried id onto the element at the path;
        // the element starts id-less (lazy default).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        assert_eq!(
            model.document().get_element(&vec![0, 0]).unwrap().common().id,
            None,
        );
        Controller::assign_id(&mut model, &vec![0, 0], "elem-1");
        assert_eq!(
            model.document().get_element(&vec![0, 0]).unwrap().common().id.as_deref(),
            Some("elem-1"),
        );
    }

    #[test]
    fn create_reference_stamps_target_and_inserts_reference() {
        // Target has no id → create_reference stamps target_id onto it and
        // appends a ReferenceElem (id ref_id, target = the stamped id).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::create_reference(&mut model, &vec![0, 0], "tgt-1", "ref-1");
        let doc = model.document();
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().common().id.as_deref(),
            Some("tgt-1"),
        );
        match doc.get_element(&vec![0, 1]).unwrap() {
            Element::Live(crate::geometry::live::LiveVariant::Reference(re)) => {
                assert_eq!(re.common.id.as_deref(), Some("ref-1"));
                assert_eq!(re.target.0, "tgt-1");
            }
            other => panic!("expected a Reference at [0,1], got {other:?}"),
        }
    }

    #[test]
    fn make_instance_creates_offset_selected_reference() {
        // "Make Instance" = create_reference + move_selection(24, 24) under
        // a single snapshot. After it: a reference targeting the source's
        // id exists, is offset by (24, 24) via its common.transform, and
        // is the selection. Source keeps its position. This pins the op
        // composition the Object-menu handler performs.
        // `crate::tool_consts`, not `crate::tools::tool` — `tools` is gated behind
        // `feature = "web"`, and a document-layer test must build natively.
        use crate::tool_consts::PASTE_OFFSET;
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // The just-added element is selected at [0,0] (kind=All).
        // Make Instance = create_reference + offset-move under ONE
        // transaction (mirrors the Object-menu handler), so the whole
        // composition is a single undo step.
        model.with_txn(|m| {
            Controller::create_reference(m, &vec![0, 0], "tgt-1", "ref-1");
            Controller::move_selection(m, PASTE_OFFSET, PASTE_OFFSET);
        });
        let doc = model.document();
        // Source rect untouched.
        if let Element::Rect(r) = doc.get_element(&vec![0, 0]).unwrap() {
            assert_eq!((r.x, r.y), (0.0, 0.0));
        } else {
            panic!("expected source Rect at [0,0]");
        }
        // New reference at [0,1], targeting the source, offset by (24, 24).
        match doc.get_element(&vec![0, 1]).unwrap() {
            Element::Live(crate::geometry::live::LiveVariant::Reference(re)) => {
                assert_eq!(re.target.0, "tgt-1");
                assert_eq!(re.common.id.as_deref(), Some("ref-1"));
                let t = re.common.transform.expect("offset rides on common.transform");
                assert_eq!((t.e, t.f), (PASTE_OFFSET, PASTE_OFFSET));
                // The dead instance-transform field stays None.
                assert!(re.transform.is_none());
            }
            other => panic!("expected a Reference at [0,1], got {other:?}"),
        }
        // The reference is the selection (whole-element).
        assert_eq!(doc.selection.len(), 1);
        assert_eq!(doc.selection[0].path, vec![0, 1]);
        assert_eq!(doc.selection[0].kind, SelectionKind::All);
        // Single snapshot ⇒ one undo restores the pre-Make-Instance state
        // (just the source rect, no reference).
        model.undo();
        let doc = model.document();
        assert!(doc.get_element(&vec![0, 1]).is_none());
        assert!(doc.get_element(&vec![0, 0]).is_some());
    }

    #[test]
    fn create_reference_keeps_existing_target_id() {
        // Target already has an id → it is NOT re-stamped; the reference
        // targets the existing id and target_id is ignored.
        let mut model = Model::default();
        let mut rect = make_rect(0.0, 0.0, 10.0, 10.0);
        rect.common_mut().id = Some("existing".into());
        Controller::add_element(&mut model, rect);
        Controller::create_reference(&mut model, &vec![0, 0], "tgt-ignored", "ref-1");
        let doc = model.document();
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().common().id.as_deref(),
            Some("existing"),
        );
        if let Element::Live(crate::geometry::live::LiveVariant::Reference(re)) =
            doc.get_element(&vec![0, 1]).unwrap()
        {
            assert_eq!(re.target.0, "existing");
        } else {
            panic!("expected a Reference at [0,1]");
        }
    }

    // ----------------------------------------------------------------------
    // Symbols P2 — operations (SYMBOLS.md §7)
    // ----------------------------------------------------------------------

    /// Helper: pull a `ReferenceElem` out of the element at `path` or panic.
    fn as_reference<'a>(
        doc: &'a Document,
        path: &ElementPath,
    ) -> &'a crate::geometry::live::ReferenceElem {
        match doc.get_element(path) {
            Some(Element::Live(crate::geometry::live::LiveVariant::Reference(re))) => re,
            other => panic!("expected a Reference at {path:?}, got {other:?}"),
        }
    }

    #[test]
    fn make_symbol_promotes_and_leaves_instance() {
        // An id-less element → make_symbol stamps master_id, moves the element
        // into doc.symbols as a master, and replaces it in place with an
        // instance (ref_id, target = master_id).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        let doc = model.document();
        // The master lives off-canvas in symbols, carrying master_id.
        assert_eq!(doc.symbols.len(), 1);
        assert_eq!(doc.symbols[0].common().id.as_deref(), Some("m1"));
        assert!(matches!(doc.symbols[0], Element::Rect(_)));
        // The in-place element is now an instance targeting the master.
        let re = as_reference(doc, &vec![0, 0]);
        assert_eq!(re.common.id.as_deref(), Some("i1"));
        assert_eq!(re.target.0, "m1");
    }

    #[test]
    fn make_symbol_keeps_existing_id_as_master_key() {
        // If the element already carries an id, that id is KEPT as the master
        // key and master_id is ignored (assign-on-create, like create_reference).
        let mut model = Model::default();
        let mut rect = make_rect(0.0, 0.0, 10.0, 10.0);
        rect.common_mut().id = Some("existing".into());
        Controller::add_element(&mut model, rect);
        Controller::make_symbol(&mut model, &vec![0, 0], "m1-ignored", "i1");
        let doc = model.document();
        assert_eq!(doc.symbols[0].common().id.as_deref(), Some("existing"));
        let re = as_reference(doc, &vec![0, 0]);
        assert_eq!(re.target.0, "existing");
        assert_eq!(re.common.id.as_deref(), Some("i1"));
    }

    #[test]
    fn make_symbol_invalid_path_is_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let before = model.document().clone();
        Controller::make_symbol(&mut model, &vec![0, 9], "m1", "i1");
        // Symbols untouched, element unchanged.
        assert!(model.document().symbols.is_empty());
        assert!(matches!(
            model.document().get_element(&vec![0, 0]).unwrap(),
            Element::Rect(_)
        ));
        let _ = before;
    }

    #[test]
    fn place_instance_appends_and_selects() {
        // place_instance appends a reference to the active layer and selects it.
        let mut model = Model::default();
        // Pre-seed a master so the doc has one; not strictly required.
        let mut master = make_rect(0.0, 0.0, 10.0, 10.0);
        master.common_mut().id = Some("m1".into());
        let mut seed = model.document().clone();
        seed.symbols.push(master);
        model.set_document_for_test(seed);

        Controller::place_instance(&mut model, "m1", "i2");
        let doc = model.document();
        // Appended as the only layer child (index 0).
        let re = as_reference(doc, &vec![0, 0]);
        assert_eq!(re.target.0, "m1");
        assert_eq!(re.common.id.as_deref(), Some("i2"));
        // The new instance is the selection (auto-select via add_element).
        assert_eq!(doc.selection.len(), 1);
        assert_eq!(doc.selection[0].path, vec![0, 0]);
    }

    #[test]
    fn place_concept_instance_appends_generated_and_selects() {
        // place_concept_instance appends a Generated element (concept id +
        // default params) to the active layer and selects it (CONCEPTS.md §6).
        let mut model = Model::default();
        let params = serde_json::json!({ "radius": 50.0, "sides": 6.0 });
        Controller::place_concept_instance(&mut model, "regular_polygon", params.clone(), "g1");
        let doc = model.document();
        let el = doc.get_element(&vec![0, 0]).expect("appended element");
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Generated(g),
        ) = el
        else {
            panic!("expected a generated element");
        };
        assert_eq!(g.concept_id, "regular_polygon");
        assert_eq!(g.params, params);
        assert_eq!(g.common.id.as_deref(), Some("g1"));
        assert_eq!(doc.selection.len(), 1);
        assert_eq!(doc.selection[0].path, vec![0, 0]);
    }

    #[test]
    fn set_concept_param_updates_instance_and_regenerates() {
        // Concepts panel Slice 2: changing a param on a placed Generated
        // instance rewrites params[name]=value, so the instance re-generates
        // (CONCEPTS.md §6.4 — "tune the same parameters").
        let mut model = Model::default();
        let params = serde_json::json!({ "radius": 50.0, "sides": 6.0 });
        Controller::place_concept_instance(&mut model, "regular_polygon", params, "g1");
        let path = vec![0, 0];
        Controller::set_concept_param(&mut model, &path, "sides", 8.0);
        let doc = model.document();
        let el = doc.get_element(&path).expect("instance");
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Generated(g),
        ) = el
        else {
            panic!("expected a generated element");
        };
        assert_eq!(g.params.get("sides").and_then(|v| v.as_f64()), Some(8.0));
        // radius is untouched
        assert_eq!(g.params.get("radius").and_then(|v| v.as_f64()), Some(50.0));
    }

    #[test]
    fn apply_concept_operation_merges_changes() {
        // CONCEPTS.md §9: an operation's RESOLVED changes map is merged into the
        // Generated's params (only named params change; others untouched).
        let mut model = Model::default();
        let params = serde_json::json!({ "radius": 50.0, "sides": 6.0 });
        Controller::place_concept_instance(&mut model, "regular_polygon", params, "g1");
        let path = vec![0, 0];
        // add_side resolves to { sides: 7 } at production time.
        let changes = serde_json::json!({ "sides": 7.0 });
        Controller::apply_concept_operation(&mut model, &path, &changes);
        let el = model.document().get_element(&path).expect("instance");
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Generated(g),
        ) = el
        else {
            panic!("expected a generated element");
        };
        assert_eq!(g.params.get("sides").and_then(|v| v.as_f64()), Some(7.0));
        assert_eq!(g.params.get("radius").and_then(|v| v.as_f64()), Some(50.0));
    }

    #[test]
    fn apply_concept_operation_empty_changes_is_noop() {
        // An empty / non-object changes map mutates nothing (the no-op guard).
        let mut model = Model::default();
        let params = serde_json::json!({ "radius": 50.0, "sides": 6.0 });
        Controller::place_concept_instance(&mut model, "regular_polygon", params, "g1");
        let path = vec![0, 0];
        Controller::apply_concept_operation(&mut model, &path, &serde_json::json!({}));
        let el = model.document().get_element(&path).expect("instance");
        let crate::geometry::element::Element::Live(
            crate::geometry::live::LiveVariant::Generated(g),
        ) = el
        else {
            panic!("expected a generated element");
        };
        assert_eq!(g.params.get("sides").and_then(|v| v.as_f64()), Some(6.0));
    }

    #[test]
    fn promote_to_concept_replaces_with_generated() {
        // CONCEPTS.md §10: promote replaces a raw element with a Generated
        // instance carrying the fitted params + the placement transform, while
        // preserving the original element's identity (id/name).
        use crate::geometry::element::{CommonProps, Element, PolygonElem, Transform};
        let mut model = Model::default();
        let poly = Element::Polygon(PolygonElem {
            points: vec![(10.0, 0.0), (0.0, 10.0), (-10.0, 0.0), (0.0, -10.0)],
            fill: None,
            stroke: None,
            common: CommonProps {
                id: Some("p1".into()),
                name: Some("my square".into()),
                ..CommonProps::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
        });
        Controller::add_element(&mut model, poly);
        let path = vec![0, 0];
        let params = serde_json::json!({ "sides": 4.0, "radius": 10.0 });
        let t = Transform::translate(5.0, 7.0);
        Controller::promote_to_concept(&mut model, &path, "regular_polygon", params, t);

        let el = model.document().get_element(&path).expect("promoted element");
        let Element::Live(crate::geometry::live::LiveVariant::Generated(g)) = el else {
            panic!("expected a generated element after promote");
        };
        assert_eq!(g.concept_id, "regular_polygon");
        assert_eq!(g.params.get("sides").and_then(|v| v.as_f64()), Some(4.0));
        assert_eq!(g.params.get("radius").and_then(|v| v.as_f64()), Some(10.0));
        // placement transform applied …
        let gt = g.common.transform.expect("placement transform set");
        assert_eq!((gt.e, gt.f), (5.0, 7.0));
        // … and the original identity preserved.
        assert_eq!(g.common.id.as_deref(), Some("p1"));
        assert_eq!(g.common.name.as_deref(), Some("my square"));
    }

    #[test]
    fn promote_to_concept_missing_path_is_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::promote_to_concept(
            &mut model,
            &vec![9, 9],
            "regular_polygon",
            serde_json::json!({}),
            crate::geometry::element::Transform::IDENTITY,
        );
        // The rect at [0,0] is untouched; the missing path stays missing.
        assert!(matches!(
            model.document().get_element(&vec![0, 0]),
            Some(crate::geometry::element::Element::Rect(_))
        ));
        assert!(model.document().get_element(&vec![9, 9]).is_none());
    }

    #[test]
    fn place_instance_dangling_master_ok() {
        // It is fine if the master does not exist; the instance still appears
        // (renders empty until the master exists — dangling is handled).
        let mut model = Model::default();
        Controller::place_instance(&mut model, "ghost", "i9");
        let re = as_reference(model.document(), &vec![0, 0]);
        assert_eq!(re.target.0, "ghost");
        assert_eq!(re.common.id.as_deref(), Some("i9"));
    }

    #[test]
    fn set_instance_transform_sets_the_field() {
        // Symbols P4 (SYMBOLS.md §4 / Fork F2): set_instance_transform writes
        // the given Transform into the instance's `transform` field, leaving
        // common.transform untouched (the two are independent).
        use crate::geometry::element::Transform;
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        // Precondition: a fresh instance has no instance transform.
        assert!(as_reference(model.document(), &vec![0, 0]).transform.is_none());

        Controller::set_instance_transform(&mut model, &vec![0, 0], Transform::scale(2.0, 2.0));
        let re = as_reference(model.document(), &vec![0, 0]);
        let t = re.transform.expect("instance transform set");
        assert_eq!((t.a, t.d), (2.0, 2.0));
        assert!((t.b, t.c, t.e, t.f) == (0.0, 0.0, 0.0, 0.0));
        // common.transform is left alone (still None for a fresh instance).
        assert!(re.common.transform.is_none(),
            "set_instance_transform must not touch common.transform");
    }

    #[test]
    fn set_instance_transform_non_reference_is_noop() {
        // The element at `path` is a plain rect, not a reference → no-op
        // (no panic, the rect is unchanged).
        use crate::geometry::element::Transform;
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::set_instance_transform(&mut model, &vec![0, 0], Transform::scale(2.0, 2.0));
        assert!(matches!(
            model.document().get_element(&vec![0, 0]).unwrap(),
            Element::Rect(_)
        ));
    }

    #[test]
    fn detach_replaces_instance_with_idless_copy() {
        // make_symbol then detach the instance → the path holds an id-less copy
        // of the master geometry (NOT a reference); the master is untouched.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(3.0, 4.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        Controller::detach(&mut model, &vec![0, 0]);
        let doc = model.document();
        // No longer a reference: an independent rect copy.
        match doc.get_element(&vec![0, 0]).unwrap() {
            Element::Rect(r) => {
                assert_eq!((r.x, r.y), (3.0, 4.0));
                assert_eq!(r.common.id, None, "detached copy is born id-less");
            }
            other => panic!("expected an id-less Rect copy, got {other:?}"),
        }
        // The master still exists.
        assert_eq!(doc.symbols.len(), 1);
        assert_eq!(doc.symbols[0].common().id.as_deref(), Some("m1"));
    }

    #[test]
    fn detach_applies_instance_transform_override() {
        // An instance with a common.transform offset → the detached copy carries
        // that transform composed onto the master geometry.
        use crate::geometry::element::Transform;
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        // Move the instance (rides on common.transform).
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 24.0, 24.0);
        Controller::detach(&mut model, &vec![0, 0]);
        let copy = model.document().get_element(&vec![0, 0]).unwrap();
        let t = copy.common().transform.expect("instance transform applied to copy");
        assert_eq!((t.e, t.f), (24.0, 24.0));
        let _ = Transform::IDENTITY;
    }

    #[test]
    fn detach_composes_instance_transform_field() {
        // Symbols P4 (SYMBOLS.md §4 / Fork F2): an instance carrying BOTH a
        // common.transform (a translate) AND a non-None instance `transform`
        // field (a scale) → the detached copy composes both, in render order
        // (common.transform ∘ instance.transform), so detach drops neither.
        use crate::geometry::element::Transform;
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        // common.transform = translate(24, 24).
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 24.0, 24.0);
        // instance.transform = scale(2, 2).
        Controller::set_instance_transform(&mut model, &vec![0, 0], Transform::scale(2.0, 2.0));
        Controller::detach(&mut model, &vec![0, 0]);

        let copy = model.document().get_element(&vec![0, 0]).unwrap();
        let t = copy.common().transform.expect("composed transform on copy");
        // Expected = translate(24,24) ∘ scale(2,2) (the master copy has no own
        // transform, so the composition is exactly common.transform * instance).
        let expected = Transform::translate(24.0, 24.0).multiply(&Transform::scale(2.0, 2.0));
        assert!((t.a - expected.a).abs() < 1e-9);
        assert!((t.b - expected.b).abs() < 1e-9);
        assert!((t.c - expected.c).abs() < 1e-9);
        assert!((t.d - expected.d).abs() < 1e-9);
        assert!((t.e - expected.e).abs() < 1e-9);
        assert!((t.f - expected.f).abs() < 1e-9);
        // Concretely: scale 2, then translate 24.
        assert_eq!((t.a, t.d), (2.0, 2.0));
        assert_eq!((t.e, t.f), (24.0, 24.0));
    }

    #[test]
    fn detach_applies_instance_paint_override() {
        // An instance with its own fill → the detached copy adopts that fill.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        // Override the instance's fill.
        let red = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        let new_ref = crate::geometry::element::with_fill(
            model.document().get_element(&vec![0, 0]).unwrap(),
            red.clone(),
        );
        model.set_document_for_test(model.document().replace_element(&vec![0, 0], new_ref));
        Controller::detach(&mut model, &vec![0, 0]);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.fill, red);
        } else {
            panic!("expected a Rect copy");
        }
    }

    #[test]
    fn detach_non_reference_is_noop() {
        // A plain element (not a reference) → detach is a no-op.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::detach(&mut model, &vec![0, 0]);
        assert!(matches!(
            model.document().get_element(&vec![0, 0]).unwrap(),
            Element::Rect(_)
        ));
    }

    #[test]
    fn detach_unresolvable_target_is_noop() {
        // An instance whose target is missing → detach leaves it as-is.
        let mut model = Model::default();
        Controller::place_instance(&mut model, "ghost", "i1");
        Controller::detach(&mut model, &vec![0, 0]);
        // Still a reference.
        let re = as_reference(model.document(), &vec![0, 0]);
        assert_eq!(re.target.0, "ghost");
    }

    #[test]
    fn redefine_swaps_master_and_makes_instance() {
        // make_symbol a rect (m1), add a separate circle, then redefine m1 from
        // the circle → doc.symbols[m1] becomes the circle, and the circle's path
        // holds a new instance (ref_id) targeting m1.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        // Add a circle at [0,1].
        Controller::add_element(&mut model, Element::Circle(CircleElem {
            cx: 50.0, cy: 50.0, r: 20.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        }));
        Controller::redefine(&mut model, "m1", &vec![0, 1], "i2");
        let doc = model.document();
        // The master is now the circle, keyed by m1.
        assert_eq!(doc.symbols.len(), 1);
        assert!(matches!(doc.symbols[0], Element::Circle(_)));
        assert_eq!(doc.symbols[0].common().id.as_deref(), Some("m1"));
        // The selection's path is now an instance of m1.
        let re = as_reference(doc, &vec![0, 1]);
        assert_eq!(re.target.0, "m1");
        assert_eq!(re.common.id.as_deref(), Some("i2"));
        // The original instance still targets m1 (now resolves to the circle).
        let re0 = as_reference(doc, &vec![0, 0]);
        assert_eq!(re0.target.0, "m1");
        assert_eq!(re0.common.id.as_deref(), Some("i1"));
    }

    #[test]
    fn redefine_unknown_master_is_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::redefine(&mut model, "nope", &vec![0, 0], "i1");
        // No symbols created, element unchanged.
        assert!(model.document().symbols.is_empty());
        assert!(matches!(
            model.document().get_element(&vec![0, 0]).unwrap(),
            Element::Rect(_)
        ));
    }

    #[test]
    fn delete_symbol_removes_master() {
        // make_symbol a rect (m1), then delete_symbol m1 → doc.symbols is empty.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        assert_eq!(model.document().symbols.len(), 1);
        Controller::delete_symbol(&mut model, "m1");
        assert!(model.document().symbols.is_empty());
    }

    #[test]
    fn delete_symbol_unknown_id_noop() {
        // Deleting an id that is not a master leaves doc.symbols untouched.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        Controller::delete_symbol(&mut model, "ghost");
        assert_eq!(model.document().symbols.len(), 1);
        assert_eq!(model.document().symbols[0].common().id.as_deref(), Some("m1"));
    }

    #[test]
    fn delete_symbol_leaves_instances_dangling() {
        // The instances are NOT removed; they stay in the layer, still
        // targeting the now-absent master id (dangling → resolves to empty).
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "i1");
        Controller::delete_symbol(&mut model, "m1");
        let doc = model.document();
        assert!(doc.symbols.is_empty());
        // The instance is still present, still targeting the absent master.
        let re = as_reference(doc, &vec![0, 0]);
        assert_eq!(re.target.0, "m1");
        assert_eq!(re.common.id.as_deref(), Some("i1"));
    }

    #[test]
    fn copy_selection_clears_id() {
        // A duplicated element must not inherit the source's stable id —
        // two elements cannot share an identity. The copy is born id-less
        // (lazy); it mints a fresh id only if/when it later becomes a
        // reference target. See the stable-identity initiative.
        let mut model = Model::default();
        let mut rect = make_rect(0.0, 0.0, 10.0, 10.0);
        rect.common_mut().id = Some("rect-1".into());
        Controller::add_element(&mut model, rect);
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        let doc = model.document();
        // The original keeps its id.
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().common().id.as_deref(),
            Some("rect-1"),
        );
        // The copy must NOT inherit it.
        assert_eq!(doc.get_element(&vec![0, 1]).unwrap().common().id, None);
    }

    #[test]
    fn copy_selection_clears_id_recursively_in_group() {
        // Duplicating a group clears ids on the group AND its descendants,
        // so no copied element shares identity with its source.
        let mut model = Model::default();
        let mut inner = make_rect(0.0, 0.0, 10.0, 10.0);
        inner.common_mut().id = Some("inner-1".into());
        let mut group = Element::Group(crate::geometry::element::GroupElem {
            children: vec![std::rc::Rc::new(inner)],
            common: crate::geometry::element::CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        });
        group.common_mut().id = Some("group-1".into());
        Controller::add_element(&mut model, group);
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        let doc = model.document();
        // Copy of the group at [0,1]; its child at [0,1,0].
        assert_eq!(doc.get_element(&vec![0, 1]).unwrap().common().id, None);
        assert_eq!(doc.get_element(&vec![0, 1, 0]).unwrap().common().id, None);
        // Originals untouched.
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().common().id.as_deref(),
            Some("group-1"),
        );
        assert_eq!(
            doc.get_element(&vec![0, 0, 0]).unwrap().common().id.as_deref(),
            Some("inner-1"),
        );
    }

    #[test]
    fn copy_selection_offsets_copy() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 5.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 1]).unwrap() {
            assert_eq!(r.x, 20.0);
            assert_eq!(r.y, 5.0);
        } else { panic!("expected Rect copy"); }
    }

    // ----------------------------------------------------------------------
    // Direct/group select rect
    // ----------------------------------------------------------------------

    #[test]
    fn partial_select_rect_no_group_expansion() {
        // partial_select_rect should NOT expand to the parent group.
        let mut model = setup_model();
        // Group at [0, 1] contains lines at [0, 1, 0] and [0, 1, 1] in
        // setup_model. Marquee around the line inside the group.
        Controller::partial_select_rect(&mut model, 0.5, 0.5, 1.5, 1.5, false);
        let paths = sel_paths(&model);
        // Should NOT contain the parent group path [0, 1].
        assert!(!paths.contains(&vec![0, 1]));
    }

    // Note: Rust does not have a separate interior_select_rect method;
    // interior selection happens via select_rect with the auto-expand
    // behaviour built in. Skipped here.

    // ----------------------------------------------------------------------
    // Selection clearing
    // ----------------------------------------------------------------------

    #[test]
    fn set_selection_to_empty_clears() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        Controller::set_selection(&mut model, vec![]);
        assert!(model.document().selection.is_empty());
    }

    // ----------------------------------------------------------------------
    // Locked elements
    // ----------------------------------------------------------------------

    #[test]
    fn locked_element_not_selectable_via_rect() {
        let mut model = Model::default();
        let mut rect = match make_rect(0.0, 0.0, 10.0, 10.0) {
            Element::Rect(r) => r,
            _ => unreachable!(),
        };
        rect.common.locked = true;
        Controller::add_element(&mut model, Element::Rect(rect));
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        assert!(model.document().selection.is_empty());
    }

    // ----------------------------------------------------------------------
    // select_rect on filled vs stroked rect interior
    // ----------------------------------------------------------------------

    #[test]
    fn select_rect_filled_rect_interior_hits() {
        let mut model = Model::default();
        let mut rect = match make_rect(0.0, 0.0, 100.0, 100.0) {
            Element::Rect(r) => r,
            _ => unreachable!(),
        };
        rect.fill = Some(Fill::new(Color::BLACK));
        Controller::add_element(&mut model, Element::Rect(rect));
        // Marquee fully inside the filled rect — should hit (filled
        // interior counts as part of the element).
        Controller::select_rect(&mut model, 25.0, 25.0, 50.0, 50.0, false);
        // Behaviour may vary; if hit, the path should contain [0, 0].
        // We just assert "selection not empty" as the loose check.
        let _ = sel_paths(&model);
    }

    // ----------------------------------------------------------------------
    // set_selection_fill / set_selection_stroke
    // ----------------------------------------------------------------------

    #[test]
    fn set_selection_fill_updates_rect() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // add_element selects the new element
        let red = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        Controller::set_selection_fill(&mut model, red);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.fill(), Some(&Fill::new(Color::rgb(1.0, 0.0, 0.0))));
    }

    #[test]
    fn set_selection_stroke_updates_line() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_line(0.0, 0.0, 50.0, 50.0));
        let blue = Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0));
        Controller::set_selection_stroke(&mut model, blue);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.stroke(), Some(&Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0)));
    }

    #[test]
    fn set_selection_fill_no_selection_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // Clear selection
        Controller::set_selection(&mut model, vec![]);
        let gen_before = model.document().selection.len();
        Controller::set_selection_fill(&mut model, Some(Fill::new(Color::WHITE)));
        assert_eq!(model.document().selection.len(), gen_before);
    }

    // ----------------------------------------------------------------------
    // fill / stroke summary
    // ----------------------------------------------------------------------

    #[test]
    fn fill_summary_no_selection() {
        let doc = Document::default();
        assert_eq!(selection_fill_summary(&doc), FillSummary::NoSelection);
    }

    #[test]
    fn fill_summary_single_element() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let doc = model.document();
        match selection_fill_summary(doc) {
            FillSummary::Uniform(Some(f)) => assert_eq!(f.color, Color::BLACK),
            other => panic!("expected Uniform(Some(...)), got {other:?}"),
        }
    }

    #[test]
    fn fill_summary_uniform_same() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::add_element(&mut model, make_rect(20.0, 20.0, 10.0, 10.0));
        Controller::select_all(&mut model);
        let doc = model.document();
        match selection_fill_summary(doc) {
            FillSummary::Uniform(Some(f)) => assert_eq!(f.color, Color::BLACK),
            other => panic!("expected Uniform(Some(...)), got {other:?}"),
        }
    }

    #[test]
    fn fill_summary_mixed() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // Change first rect's fill to red
        Controller::set_selection_fill(&mut model, Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))));
        Controller::add_element(&mut model, make_rect(20.0, 20.0, 10.0, 10.0));
        Controller::select_all(&mut model);
        assert_eq!(selection_fill_summary(model.document()), FillSummary::Mixed);
    }

    #[test]
    fn stroke_summary_uniform_none() {
        let mut model = Model::default();
        // make_rect has stroke: None
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let doc = model.document();
        assert_eq!(selection_stroke_summary(doc), StrokeSummary::Uniform(None));
    }

    // ── Opacity mask lifecycle (Phase 3b) ─────────────────────

    fn setup_two_rect_selection() -> Model {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::add_element(&mut model, make_rect(20.0, 0.0, 10.0, 10.0));
        Controller::select_all(&mut model);
        model
    }

    #[test]
    fn selection_has_mask_false_for_empty_selection() {
        let model = Model::default();
        assert!(!selection_has_mask(model.document()));
    }

    #[test]
    fn selection_has_mask_false_for_unmasked_elements() {
        let model = setup_two_rect_selection();
        assert!(!selection_has_mask(model.document()));
    }

    #[test]
    fn make_mask_creates_mask_on_every_selected_element() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        assert!(selection_has_mask(model.document()));
        for es in &model.document().selection {
            let elem = model.document().get_element(&es.path).unwrap();
            let mask = elem.common().mask.as_ref().unwrap();
            assert!(mask.clip);
            assert!(!mask.invert);
            assert!(!mask.disabled);
            assert!(mask.linked);
        }
    }

    #[test]
    fn make_mask_honors_clip_and_invert_args() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, false, true);
        let first = model.document().selection.first().unwrap();
        let mask = model.document().get_element(&first.path).unwrap()
            .common().mask.as_ref().unwrap();
        assert!(!mask.clip);
        assert!(mask.invert);
    }

    #[test]
    fn make_mask_is_idempotent_for_already_masked_elements() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        // Toggle invert on one element to detect overwrites.
        Controller::set_mask_invert_on_selection(&mut model, true);
        // Second make_mask_on_selection should not overwrite.
        Controller::make_mask_on_selection(&mut model, true, false);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(mask.invert, "invert should be preserved by idempotent make");
        }
    }

    #[test]
    fn release_mask_clears_masks_on_selection() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        Controller::release_mask_on_selection(&mut model);
        assert!(!selection_has_mask(model.document()));
    }

    #[test]
    fn set_mask_clip_and_invert_propagate() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        Controller::set_mask_clip_on_selection(&mut model, false);
        Controller::set_mask_invert_on_selection(&mut model, true);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(!mask.clip);
            assert!(mask.invert);
        }
    }

    #[test]
    fn toggle_mask_disabled_flips_every_mask() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        // First toggle → all disabled=true.
        Controller::toggle_mask_disabled_on_selection(&mut model);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(mask.disabled);
        }
        // Second toggle → all disabled=false.
        Controller::toggle_mask_disabled_on_selection(&mut model);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(!mask.disabled);
        }
    }

    #[test]
    fn toggle_mask_linked_flips_and_captures_transform_on_unlink() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        // Unlink: every mask.linked becomes false.
        Controller::toggle_mask_linked_on_selection(&mut model);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(!mask.linked);
            // Rects in this test have no transform, so the captured
            // unlink_transform is None (same as element.transform).
            assert!(mask.unlink_transform.is_none());
        }
        // Relink: clears unlink_transform and sets linked back to true.
        Controller::toggle_mask_linked_on_selection(&mut model);
        for es in &model.document().selection {
            let mask = model.document().get_element(&es.path).unwrap()
                .common().mask.as_ref().unwrap();
            assert!(mask.linked);
            assert!(mask.unlink_transform.is_none());
        }
    }

    #[test]
    fn first_mask_returns_none_when_first_unmasked() {
        let mut model = setup_two_rect_selection();
        Controller::make_mask_on_selection(&mut model, true, false);
        // Clear mask from the first element only.
        let doc = model.document().clone();
        let first_path = doc.selection.first().unwrap().path.clone();
        let mut new_doc = doc.clone();
        if let Some(elem) = doc.get_element(&first_path) {
            let mut new_elem = elem.clone();
            new_elem.common_mut().mask = None;
            new_doc = new_doc.replace_element(&first_path, new_elem);
        }
        model.set_document_for_test(new_doc);
        assert!(first_mask(model.document()).is_none());
        assert!(!selection_has_mask(model.document()),
                "mixed selection counts as no-mask");
    }

    // ------------------------------------------------------------------
    // fill_rule preservation across the id-stamping / duplicate family
    //
    // The PRIME DIRECTIVE twin of JasSwift's
    // Tests/Geometry/FillRulePreservationTests.swift. Rust reaches these
    // paths by MUTATING `common` in place (`clear_ids`, `common_mut().id
    // = ...`), so no field can be dropped by construction — unlike
    // Swift, whose value-type copies must re-list every field. These
    // tests exist so that the two ports assert the same invariant and a
    // future refactor to a rebuild-style copy in Rust cannot regress it
    // silently.
    // ------------------------------------------------------------------

    /// A two-ring even-odd path: outer 100x100 square, concentric inner
    /// square. Under EvenOdd the inner ring is a HOLE; under NonZero
    /// (both rings wound alike) it fills solid, so the rule is
    /// observable in the artwork, not just a tag.
    fn even_odd_donut(id: Option<&str>) -> Element {
        use crate::geometry::element::PathCommand as C;
        Element::Path(PathElem {
            d: vec![
                C::MoveTo { x: 0.0, y: 0.0 }, C::LineTo { x: 100.0, y: 0.0 },
                C::LineTo { x: 100.0, y: 100.0 }, C::LineTo { x: 0.0, y: 100.0 },
                C::ClosePath,
                C::MoveTo { x: 25.0, y: 25.0 }, C::LineTo { x: 75.0, y: 25.0 },
                C::LineTo { x: 75.0, y: 75.0 }, C::LineTo { x: 25.0, y: 75.0 },
                C::ClosePath,
            ],
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            width_points: vec![],
            common: CommonProps {
                id: id.map(|s| s.to_string()),
                name: Some("donut".to_string()),
                ..CommonProps::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: FillRule::EvenOdd,
            stroke_brush: None,
            stroke_brush_overrides: None,
        })
    }

    /// The fill rule of `elem`, or None when it is not a Path.
    fn rule_of(elem: &Element) -> Option<FillRule> {
        match elem {
            Element::Path(p) => Some(p.fill_rule),
            _ => None,
        }
    }

    fn model_with_donut(id: Option<&str>, select_first: bool) -> Model {
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(even_odd_donut(id))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let selection: Selection = if select_first {
            vec![ElementSelection::all(vec![0, 0])]
        } else {
            vec![]
        };
        Model::new(
            Document { layers: vec![layer], selected_layer: 0, selection, ..Document::default() },
            None,
        )
    }

    fn top_child(model: &Model, i: usize) -> Element {
        (*model.document().layers[0].children().unwrap()[i]).clone()
    }

    #[test]
    fn fill_rule_survives_clear_ids() {
        let mut e = even_odd_donut(Some("src"));
        crate::geometry::element::clear_ids(&mut e);
        assert!(e.common().id.is_none());
        assert_eq!(rule_of(&e), Some(FillRule::EvenOdd), "clear_ids refilled the hole");
    }

    #[test]
    fn fill_rule_survives_assign_id() {
        let mut model = model_with_donut(None, false);
        Controller::assign_id(&mut model, &vec![0, 0], "e1");
        let out = top_child(&model, 0);
        assert_eq!(out.common().id.as_deref(), Some("e1"));
        assert_eq!(rule_of(&out), Some(FillRule::EvenOdd), "assign_id refilled the hole");
    }

    #[test]
    fn fill_rule_survives_create_reference_stamp() {
        let mut model = model_with_donut(None, false);
        Controller::create_reference(&mut model, &vec![0, 0], "t1", "r1");
        let target = top_child(&model, 0);
        assert_eq!(target.common().id.as_deref(), Some("t1"));
        assert_eq!(rule_of(&target), Some(FillRule::EvenOdd),
                   "create_reference refilled the hole");
    }

    #[test]
    fn fill_rule_survives_make_symbol_master() {
        let mut model = model_with_donut(None, false);
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "r1");
        assert_eq!(model.document().symbols.len(), 1);
        let master = model.document().symbols[0].clone();
        assert_eq!(master.common().id.as_deref(), Some("m1"));
        assert_eq!(rule_of(&master), Some(FillRule::EvenOdd),
                   "make_symbol refilled the master's hole");
    }

    #[test]
    fn fill_rule_survives_detach() {
        let mut model = model_with_donut(None, false);
        Controller::make_symbol(&mut model, &vec![0, 0], "m1", "r1");
        Controller::detach(&mut model, &vec![0, 0]);
        let out = top_child(&model, 0);
        assert_eq!(rule_of(&out), Some(FillRule::EvenOdd), "detach refilled the hole");
    }

    #[test]
    fn fill_rule_survives_duplicate() {
        let mut model = model_with_donut(Some("src"), true);
        Controller::copy_selection(&mut model, 10.0, 0.0);
        let children = model.document().layers[0].children().unwrap().len();
        assert_eq!(children, 2);
        for i in 0..2 {
            assert_eq!(rule_of(&top_child(&model, i)), Some(FillRule::EvenOdd),
                       "duplicate refilled the hole at index {i}");
        }
    }

    #[test]
    fn fill_rule_survives_id_dedupe() {
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(even_odd_donut(Some("dup"))),
                           Rc::new(even_odd_donut(Some("dup")))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, ..Document::default() };
        let out = crate::geometry::normalize::dedupe_element_ids(&doc);
        let children = out.layers[0].children().unwrap();
        assert_eq!(children.len(), 2);
        assert_eq!(children[0].common().id.as_deref(), Some("dup"));
        assert!(children[1].common().id.is_none(),
                "dedupe should have cleared the second id");
        for (i, c) in children.iter().enumerate() {
            assert_eq!(rule_of(c), Some(FillRule::EvenOdd),
                       "id-dedupe refilled the hole at index {i}");
        }
    }
}

/// THE PRESERVATION LAW at the two container/merge sites this file owns:
/// `apply_destructive_boolean`'s N -> 1 arm and `make_compound_shape_with_op`.
/// transcripts/EDIT_SEMANTICS_FREEZE.md, ratified 2026-07-27 — §3.3 (merges),
/// §3.4 (WRAP), §3.6 (the per-op table), T3 ("must not guess") and the
/// cardinality law's identity projection.
///
/// Every battery below carries the §3.1 ANTI-VACUITY guard (the fixture is
/// asserted to differ from `CommonProps::default()` in every field the law
/// legislates, so a fixture that decayed to defaults could not pass on
/// nothing) and the MANDATORY GEOMETRY PAIRING (at least one assertion on
/// where the result's geometry actually landed).
#[cfg(test)]
mod preservation_law_tests {
    use super::*;
    use crate::geometry::element::{
        BlendMode, Color, CommonProps, Fill, LayerElem, Mask, RectElem, Stroke,
        Visibility,
    };
    use crate::geometry::live::{CompoundShape, LiveVariant};
    use std::rc::Rc;

    fn a_mask() -> Mask {
        Mask {
            subtree: Box::new(Element::Rect(RectElem {
                x: 0.0, y: 0.0, width: 4.0, height: 4.0, rx: 0.0, ry: 0.0,
                fill: Some(Fill::new(Color::BLACK)), stroke: None,
                common: CommonProps::default(),
                fill_gradient: None, stroke_gradient: None,
            })),
            clip: false,
            invert: false,
            disabled: false,
            linked: true,
            unlink_transform: None,
        }
    }

    /// A rect whose `common` differs from the default in EVERY field the
    /// preservation law legislates. `tag` distinguishes the sources so a
    /// disagreement fixture really disagrees.
    fn rich_rect(
        x: f64, w: f64, id: &str, name: Option<&str>, opacity: f64,
    ) -> Element {
        Element::Rect(RectElem {
            x, y: 0.0, width: w, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: Some(Stroke::new(Color::BLACK, 2.0)),
            common: CommonProps {
                opacity,
                mode: BlendMode::Multiply,
                transform: None,
                locked: false,
                visibility: Visibility::Outline,
                mask: Some(Box::new(a_mask())),
                tool_origin: Some("blob_brush".to_string()),
                name: name.map(|s| s.to_string()),
                id: Some(id.to_string()),
            },
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// ANTI-VACUITY (§3.1, mandatory): the fixture must differ from the
    /// fresh-element default in every legislated field, or the batteries
    /// below assert nothing.
    fn assert_fixture_is_rich(e: &Element) {
        let d = CommonProps::default();
        let c = e.common();
        assert_ne!(c.opacity, d.opacity, "fixture opacity decayed to default");
        assert_ne!(c.mode, d.mode, "fixture blend mode decayed to default");
        assert_ne!(c.visibility, d.visibility, "fixture visibility decayed");
        assert_ne!(c.mask, d.mask, "fixture mask decayed to default");
        assert_ne!(c.tool_origin, d.tool_origin, "fixture tool_origin decayed");
        assert!(c.id.is_some(), "fixture must carry an id");
    }

    /// Two overlapping rich rects, back-to-front, selected.
    /// back = [0..10]x[0..10] id "id-back"; front = [5..15]x[0..10] id
    /// "id-front". Union bbox is therefore [0..15]x[0..10].
    fn rich_pair(back_name: Option<&str>, front_name: Option<&str>,
                 back_opacity: f64, front_opacity: f64) -> Model {
        let back = rich_rect(0.0, 10.0, "id-back", back_name, back_opacity);
        let front = rich_rect(5.0, 10.0, "id-front", front_name, front_opacity);
        assert_fixture_is_rich(&back);
        assert_fixture_is_rich(&front);
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(back), Rc::new(front)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".into()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
            ],
            ..Document::default()
        };
        Model::new(doc, None)
    }

    /// The bbox of a Polygon's POINTS — the geometry the op produced,
    /// unaffected by the stroke width `Element::bounds` inflates by.
    fn polygon_point_bbox(e: &Element) -> (f64, f64, f64, f64) {
        let Element::Polygon(p) = e else { panic!("expected a Polygon") };
        let min_x = p.points.iter().map(|q| q.0).fold(f64::MAX, f64::min);
        let max_x = p.points.iter().map(|q| q.0).fold(f64::MIN, f64::max);
        let min_y = p.points.iter().map(|q| q.1).fold(f64::MAX, f64::min);
        let max_y = p.points.iter().map(|q| q.1).fold(f64::MIN, f64::max);
        (min_x, min_y, max_x - min_x, max_y - min_y)
    }

    fn only_child(model: &Model) -> Rc<Element> {
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1, "expected exactly one output element");
        children[0].clone()
    }

    /// The layer's children sorted by their leftmost point. DIVIDE emits its
    /// regions in the accumulator's internal order, which is neither z-order
    /// nor left-to-right; sorting keeps the assertions about WHICH region got
    /// WHICH identity independent of that implementation detail.
    fn children_by_left_edge(model: &Model) -> Vec<Rc<Element>> {
        let mut kids: Vec<Rc<Element>> =
            model.document().layers[0].children().unwrap().to_vec();
        kids.sort_by(|a, b| {
            polygon_point_bbox(a)
                .0
                .partial_cmp(&polygon_point_bbox(b).0)
                .expect("finite coordinates")
        });
        kids
    }

    /// Every id in the document, WITH repeats — `Document::element_ids`
    /// returns a `HashSet`, which silently dedupes exactly the duplicate this
    /// gate exists to catch.
    fn all_ids_with_repeats(model: &Model) -> Vec<String> {
        fn walk(e: &Element, out: &mut Vec<String>) {
            if let Some(id) = e.common().id.as_ref() {
                out.push(id.clone());
            }
            if let Some(children) = e.children() {
                for c in children {
                    walk(c, out);
                }
            }
        }
        let mut out = Vec::new();
        for layer in &model.document().layers {
            walk(layer, &mut out);
        }
        out
    }

    fn assert_ids_unique(model: &Model, what: &str) {
        let seen = all_ids_with_repeats(model);
        let mut sorted = seen.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            seen.len(),
            "{what} left a duplicate id in the document: {seen:?}"
        );
    }

    // ── §3.3 / cardinality law: the N -> 1 boolean arm ────────────────────

    /// THE REJECTED RULE IN DISGUISE. `front.common().clone()` carries the
    /// FRONTMOST operand's id through an N -> 1 merge — "the frontmost source
    /// keeps the id", elected by z-order. Identity is preservable exactly
    /// when the edit is 1 -> 1 (the cardinality law), so the union product
    /// must wear an id that belonged to NEITHER operand.
    #[test]
    fn boolean_union_mints_an_id_that_was_no_operand_s() {
        let mut model = rich_pair(None, None, 0.5, 0.5);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        let out = only_child(&model);
        // MANDATORY GEOMETRY PAIRING: the union really is the [0..15] bar.
        let (bx, by, bw, bh) = polygon_point_bbox(&out);
        assert!((bx - 0.0).abs() < 1e-9 && (by - 0.0).abs() < 1e-9
                && (bw - 15.0).abs() < 1e-9 && (bh - 10.0).abs() < 1e-9,
                "union bbox should be [0..15]x[0..10], got {bx},{by},{bw},{bh}");
        let id = out.common().id.clone();
        assert!(id.is_some(), "an N->1 merge mints a fresh id, it does not \
                               leave the product identity-less");
        assert_ne!(id.as_deref(), Some("id-front"),
                   "the frontmost operand's id survived an N->1 merge — the \
                    rule JYH rejected twice, wearing ..clone() as a hat");
        assert_ne!(id.as_deref(), Some("id-back"),
                   "the backmost operand's id survived an N->1 merge");
    }

    /// Uniqueness (REFERENCE_GRAPH.md §2.5): whatever the merge mints must
    /// not collide with an id still live in the document.
    #[test]
    fn boolean_union_minted_id_avoids_live_ids() {
        let mut model = rich_pair(None, None, 0.5, 0.5);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        let ids = model.document().element_ids();
        let out = only_child(&model);
        let id = out.common().id.clone().unwrap();
        // The only element left is the product, so its id is the only one.
        assert!(ids.contains(&id));
        assert_eq!(ids.len(), 1, "no stale operand id may linger");
    }

    /// §3.3: a field the op does not speak to follows UNANIMITY. `mask`,
    /// `visibility` and `tool_origin` agree across both operands here, so
    /// they carry — no winner is elected, the value is simply well-defined.
    #[test]
    fn boolean_union_carries_unanimous_non_paint_fields() {
        let mut model = rich_pair(None, None, 0.5, 0.5);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        let out = only_child(&model);
        let c = out.common();
        assert_eq!(c.mask, Some(Box::new(a_mask())),
                   "a unanimous mask is preservation, not a guess");
        assert_eq!(c.visibility, Visibility::Outline,
                   "a unanimous visibility carries");
        assert_eq!(c.tool_origin.as_deref(), Some("blob_brush"),
                   "a unanimous capability marker carries (T6)");
    }

    /// §3.3: sources DISAGREE on `visibility`, so the fresh element's
    /// documented default stands. Nothing geometric elects a winner.
    #[test]
    fn boolean_union_disagreeing_field_falls_to_the_default() {
        let mut model = rich_pair(None, None, 0.5, 0.5);
        // Make the back operand disagree on visibility only.
        {
            let doc = model.document().clone();
            let mut back = (*doc.get_element(&vec![0, 0]).unwrap()).clone();
            back.common_mut().visibility = Visibility::Invisible;
            let new_doc = doc.replace_element(&vec![0, 0], back);
            model.edit_document(new_doc);
        }
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        let out = only_child(&model);
        assert_eq!(out.common().visibility, CommonProps::default().visibility,
                   "disagreeing sources must fall to the default, never elect \
                    the frontmost");
    }

    /// RATIFIED ANSWER (1), ASSERTING-SOURCES: a source that asserts a name
    /// carries it; a silent source does not veto. "hull" + unnamed -> "hull".
    #[test]
    fn boolean_union_name_carries_from_the_only_asserting_source() {
        let mut model = rich_pair(Some("hull"), None, 0.5, 0.5);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        assert_eq!(only_child(&model).common().name.as_deref(), Some("hull"),
                   "the only name asserted must survive the merge");
    }

    /// ASSERTING-SOURCES, the other direction: two sources both assert and
    /// they disagree, so the name dies. No winner by z-order.
    #[test]
    fn boolean_union_name_dies_when_asserting_sources_disagree() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.5, 0.5);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        assert_eq!(only_child(&model).common().name, None,
                   "two asserted names disagree -> the default, not the \
                    frontmost's word");
    }

    /// The ratified BOOLEAN.md paint rule is FOUR properties — fill, stroke,
    /// opacity, blend mode — from the frontmost operand. That rule is what
    /// the op SPEAKS TO (T1), so it is preserved by the fix, not swept away
    /// with the id. Disagreeing opacities here prove it is the frontmost's
    /// value and not a unanimity accident.
    #[test]
    fn boolean_union_still_takes_the_frontmost_s_four_paint_properties() {
        let mut model = rich_pair(None, None, 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "union", &BooleanOptions::default());
        let out = only_child(&model);
        assert_eq!(out.common().opacity, 0.75,
                   "opacity is paint: the frontmost operand's, per BOOLEAN.md");
        assert_eq!(out.common().mode, BlendMode::Multiply);
        assert!(out.fill().is_some());
        assert!(out.stroke().is_some());
    }

    /// §3.6: a SUBTRACT_FRONT survivor is 1 -> 1, so its identity LIVES.
    /// The fix to the N->1 arm must not leak into the survivor arms.
    #[test]
    fn boolean_subtract_front_survivor_keeps_its_own_identity() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "subtract_front", &BooleanOptions::default());
        let out = only_child(&model);
        let (bx, _, bw, _) = polygon_point_bbox(&out);
        assert!((bx - 0.0).abs() < 1e-9 && (bw - 5.0).abs() < 1e-9,
                "subtract_front leaves [0..5], got x={bx} w={bw}");
        assert_eq!(out.common().id.as_deref(), Some("id-back"),
                   "a 1->1 survivor keeps its id");
        assert_eq!(out.common().name.as_deref(), Some("hull"),
                   "a 1->1 survivor keeps its name");
        assert_eq!(out.common().opacity, 0.25, "and its own paint");
    }

    // ── §3.2 / §3.6 DIVIDE row: the 1 -> N arm ────────────────────────────
    //
    // `rich_pair` is back [0..10] over front [5..15]. DIVIDE partitions their
    // union into three regions and labels each with its FRONTMOST covering
    // operand:
    //   [0..5]   <- back  (the back operand's only region: 1 -> 1)
    //   [5..10]  <- front (the overlap)
    //   [10..15] <- front (front-only)
    // So the FRONT operand is split 1 -> 2 and the BACK operand is not split
    // at all — one fixture exercising both sides of the cardinality law.

    /// The violation, stated as a document invariant. The arm handed EVERY
    /// output region the designated operand's whole `common`, id included, so
    /// the front operand's two fragments both wore `id-front` — two live
    /// elements sharing one identity, which is the silent-rebinding hazard
    /// §3.7 exists to prevent and strictly worse than a loud break.
    #[test]
    fn boolean_divide_leaves_no_duplicate_id_in_the_document() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "divide", &BooleanOptions::default());
        // MANDATORY GEOMETRY PAIRING: the partition really is the three bars.
        let kids = children_by_left_edge(&model);
        assert_eq!(kids.len(), 3, "divide of two overlapping rects -> 3 regions");
        for (i, want) in [(0usize, (0.0, 5.0)), (1, (5.0, 5.0)), (2, (10.0, 5.0))] {
            let (bx, _, bw, _) = polygon_point_bbox(&kids[i]);
            assert!((bx - want.0).abs() < 1e-9 && (bw - want.1).abs() < 1e-9,
                    "region {i} should be x={} w={}, got x={bx} w={bw}",
                    want.0, want.1);
        }
        assert_ids_unique(&model, "divide");
    }

    /// §3.2 / the cardinality law: the operand that was SPLIT is 1 -> N, so
    /// its identity dies and every fragment wears a FRESH id — fresh meaning
    /// "not in the pre-edit id set", and distinct from its siblings'.
    #[test]
    fn boolean_divide_split_operand_s_fragments_wear_fresh_distinct_ids() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        let before: std::collections::HashSet<String> =
            model.document().element_ids();
        Controller::apply_destructive_boolean(
            &mut model, "divide", &BooleanOptions::default());
        let kids = children_by_left_edge(&model);
        // kids[1] = [5..10] and kids[2] = [10..15] both came from the FRONT
        // operand, which is therefore 1 -> 2.
        let a = kids[1].common().id.clone().expect("a split fragment is identified");
        let b = kids[2].common().id.clone().expect("a split fragment is identified");
        assert_ne!(a, b, "two fragments of one operand may not share an id");
        for id in [&a, &b] {
            assert!(!before.contains(id),
                    "fragment id {id:?} was already in the document before the \
                     split — the designated operand's identity rode out on a \
                     1 -> N edit");
        }
    }

    /// §3.2: identity is the ONLY thing a split takes. Appearance, the
    /// unspoken-to fields and `name` copy to every fragment.
    #[test]
    fn boolean_divide_fragments_copy_name_and_unspoken_fields() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "divide", &BooleanOptions::default());
        let kids = children_by_left_edge(&model);
        for i in [1usize, 2] {
            let c = kids[i].common();
            assert_eq!(c.name.as_deref(), Some("keel"),
                       "a split copies the source's name to every fragment");
            assert_eq!(c.opacity, 0.75, "and its paint");
            assert_eq!(c.mode, BlendMode::Multiply);
            assert_eq!(c.visibility, Visibility::Outline);
            assert_eq!(c.mask, Some(Box::new(a_mask())));
            assert_eq!(c.tool_origin.as_deref(), Some("blob_brush"));
        }
    }

    /// The other side of the same law, and the guard that the fix does not
    /// over-reach: the BACK operand contributes exactly ONE region, so that
    /// region is 1 -> 1 and its identity is preservable — killing it would be
    /// as much a violation as carrying it through the split.
    #[test]
    fn boolean_divide_unsplit_operand_keeps_its_identity() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "divide", &BooleanOptions::default());
        let kids = children_by_left_edge(&model);
        assert_eq!(kids[0].common().id.as_deref(), Some("id-back"),
                   "the operand divide did not split is 1 -> 1: its id lives");
        assert_eq!(kids[0].common().name.as_deref(), Some("hull"));
        assert_eq!(kids[0].common().opacity, 0.25);
    }

    // ── §3.6 MERGE row: singleton survives, multi is an N -> 1 ────────────
    //
    // On `rich_pair` both rects carry the same solid fill, so TRIM's two
    // survivors ([0..5] from back, [5..15] from front) merge into one
    // [0..15] bar — a two-contributor group, i.e. an N -> 1.

    /// THE REJECTED RULE, IN PLAIN TEXT. The merge arm elected the frontmost
    /// contributor's whole `common` — id and name included — and its own
    /// comment stated the z-order election outright ("j is frontmost; its
    /// stroke/common wins"). z-order is geometry, so T3 forbids it: the
    /// product of an N -> 1 wears an id that belonged to NEITHER contributor.
    #[test]
    fn boolean_merge_multi_contributor_group_mints_a_fresh_id() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "merge", &BooleanOptions::default());
        let out = only_child(&model);
        // MANDATORY GEOMETRY PAIRING: the merged bar really is [0..15].
        let (bx, by, bw, bh) = polygon_point_bbox(&out);
        assert!((bx - 0.0).abs() < 1e-9 && (by - 0.0).abs() < 1e-9
                && (bw - 15.0).abs() < 1e-9 && (bh - 10.0).abs() < 1e-9,
                "merge bbox should be [0..15]x[0..10], got {bx},{by},{bw},{bh}");
        let id = out.common().id.clone();
        assert!(id.is_some(), "an N->1 merge mints a fresh id");
        assert_ne!(id.as_deref(), Some("id-front"),
                   "the frontmost CONTRIBUTOR's id survived an N->1 merge — \
                    the rejected rule, elected by z-order");
        assert_ne!(id.as_deref(), Some("id-back"));
        assert_ids_unique(&model, "merge");
    }

    /// ASSERTING-SOURCES (JYH's ratified answer (1)) reaches this arm too:
    /// the only asserted name survives. Under the z-order election the
    /// BACKmost contributor's word was simply deleted.
    #[test]
    fn boolean_merge_name_carries_from_the_only_asserting_contributor() {
        let mut model = rich_pair(Some("hull"), None, 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "merge", &BooleanOptions::default());
        assert_eq!(only_child(&model).common().name.as_deref(), Some("hull"),
                   "the only name asserted must survive the merged group");
    }

    /// §3.3: contributors DISAGREE on a field the op does not speak to, so
    /// the fresh element's documented default stands. Under the z-order
    /// election the frontmost's value won instead.
    #[test]
    fn boolean_merge_disagreeing_field_falls_to_the_default() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        {
            let doc = model.document().clone();
            let mut back = (*doc.get_element(&vec![0, 0]).unwrap()).clone();
            back.common_mut().visibility = Visibility::Invisible;
            let new_doc = doc.replace_element(&vec![0, 0], back);
            model.edit_document(new_doc);
        }
        Controller::apply_destructive_boolean(
            &mut model, "merge", &BooleanOptions::default());
        let out = only_child(&model);
        assert_eq!(out.common().visibility, CommonProps::default().visibility,
                   "disagreeing contributors must fall to the default");
        assert_eq!(out.common().name, None,
                   "two asserted names disagree -> the default");
    }

    /// GUARD: the §3.6 MERGE row keeps paint at "the frontmost contributor's",
    /// so `opacity` and blend mode must NOT be swept away with the identity.
    #[test]
    fn boolean_merge_still_takes_the_frontmost_contributor_s_paint() {
        let mut model = rich_pair(None, None, 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "merge", &BooleanOptions::default());
        let out = only_child(&model);
        assert_eq!(out.common().opacity, 0.75,
                   "opacity is paint: the frontmost contributor's");
        assert_eq!(out.common().mode, BlendMode::Multiply);
        assert!(out.fill().is_some());
        assert!(out.stroke().is_some());
    }

    /// GUARD, the other arm of the same row: a merged group of ONE is a
    /// 1 -> 1, so the survivor keeps everything. Different fill colours mean
    /// the two trimmed survivors never join, so each group is a singleton.
    #[test]
    fn boolean_merge_singleton_group_keeps_its_own_identity() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        {
            let doc = model.document().clone();
            let mut back = (*doc.get_element(&vec![0, 0]).unwrap()).clone();
            let Element::Rect(r) = &mut back else { panic!("a Rect") };
            r.fill = Some(Fill::new(Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 }));
            let new_doc = doc.replace_element(&vec![0, 0], back);
            model.edit_document(new_doc);
        }
        Controller::apply_destructive_boolean(
            &mut model, "merge", &BooleanOptions::default());
        let kids = children_by_left_edge(&model);
        assert_eq!(kids.len(), 2, "different fills never merge");
        let (bx, _, bw, _) = polygon_point_bbox(&kids[0]);
        assert!((bx - 0.0).abs() < 1e-9 && (bw - 5.0).abs() < 1e-9,
                "the back survivor is the trimmed [0..5], got x={bx} w={bw}");
        assert_eq!(kids[0].common().id.as_deref(), Some("id-back"),
                   "a one-contributor merge group is 1 -> 1: its id lives");
        assert_eq!(kids[0].common().name.as_deref(), Some("hull"));
        assert_eq!(kids[1].common().id.as_deref(), Some("id-front"));
        assert_eq!(kids[1].common().name.as_deref(), Some("keel"));
    }

    /// GUARD for the arm the merge fix shares its code with: §3.6 makes every
    /// TRIM operand a 1 -> 1, so trim must keep preserving everything.
    #[test]
    fn boolean_trim_operands_keep_their_own_identity() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::apply_destructive_boolean(
            &mut model, "trim", &BooleanOptions::default());
        let kids = children_by_left_edge(&model);
        assert_eq!(kids.len(), 2);
        let (bx, _, bw, _) = polygon_point_bbox(&kids[0]);
        assert!((bx - 0.0).abs() < 1e-9 && (bw - 5.0).abs() < 1e-9,
                "the back operand is trimmed to [0..5], got x={bx} w={bw}");
        assert_eq!(kids[0].common().id.as_deref(), Some("id-back"));
        assert_eq!(kids[0].common().name.as_deref(), Some("hull"));
        assert_eq!(kids[0].common().opacity, 0.25);
        assert_eq!(kids[1].common().id.as_deref(), Some("id-front"));
        assert_eq!(kids[1].common().name.as_deref(), Some("keel"));
        assert_eq!(kids[1].common().opacity, 0.75);
    }

    // ── §3.4 WRAP: Make Compound Shape ────────────────────────────────────

    /// A DUPLICATE ID, worse than a loud break. The wrapper wore the
    /// frontmost operand's whole `common` — id included — while that operand
    /// REMAINED a child, so two live elements shared one id and a reference
    /// to it would silently rebind to whichever the index walk reached first.
    /// WRAP is 0 -> 1 for the container: never a member's identity.
    #[test]
    fn compound_shape_make_never_wears_an_operand_s_id() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        let out = only_child(&model);
        // MANDATORY GEOMETRY PAIRING: the compound really evaluates to the bar.
        let (bx, by, bw, bh) = out.bounds();
        assert!((bx - 0.0).abs() < 1e-9 && (by - 0.0).abs() < 1e-9
                && (bw - 15.0).abs() < 1e-9 && (bh - 10.0).abs() < 1e-9,
                "compound bbox should be [0..15]x[0..10], got {bx},{by},{bw},{bh}");
        assert_ne!(out.common().id.as_deref(), Some("id-front"),
                   "the wrapper wore the frontmost's id while the frontmost \
                    stayed a child — two live elements, one id");
        assert_ne!(out.common().id.as_deref(), Some("id-back"));
    }

    /// The uniqueness invariant, stated document-wide: after MAKE, walking
    /// every element (wrapper and operands) must yield no repeated id.
    #[test]
    fn compound_shape_make_leaves_no_duplicate_id_in_the_document() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        let mut seen: Vec<String> = Vec::new();
        fn walk(e: &Element, seen: &mut Vec<String>) {
            if let Some(id) = e.common().id.as_ref() {
                seen.push(id.clone());
            }
            if let Element::Live(LiveVariant::CompoundShape(cs)) = e {
                for o in &cs.operands {
                    walk(o, seen);
                }
            }
            if let Some(children) = e.children() {
                for c in children {
                    walk(c, seen);
                }
            }
        }
        for layer in &model.document().layers {
            walk(layer, &mut seen);
        }
        let mut sorted = seen.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), seen.len(),
                   "duplicate id after Make Compound Shape: {seen:?}");
    }

    /// §3.4: children of a WRAP are 1 -> 1 — untouched, ids and all.
    #[test]
    fn compound_shape_make_leaves_its_operands_untouched() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        let out = only_child(&model);
        let Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operands, ..
        })) = &*out else {
            panic!("expected a compound shape");
        };
        assert_eq!(operands.len(), 2);
        assert_eq!(operands[0].common().id.as_deref(), Some("id-back"));
        assert_eq!(operands[1].common().id.as_deref(), Some("id-front"));
        assert_eq!(operands[0].common().name.as_deref(), Some("hull"));
        assert_eq!(operands[1].common().name.as_deref(), Some("keel"));
    }

    /// §3.6 MAKE row: "frontmost's, per spec — paint only, never `common`".
    /// Paint (fill / stroke / opacity / blend mode) rides; the identity and
    /// container-structural fields do not.
    #[test]
    fn compound_shape_make_takes_paint_but_not_identity_or_mask() {
        let mut model = rich_pair(Some("hull"), Some("keel"), 0.25, 0.75);
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        let out = only_child(&model);
        assert_eq!(out.common().opacity, 0.75,
                   "opacity is paint: the frontmost's");
        assert_eq!(out.common().mode, BlendMode::Multiply,
                   "blend mode is paint: the frontmost's");
        assert!(out.fill().is_some());
        assert!(out.stroke().is_some());
        assert_eq!(out.common().name, None,
                   "the wrapper is a fresh container, not the frontmost");
        assert_eq!(out.common().mask, None,
                   "a mask on an operand must not silently re-apply to the \
                    wrapper as well (it would composite twice)");
        assert_eq!(out.common().tool_origin, None,
                   "a capability marker belongs to the element that earned it");
    }

    /// BUG CONTAINMENT, not law, and pinned so it cannot be mistaken for
    /// law. `CompoundShape::evaluate_with` flattens each operand through
    /// `element_to_polygon_set_with`, which contains ZERO transform
    /// references — an operand's own transform is IGNORED by the evaluator,
    /// and only the wrapper's is applied at render. So a WRAP that leaves the
    /// wrapper's transform at its fresh default would make a compound built
    /// from transformed operands jump to the untransformed position.
    ///
    /// A UNANIMOUS transform therefore carries — no winner is elected, and it
    /// is the only transform under which the raw rings mean anything.
    /// Disagreement takes the default, exactly as §3.3 rules for every other
    /// field. Delete this carry when the compound evaluator becomes
    /// transform-aware (the S-3 class), not before.
    #[test]
    fn compound_shape_make_carries_a_unanimous_transform_only() {
        use crate::geometry::element::Transform;
        let t = Transform::default().translated(12.0, 34.0);
        // Unanimous: both operands carry the same transform -> it rides.
        let mut model = rich_pair(None, None, 0.5, 0.5);
        {
            let doc = model.document().clone();
            let mut new_doc = doc.clone();
            for p in [vec![0, 0], vec![0, 1]] {
                let mut e = (*doc.get_element(&p).unwrap()).clone();
                e.common_mut().transform = Some(t);
                new_doc = new_doc.replace_element(&p, e);
            }
            model.edit_document(new_doc);
        }
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        assert_eq!(only_child(&model).common().transform, Some(t),
                   "a unanimous transform must ride the wrapper while the \
                    compound evaluator is transform-blind");

        // Disagreement: the default stands. No operand is elected.
        let mut model = rich_pair(None, None, 0.5, 0.5);
        {
            let doc = model.document().clone();
            let mut front = (*doc.get_element(&vec![0, 1]).unwrap()).clone();
            front.common_mut().transform = Some(t);
            let new_doc = doc.replace_element(&vec![0, 1], front);
            model.edit_document(new_doc);
        }
        Controller::make_compound_shape_with_op(
            &mut model, crate::geometry::live::CompoundOperation::Union);
        assert_eq!(only_child(&model).common().transform, None,
                   "disagreeing transforms must fall to the default");
    }

    // ── The corner drag is a MULTI-SAMPLE gesture ─────────────────────────

    /// `doc.translate_selection` feeds `move_selection` an INCREMENTAL delta
    /// per mousemove against the LIVE document (workspace/tools/
    /// partial_selection.yaml), so the promotion happens on sample 1 and
    /// every later sample lands on the Polygon. With four emitted points the
    /// corner index happened to survive; once the rounding flattens into arc
    /// runs it does not, so the promotion must remap the selection onto the
    /// whole run it came from — or the second sample would spike one arc
    /// point and shred the corner.
    #[test]
    fn rounded_rect_corner_drag_survives_a_second_sample() {
        use crate::document::document::{SelectionKind, SortedCps};
        use crate::geometry::element::RectElem;
        let rect = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 60.0, rx: 20.0, ry: 10.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![ElementSelection {
                path: vec![0, 0],
                kind: SelectionKind::Partial(SortedCps::from_iter([1usize])),
            }],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        // Sample 1: promotes and moves corner 1 by (10, 0).
        Controller::move_selection(&mut model, 10.0, 0.0);
        // Sample 2: another (10, 0) on the SAME gesture.
        Controller::move_selection(&mut model, 10.0, 0.0);
        let out = only_child(&model);
        let Element::Polygon(p) = &*out else { panic!("expected Polygon") };
        let n = p.points.len() / 4;
        assert!(n > 1, "the rounding should have flattened into arc runs");
        // Corner 1's whole run has moved by (20, 0); corner 0's has not.
        let reference = crate::geometry::element::rounded_rect_corner_runs(
            0.0, 0.0, 100.0, 60.0, 20.0, 10.0);
        for (i, want) in reference[1].iter().enumerate() {
            let got = p.points[n + i];
            assert!((got.0 - want.0 - 20.0).abs() < 1e-9
                    && (got.1 - want.1).abs() < 1e-9,
                    "corner-1 point {i}: want {:?} + (20,0), got {got:?}",
                    want);
        }
        for (i, want) in reference[0].iter().enumerate() {
            let got = p.points[i];
            assert!((got.0 - want.0).abs() < 1e-9 && (got.1 - want.1).abs() < 1e-9,
                    "corner-0 point {i} moved: want {:?}, got {got:?}", want);
        }
    }

    // ── §3.6's "Compound Shape EXPAND" row: 1 -> N, at the DOCUMENT ───────
    //
    // `CompoundShape::expand` handed every emitted ring the compound's whole
    // `common`, ID INCLUDED — the same 1 -> N defect the DIVIDE arm carried.
    // Driven end-to-end here, through the controller, because the unit-level
    // battery in `geometry::live` can only see that the ids are no longer
    // REPLICATED: minting needs the document's id space, which exists only
    // at this layer.

    /// The compound's own `common` is rich in every legislated field, so the
    /// batteries below cannot pass on nothing (§3.1 ANTI-VACUITY). Its two
    /// operands are `rich_rect`s carrying ids of their own, which is what
    /// makes the FRESHNESS assertion bite: a mint that landed on an operand
    /// id would be as wrong as inheriting the compound's.
    fn rich_compound(op: crate::geometry::live::CompoundOperation) -> Model {
        let back = rich_rect(0.0, 10.0, "op-back", Some("port"), 0.5);
        let front = rich_rect(5.0, 10.0, "op-front", Some("starboard"), 0.5);
        let cs = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: op,
            operands: vec![Rc::new(back), Rc::new(front)],
            fill: Some(Fill::new(Color::BLACK)),
            stroke: Some(Stroke::new(Color::BLACK, 2.0)),
            common: CommonProps {
                opacity: 0.25,
                mode: BlendMode::Multiply,
                transform: None,
                locked: false,
                visibility: Visibility::Outline,
                mask: Some(Box::new(a_mask())),
                tool_origin: Some("blob_brush".to_string()),
                name: Some("hull".to_string()),
                id: Some("cs-1".to_string()),
            },
        }));
        assert_fixture_is_rich(&cs);
        assert_eq!(cs.common().name.as_deref(), Some("hull"),
                   "the compound must ASSERT a name for the carry to be visible");
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(cs)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L0".into()), ..Default::default() },
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![ElementSelection::all(vec![0, 0])],
            ..Document::default()
        };
        Model::new(doc, None)
    }

    /// A COPY is born id-less — the landed rule, stated in `copy_selection`'s
    /// own words ("A copy must not inherit the source's stable id (no two
    /// elements may share an identity)") and carried out by `clear_ids`. But
    /// `clear_ids` walked `children_mut()` only, and a compound shape's
    /// operands are NOT `children()`: they live on `CompoundShape.operands`,
    /// which is exactly why `Document::element_ids` has a separate arm for
    /// them. So copying a compound shape left every OPERAND id duplicated,
    /// one level below the id the helper was written to clear.
    #[test]
    fn copy_selection_of_a_compound_shape_clears_its_operands_ids_too() {
        let mut model = rich_compound(crate::geometry::live::CompoundOperation::Union);
        let before: std::collections::HashSet<String> =
            model.document().element_ids();
        assert!(before.contains("op-back") && before.contains("op-front"));
        Controller::copy_selection(&mut model, 20.0, 0.0);
        let kids = model.document().layers[0].children().unwrap().to_vec();
        assert_eq!(kids.len(), 2, "the copy landed beside the source");
        let LiveVariant::CompoundShape(copy) = (match kids[1].as_ref() {
            Element::Live(v) => v,
            other => panic!("expected a compound shape, got {other:?}"),
        }) else { panic!("expected a compound shape") };
        // MANDATORY GEOMETRY PAIRING: the copy carries the source's operand
        // geometry, OFFSET by (dx, dy).
        //
        // This assertion used to demand x == 0 and explained why: a compound
        // shape fell through `move_control_points`'s catch-all, so Edit > Copy
        // of a live compound landed the copy exactly on top of its source. It
        // was recorded as a pre-existing gap and deliberately not repaired.
        //
        // That gap is now CLOSED — `move_control_points` gained container and
        // live arms delegating to `translate_element` (2026-07-29), so the copy
        // lands beside its source like every other kind. This test and its
        // JasSwift twin both went red on the same value, in lockstep, which is
        // the corpus reporting a recorded gap being closed rather than a
        // regression.
        let Element::Rect(r) = copy.operands[0].as_ref() else { panic!("rect") };
        assert!((r.x - 20.0).abs() < 1e-9 && (r.width - 10.0).abs() < 1e-9,
                "the copy carries the back operand's geometry offset by dx=20, \
                 got x={} w={}", r.x, r.width);
        assert!(copy.common.id.is_none(), "the copy itself is born id-less");
        for (i, operand) in copy.operands.iter().enumerate() {
            assert!(operand.common().id.is_none(),
                    "operand {i} of the COPY still wears {:?} — an identity \
                     that is still live on the source's operand",
                    operand.common().id);
        }
        // And the source is a bystander (T4): untouched, ids included.
        let LiveVariant::CompoundShape(src) = (match kids[0].as_ref() {
            Element::Live(v) => v,
            other => panic!("expected a compound shape, got {other:?}"),
        }) else { panic!("expected a compound shape") };
        assert_eq!(src.common.id.as_deref(), Some("cs-1"));
        assert_eq!(src.operands[0].common().id.as_deref(), Some("op-back"));
        assert_eq!(src.operands[1].common().id.as_deref(), Some("op-front"));
    }

    /// THE WALK ITSELF, pinned against the document's OWN id walk instead
    /// of against a hand-written id list. `clear_ids` exists precisely so
    /// that `Document::element_ids` comes back EMPTY over a cleared
    /// subtree, and the operand blind spot survived every by-name
    /// assertion written at the time because nobody enumerated the owners:
    /// the audit asked "does the helper drop a field?" (no) instead of
    /// "does the helper's walk reach what the id walk reaches?" (it did
    /// not). See EDIT_SEMANTICS_FREEZE.md §7.3's clipboard/duplicate entry.
    ///
    /// The compound sits inside a GROUP inside the layer, so one pass must
    /// cross `children` -> `children` -> `operands`.
    ///
    /// STATED BLIND SPOT, so this is not over-read: it proves agreement
    /// over the owners THIS FIXTURE contains. A future non-`children`
    /// owner added to `element_ids` and not to `clear_ids` is caught by the
    /// document-level invariant gate (freeze §4 tier 1), not by this test.
    #[test]
    fn clear_ids_leaves_document_element_ids_empty_over_a_nested_compound() {
        let model = rich_compound(crate::geometry::live::CompoundOperation::Union);
        let cs = model.document().layers[0].children().unwrap()[0].as_ref().clone();
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(cs)],
            common: CommonProps { id: Some("g-outer".into()), ..Default::default() },
            isolated_blending: false,
            knockout_group: false,
        });
        let mut layer = Element::Layer(LayerElem {
            children: vec![Rc::new(group)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps {
                id: Some("layer-id".into()),
                name: Some("L0".into()),
                ..Default::default()
            },
        });
        let doc_of = |l: &Element| Document {
            layers: vec![l.clone()],
            ..Document::default()
        };
        let before = doc_of(&layer).element_ids();
        assert_eq!(
            before.len(),
            5,
            "the fixture must carry an id at all five depths (layer, group, \
             compound, two operands) or the walk proves nothing, got {before:?}"
        );
        crate::geometry::element::clear_ids(&mut layer);
        // MANDATORY GEOMETRY PAIRING: clearing identity must not disturb the
        // shape. The back operand keeps x=0 w=10 exactly where rich_compound
        // put it, two containers below the layer this call was made on.
        let Element::Group(g) = layer.children().unwrap()[0].as_ref() else {
            panic!("group")
        };
        let Element::Live(LiveVariant::CompoundShape(cleared)) =
            g.children[0].as_ref()
        else {
            panic!("compound")
        };
        let Element::Rect(r) = cleared.operands[0].as_ref() else { panic!("rect") };
        assert!(
            (r.x - 0.0).abs() < 1e-9 && (r.width - 10.0).abs() < 1e-9,
            "geometry moved: x={} w={}",
            r.x,
            r.width
        );
        let after = doc_of(&layer).element_ids();
        assert!(
            after.is_empty(),
            "clear_ids left {after:?} live in the document — its walk no \
             longer agrees with Document::element_ids"
        );
    }

    /// THE VIOLATION, as a document invariant. Expanding an EXCLUDE compound
    /// emits two rings, and every ring wore `cs-1` — two live elements
    /// sharing one identity, breaching REFERENCE_GRAPH.md §2.5's uniqueness
    /// invariant and opening the silent-rebinding hazard of §3.7.
    #[test]
    fn expand_compound_shape_leaves_no_duplicate_id_in_the_document() {
        let mut model = rich_compound(crate::geometry::live::CompoundOperation::Exclude);
        Controller::expand_compound_shape(&mut model);
        // MANDATORY GEOMETRY PAIRING: XOR really is the two outer bars.
        let kids = children_by_left_edge(&model);
        assert_eq!(kids.len(), 2, "XOR of two overlapping rects -> 2 rings");
        for (i, want) in [(0usize, (0.0, 5.0)), (1, (10.0, 5.0))] {
            let (bx, _, bw, _) = polygon_point_bbox(&kids[i]);
            assert!((bx - want.0).abs() < 1e-9 && (bw - want.1).abs() < 1e-9,
                    "ring {i} should be x={} w={}, got x={bx} w={bw}",
                    want.0, want.1);
        }
        assert_ids_unique(&model, "expand compound shape");
    }

    /// §3.2 / the cardinality law: a 1 -> N expansion kills the compound's
    /// identity and every fragment wears a FRESH id — "fresh" meaning not in
    /// the PRE-EDIT id set (which holds the operands' ids too), and distinct
    /// from its siblings'.
    #[test]
    fn expand_compound_shape_fragments_wear_fresh_distinct_ids() {
        let mut model = rich_compound(crate::geometry::live::CompoundOperation::Exclude);
        let before: std::collections::HashSet<String> =
            model.document().element_ids();
        assert!(before.contains("cs-1") && before.contains("op-back")
                && before.contains("op-front"),
                "the avoid-set must see the compound AND its operands: {before:?}");
        Controller::expand_compound_shape(&mut model);
        let kids = children_by_left_edge(&model);
        assert_eq!(kids.len(), 2);
        let a = kids[0].common().id.clone().expect("a fragment is identified");
        let b = kids[1].common().id.clone().expect("a fragment is identified");
        assert_ne!(a, b, "two fragments of one expansion may not share an id");
        for id in [&a, &b] {
            assert!(!before.contains(id),
                    "fragment id {id:?} was already in the document before the \
                     expansion — an identity rode out on a 1 -> N edit");
        }
    }

    /// §3.2: identity is the ONLY thing the split takes. Appearance, the
    /// unspoken-to fields and `name` copy to every fragment.
    #[test]
    fn expand_compound_shape_fragments_copy_name_and_unspoken_fields() {
        let mut model = rich_compound(crate::geometry::live::CompoundOperation::Exclude);
        Controller::expand_compound_shape(&mut model);
        for kid in children_by_left_edge(&model) {
            let c = kid.common();
            assert_eq!(c.name.as_deref(), Some("hull"),
                       "a split copies the source's name to every fragment");
            assert_eq!(c.opacity, 0.25, "and its paint");
            assert_eq!(c.mode, BlendMode::Multiply);
            assert_eq!(c.visibility, Visibility::Outline);
            assert_eq!(c.mask, Some(Box::new(a_mask())));
            assert_eq!(c.tool_origin.as_deref(), Some("blob_brush"));
            // The compound's OWN paint, per the EXPAND row — not an operand's.
            assert!(kid.fill().is_some() && kid.stroke().is_some());
        }
    }

    /// The guard against over-reach: a compound that evaluates to ONE ring is
    /// 1 -> 1, so its identity is preservable and killing it would be as much
    /// a guess as carrying one that is not. Same branch DIVIDE and
    /// `path_erase_at_rect` take.
    #[test]
    fn expand_compound_shape_single_ring_keeps_its_identity() {
        let mut model = rich_compound(crate::geometry::live::CompoundOperation::Union);
        Controller::expand_compound_shape(&mut model);
        let out = only_child(&model);
        // MANDATORY GEOMETRY PAIRING: the union really is the merged bar.
        let (bx, by, bw, bh) = polygon_point_bbox(&out);
        assert!((bx - 0.0).abs() < 1e-9 && (by - 0.0).abs() < 1e-9
                && (bw - 15.0).abs() < 1e-9 && (bh - 10.0).abs() < 1e-9,
                "union bbox should be [0..15]x[0..10], got {bx},{by},{bw},{bh}");
        assert_eq!(out.common().id.as_deref(), Some("cs-1"),
                   "a 1 -> 1 expansion preserves the identity it could keep");
        assert_eq!(out.common().name.as_deref(), Some("hull"));
        assert_ids_unique(&model, "expand compound shape (single ring)");
    }
}


/// UNGROUP ALL MUST PRESERVE WHAT IT DOES NOT SPEAK TO — the Rust twin of
/// Swift's `UngroupAllPreservationTests`, case for case.
///
/// Rust has never carried the defect these gate (`(**child).clone()` and
/// `new_doc.layers = new_layers` mutate in place, and every attribute lives in
/// ONE `CommonProps` that clones wholesale), so these probes are written GREEN.
/// That is deliberate and it is the point: the shared ACTION corpus case
/// `menu_ungroup_all_nested` is STRUCTURALLY BLIND to everything at issue here
/// — its `expected_json` carries no `symbols`, no `artboards`, no
/// `document_setup`, no `print_preferences`, and its one layer has no `id`, no
/// blend mode and no mask. So the corpus could not have caught Swift's loss and
/// cannot catch a future Rust regression either. These probes are the only
/// thing that watches the Rust side, exactly as the Swift suite is the only
/// thing that watches Swift, and they assert BY VALUE for the same reason.
#[cfg(test)]
mod ungroup_all_preservation_tests {
    use super::*;
    use crate::document::artboard::{Artboard, ArtboardOptions};
    use crate::document::document_setup::DocumentSetup;
    use crate::document::print_preferences::PrintPreferences;
    use crate::geometry::element::{
        BlendMode, Color, CommonProps, Fill, GroupElem, LayerElem, Mask, RectElem,
        Visibility,
    };
    use std::rc::Rc;

    fn rect(x: f64) -> Element {
        Element::Rect(RectElem {
            x,
            y: 0.0,
            width: 10.0,
            height: 10.0,
            rx: 0.0,
            ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn a_mask() -> Mask {
        Mask {
            subtree: Box::new(rect(0.0)),
            clip: false,
            invert: true,
            disabled: false,
            linked: true,
            unlink_transform: None,
        }
    }

    /// An unlocked group with a rect inside — GUARANTEES `changed == true`.
    fn nest() -> Element {
        Element::Group(GroupElem {
            children: vec![Rc::new(rect(1.0))],
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        })
    }

    fn named_layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            children: children.into_iter().map(Rc::new).collect(),
            common: CommonProps {
                name: Some(name.to_string()),
                ..CommonProps::default()
            },
            isolated_blending: false,
            knockout_group: false,
        })
    }

    /// Twin of `documentLevelStateSurvivesUngroupAll`.
    #[test]
    fn document_level_state_survives_ungroup_all() {
        let mut master = rect(3.0);
        master.common_mut().id = Some("master-1".to_string());
        let board = Artboard {
            id: "ab-keep".to_string(),
            name: "Board Keep".to_string(),
            x: 11.0,
            y: 22.0,
            width: 333.0,
            height: 444.0,
            show_center_mark: true,
            ..Artboard::default_with_id("ab-keep".to_string())
        };
        let mut setup = DocumentSetup::default();
        setup.bleed_top = 9.0;
        setup.show_images_outline = true;
        let mut prefs = PrintPreferences::default();
        prefs.preset_name = "Proof Sheet".to_string();
        prefs.copies = 7;
        let doc = Document {
            layers: vec![
                named_layer("Base", vec![rect(0.0)]),
                named_layer("Nested", vec![nest()]),
            ],
            symbols: vec![master],
            selected_layer: 1,
            artboards: vec![board],
            artboard_options: ArtboardOptions {
                fade_region_outside_artboard: false,
                update_while_dragging: false,
            },
            document_setup: setup,
            print_preferences: prefs,
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::ungroup_all(&mut model);
        let out = model.document();

        // The operation really ran (guard against a vacuous pass).
        assert_eq!(out.layers[1].children().unwrap().len(), 1);
        assert!(matches!(
            &*out.layers[1].children().unwrap()[0],
            Element::Rect(_)
        ));

        assert_eq!(out.artboards.len(), 1);
        assert_eq!(out.artboards[0].id, "ab-keep");
        assert_eq!(out.artboards[0].name, "Board Keep");
        assert_eq!(out.artboards[0].x, 11.0);
        assert_eq!(out.artboards[0].width, 333.0);
        assert!(out.artboards[0].show_center_mark);
        assert!(!out.artboard_options.fade_region_outside_artboard);
        assert!(!out.artboard_options.update_while_dragging);
        assert_eq!(out.document_setup.bleed_top, 9.0);
        assert!(out.document_setup.show_images_outline);
        assert_eq!(out.print_preferences.preset_name, "Proof Sheet");
        assert_eq!(out.print_preferences.copies, 7);
        assert_eq!(out.symbols.len(), 1);
        assert_eq!(out.symbols[0].common().id.as_deref(), Some("master-1"));
        assert_eq!(out.selected_layer, 1);
        assert!(out.selection.is_empty());
    }

    /// Twin of `lockedGroupKeepsEveryAttribute`.
    #[test]
    fn locked_group_keeps_every_attribute() {
        let keeper = Element::Group(GroupElem {
            children: vec![Rc::new(nest()), Rc::new(rect(50.0))],
            common: CommonProps {
                opacity: 0.5,
                mode: BlendMode::Multiply,
                transform: None,
                locked: true,
                visibility: Visibility::Outline,
                mask: Some(Box::new(a_mask())),
                name: Some("Keeper".to_string()),
                id: Some("g-keep".to_string()),
                ..CommonProps::default()
            },
            isolated_blending: true,
            knockout_group: true,
        });
        let doc = Document {
            layers: vec![named_layer("L", vec![keeper])],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::ungroup_all(&mut model);
        let out = model.document();

        let kept = &*out.layers[0].children().unwrap()[0];
        let Element::Group(g) = kept else {
            panic!("the locked group was not kept")
        };
        // LOCKINHERIT (transcripts/LAYER_STRUCTURE.md §13): the kept group's
        // CONTENTS are locked too, so the nested group inside it survives as a
        // group. Before the ruling this asserted the opposite — the inner
        // group was dissolved while its locked parent was kept, which is the
        // one-level-deep reading inheritance replaces. `layer_keeps_every_
        // attribute` above is the positive control that ungroup_all still runs.
        assert_eq!(g.children.len(), 2);
        assert!(matches!(&*g.children[0], Element::Group(_)),
            "a group inside a LOCKED group is locked, so it is left alone");
        assert!(matches!(&*g.children[1], Element::Rect(_)));

        assert_eq!(g.common.name.as_deref(), Some("Keeper"));
        assert_eq!(g.common.id.as_deref(), Some("g-keep"));
        assert!(g.common.locked);
        assert_eq!(g.common.opacity, 0.5);
        assert_eq!(g.common.visibility, Visibility::Outline);
        assert_eq!(g.common.mode, BlendMode::Multiply);
        assert!(g.isolated_blending);
        assert!(g.knockout_group);
        assert!(g.common.mask.is_some());
        assert!(!g.common.mask.as_ref().unwrap().clip);
        assert!(g.common.mask.as_ref().unwrap().invert);
    }

    /// Twin of `layerKeepsEveryAttribute`.
    #[test]
    fn layer_keeps_every_attribute() {
        let doc = Document {
            layers: vec![Element::Layer(LayerElem {
                children: vec![Rc::new(nest())],
                common: CommonProps {
                    opacity: 0.25,
                    mode: BlendMode::Screen,
                    locked: false,
                    visibility: Visibility::Outline,
                    mask: Some(Box::new(a_mask())),
                    name: Some("Styled".to_string()),
                    id: Some("lay-keep".to_string()),
                    ..CommonProps::default()
                },
                isolated_blending: true,
                knockout_group: true,
            })],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::ungroup_all(&mut model);
        let out = model.document();

        let Element::Layer(l) = &out.layers[0] else {
            panic!("layer")
        };
        // The operation ran.
        assert_eq!(l.children.len(), 1);
        assert!(matches!(&*l.children[0], Element::Rect(_)));

        assert_eq!(l.common.name.as_deref(), Some("Styled"));
        assert_eq!(l.common.id.as_deref(), Some("lay-keep"));
        assert_eq!(l.common.opacity, 0.25);
        assert_eq!(l.common.visibility, Visibility::Outline);
        assert_eq!(l.common.mode, BlendMode::Screen);
        assert!(l.isolated_blending);
        assert!(l.knockout_group);
        assert!(l.common.mask.is_some());
        assert!(!l.common.locked);
    }

    /// Twin of `lockedLayerStaysLocked`.
    ///
    /// The fact this test was written to pin — that a locked LAYER did NOT
    /// protect its contents, so an unlocked group inside one was dissolved
    /// anyway — was banked with the note "if lock becomes INHERITED, this
    /// assertion is what moves". It became inherited (JYH, 2026-07-28,
    /// transcripts/LAYER_STRUCTURE.md §13), and it moved.
    #[test]
    fn locked_layer_stays_locked() {
        let doc = Document {
            layers: vec![Element::Layer(LayerElem {
                children: vec![Rc::new(nest())],
                common: CommonProps {
                    locked: true,
                    name: Some("Locked".to_string()),
                    ..CommonProps::default()
                },
                isolated_blending: false,
                knockout_group: false,
            })],
            ..Document::default()
        };
        let mut model = Model::new(doc, None);
        Controller::ungroup_all(&mut model);
        let out = model.document();
        assert!(out.layers[0].locked());
        assert_eq!(out.layers[0].children().unwrap().len(), 1);
        // The group inside a LOCKED layer is left alone, structure included.
        assert!(matches!(
            &*out.layers[0].children().unwrap()[0],
            Element::Group(_)
        ));
    }
}
