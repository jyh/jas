//! Observable model that holds the current document.
//!
// Public API surface; can_undo / can_redo / is_modified are wired by
// the editor shell, which isn't fully integrated yet.
#![allow(dead_code)]
//!
//! In the Dioxus version, reactivity is handled by Dioxus signals rather than
//! manual callbacks. The Model still owns undo/redo stacks and filename state.

use super::document::Document;
use crate::canvas::render::{incremental_update_index, rebuild_id_index, IdIndex};
use crate::geometry::element::{Color, Fill, Stroke};

const MAX_UNDO: usize = 100;

static NEXT_UNTITLED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

fn fresh_filename() -> String {
    let n = NEXT_UNTITLED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("Untitled-{n}")
}

/// The target that drawing tools operate on. The default is the
/// document's normal content; mask-editing mode switches the target
/// to a specific element's mask subtree so new shapes land inside
/// ``element.mask.subtree`` instead of the selected layer. Mirrors
/// the Swift / OCaml / Python ``EditingTarget`` counterparts.
/// OPACITY.md §Preview interactions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditingTarget {
    Content,
    Mask(Vec<usize>),
}

/// Holds an immutable Document with undo/redo support.
#[derive(Debug, Clone)]
pub struct Model {
    document: Document,
    /// Persistent id->element index paired with `document`
    /// (REFERENCE_GRAPH.md §2.4 Phase 4b). A pure function of `document`
    /// (always equal to `rebuild_id_index(&document)`; checked by a
    /// debug-assert gate), so it is never serialized and never part of
    /// Document equality. Stored here, alongside the snapshot, so paint reads
    /// it without rebuilding and undo carries it in O(1) (rpds structure
    /// sharing). The undo/redo stacks pair each Document with its index for
    /// the same reason.
    id_index: IdIndex,
    pub filename: String,
    undo_stack: Vec<(Document, IdIndex)>,
    redo_stack: Vec<(Document, IdIndex)>,
    generation: u64,
    saved_generation: u64,
    /// Default fill for newly created elements.
    pub default_fill: Option<Fill>,
    /// Default stroke for newly created elements.
    pub default_stroke: Option<Stroke>,
    /// Per-document list of recently committed colors (hex strings, no #),
    /// newest first. Max 10 entries.
    pub recent_colors: Vec<String>,
    /// Mask-editing mode state. ``Content`` is the default; flipped
    /// to ``Mask(path)`` when the user clicks the Opacity panel's
    /// MASK_PREVIEW and the selection has a mask. Drives where
    /// [`Controller::add_element`] places new tool-drawn shapes.
    /// OPACITY.md §Preview interactions.
    pub editing_target: EditingTarget,
    /// Mask-isolation path. When ``Some(path)``, the canvas renders
    /// only the mask subtree of the element at ``path``. Entered by
    /// Alt/Option-clicking MASK_PREVIEW. OPACITY.md §Preview
    /// interactions.
    pub mask_isolation_path: Option<Vec<usize>>,
    /// Out-of-band document snapshot used by dialog Preview flows
    /// (Scale Options, Rotate Options, Shear Options) — captured at
    /// dialog open, restored on Cancel, cleared on OK. Distinct from
    /// `undo_stack` so preview-driven applies don't pollute undo
    /// history. See SCALE_TOOL.md §Preview.
    preview_doc_snapshot: Option<Document>,
    /// Per-document view state (per ZOOM_TOOL.md §State persistence).
    /// Persists across tab switches within a session; reset to
    /// defaults on document open. Not serialized to disk in Phase 1.
    pub zoom_level: f64,
    pub view_offset_x: f64,
    pub view_offset_y: f64,
    /// Canvas viewport dimensions in screen-space pixels. Updated by
    /// the canvas widget on render / resize. Read by doc.zoom.fit_*
    /// effects to compute the new zoom factor that fits a rect into
    /// the visible canvas area. Defaults match the layout.yaml
    /// canvas_pane default_position width/height.
    pub viewport_w: f64,
    pub viewport_h: f64,
}

impl Default for Model {
    fn default() -> Self {
        let document = Document::default();
        let id_index = rebuild_id_index(&document);
        Self {
            document,
            id_index,
            filename: fresh_filename(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            generation: 0,
            saved_generation: 0,
            default_fill: None,
            default_stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            recent_colors: Vec::new(),
            editing_target: EditingTarget::Content,
            mask_isolation_path: None,
            preview_doc_snapshot: None,
            zoom_level: 1.0,
            view_offset_x: 0.0,
            view_offset_y: 0.0,
            viewport_w: 888.0,
            viewport_h: 900.0,
        }
    }
}

impl Model {
    /// Create a new model wrapping `document`. If `filename` is `None`,
    /// allocate a fresh `Untitled-N` placeholder. The provided document
    /// is also recorded as the saved baseline, so [`is_modified`] returns
    /// `false` until something edits it.
    pub fn new(document: Document, filename: Option<String>) -> Self {
        let id_index = rebuild_id_index(&document);
        Self {
            document,
            id_index,
            filename: filename.unwrap_or_else(fresh_filename),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            generation: 0,
            saved_generation: 0,
            default_fill: None,
            default_stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            recent_colors: Vec::new(),
            editing_target: EditingTarget::Content,
            mask_isolation_path: None,
            preview_doc_snapshot: None,
            zoom_level: 1.0,
            view_offset_x: 0.0,
            view_offset_y: 0.0,
            viewport_w: 888.0,
            viewport_h: 900.0,
        }
    }

    /// Center the canvas view on the current artboard using the
    /// stored viewport_w / viewport_h. Per ZOOM_TOOL.md
    /// §Document-open behavior: at zoom_level == 1.0 if the artboard
    /// fits, the artboard's bounding box is centered in the
    /// viewport. Computes pan only — leaves zoom_level alone (the
    /// caller should pre-set it). Used at TabState construction and
    /// the first time the canvas reports its real viewport size.
    pub fn center_view_on_current_artboard(&mut self) {
        let Some(ab) = self.document.artboards.first() else { return; };
        if self.viewport_w <= 0.0 || self.viewport_h <= 0.0 { return; }
        let z = self.zoom_level;
        // Fit-or-center: if artboard fits at current zoom, center
        // it; otherwise apply fit_active_artboard semantics.
        let fits = ab.width * z <= self.viewport_w && ab.height * z <= self.viewport_h;
        if fits {
            self.view_offset_x = self.viewport_w / 2.0 - (ab.x + ab.width / 2.0) * z;
            self.view_offset_y = self.viewport_h / 2.0 - (ab.y + ab.height / 2.0) * z;
        } else {
            // fit-inside with default fit_padding_px (20).
            let pad = 20.0;
            let avail_w = self.viewport_w - 2.0 * pad;
            let avail_h = self.viewport_h - 2.0 * pad;
            if avail_w > 0.0 && avail_h > 0.0 {
                let z_fit = (avail_w / ab.width).min(avail_h / ab.height).clamp(0.1, 64.0);
                self.zoom_level = z_fit;
                self.view_offset_x = self.viewport_w / 2.0
                    - (ab.x + ab.width / 2.0) * z_fit;
                self.view_offset_y = self.viewport_h / 2.0
                    - (ab.y + ab.height / 2.0) * z_fit;
            }
        }
    }

    /// Borrow the current document. The returned reference is invalidated
    /// by any subsequent mutating call on this model.
    pub fn document(&self) -> &Document {
        &self.document
    }

    /// Borrow the persistent id->element index paired with the current
    /// document (REFERENCE_GRAPH.md §2.4). Equal to
    /// `rebuild_id_index(self.document())` at all observable points. The
    /// canvas paint path installs this (an O(1) clone) instead of rebuilding
    /// the index per frame.
    pub fn id_index(&self) -> &IdIndex {
        &self.id_index
    }

    /// Monotonically increasing counter bumped on every document mutation.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Mutably borrow the current document. Bumps the modification
    /// generation so the UI re-renders. Callers that want this change
    /// to be undoable should call [`snapshot`] first.
    ///
    /// Returns a [`DocumentMutGuard`] that derefs to `&mut Document`, so
    /// existing callers (`let doc = model.document_mut(); doc.foo()`) are
    /// unchanged. When the guard is dropped (the `&mut` borrow ends) the
    /// paired id->element index is rebuilt, keeping it consistent with the
    /// edit the Model could not otherwise observe (REFERENCE_GRAPH.md §2.4).
    pub fn document_mut(&mut self) -> DocumentMutGuard<'_> {
        self.generation += 1;
        // Snapshot the document as it is BEFORE the in-place edit; the guard's
        // Drop diffs this against the mutated document to update the index
        // incrementally. Cloning a Document is cheap — its layer/symbol
        // subtrees are `Rc`-held, so the clone shares structure (O(top-level)).
        let old_doc = self.document.clone();
        DocumentMutGuard { model: self, old_doc }
    }

    /// Replace the current document, update the paired id->element index
    /// incrementally (O(changed)), and bump the modification generation.
    /// Callers that want this change to be undoable should call [`snapshot`]
    /// first; `set_document` itself does not push onto the undo stack.
    pub fn set_document(&mut self, doc: Document) {
        // Incrementally bring the index from the OLD document to the new one
        // (O(changed) via CoW `Rc::ptr_eq` diffing), instead of a full rebuild.
        // Capture the old document before overwriting it.
        self.id_index = incremental_update_index(
            std::mem::take(&mut self.id_index),
            &self.document, // old
            &doc,           // new
        );
        self.document = doc;
        debug_assert!(
            self.id_index == rebuild_id_index(&self.document),
            "id index diverged from rebuild after set_document",
        );
        self.generation += 1;
    }

    /// Capture the current document into the preview snapshot slot,
    /// independently of the undo stack. Used by dialog Preview flows
    /// (Scale / Rotate / Shear) to enable apply-on-change without
    /// polluting undo history. Idempotent — overwrites any prior
    /// preview snapshot.
    pub fn capture_preview_snapshot(&mut self) {
        self.preview_doc_snapshot = Some(self.document.clone());
    }

    /// Restore the preview snapshot if present. The captured document
    /// replaces the current one (no undo entry is pushed); the snapshot
    /// is left in place so subsequent restore calls remain idempotent.
    /// No-op when no snapshot is captured.
    pub fn restore_preview_snapshot(&mut self) {
        if let Some(doc) = self.preview_doc_snapshot.clone() {
            // Incremental update from the current document to the restored
            // snapshot (same O(changed) diff as `set_document`); capture the
            // old document before overwriting.
            self.id_index = incremental_update_index(
                std::mem::take(&mut self.id_index),
                &self.document, // old (current)
                &doc,           // new (restored snapshot)
            );
            self.document = doc;
            debug_assert!(
                self.id_index == rebuild_id_index(&self.document),
                "id index diverged from rebuild after restore_preview_snapshot",
            );
            self.generation += 1;
        }
    }

    /// Drop the preview snapshot without restoring. OK actions call
    /// this so subsequent close_dialog flows do not revert.
    pub fn clear_preview_snapshot(&mut self) {
        self.preview_doc_snapshot = None;
    }

    /// True iff a preview snapshot is currently captured.
    pub fn has_preview_snapshot(&self) -> bool {
        self.preview_doc_snapshot.is_some()
    }

    /// Push the current document onto the undo stack and clear the redo
    /// stack. Tools should call this exactly once per user-visible action,
    /// before mutating the document. The undo stack is capped at
    /// `MAX_UNDO` entries; older snapshots are silently dropped.
    pub fn snapshot(&mut self) {
        // Pair the index with the document on the stack so undo/redo restore
        // it in O(1) without a rebuild (rpds clone is O(1) structure sharing).
        self.undo_stack.push((self.document.clone(), self.id_index.clone()));
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    /// Restore the most recently snapshotted document, moving the current
    /// document onto the redo stack. No-op if the undo stack is empty.
    pub fn undo(&mut self) {
        if let Some((prev_doc, prev_index)) = self.undo_stack.pop() {
            self.redo_stack.push((self.document.clone(), self.id_index.clone()));
            self.document = prev_doc;
            self.id_index = prev_index;
            debug_assert!(
                self.id_index == rebuild_id_index(&self.document),
                "id index diverged from rebuild after undo",
            );
            self.generation += 1;
        }
    }

    /// Re-apply the most recently undone document, moving the current
    /// document back onto the undo stack. No-op if the redo stack is
    /// empty (e.g. after any new edit, which clears redo).
    pub fn redo(&mut self) {
        if let Some((next_doc, next_index)) = self.redo_stack.pop() {
            self.undo_stack.push((self.document.clone(), self.id_index.clone()));
            self.document = next_doc;
            self.id_index = next_index;
            debug_assert!(
                self.id_index == rebuild_id_index(&self.document),
                "id index diverged from rebuild after redo",
            );
            self.generation += 1;
        }
    }

    /// True if there is at least one snapshot available to [`undo`].
    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    /// True if there is at least one undone snapshot available to [`redo`].
    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// True if the document has been mutated since the last [`mark_saved`]
    /// call (or since model construction, whichever is later). Compares
    /// generations rather than document contents, so an undo back to the
    /// saved state still reads as modified.
    pub fn is_modified(&self) -> bool {
        self.generation != self.saved_generation
    }

    /// Snapshot the current document as the on-disk baseline, after
    /// which [`is_modified`] will return `false` until the next edit.
    /// Call this after a successful save.
    pub fn mark_saved(&mut self) {
        self.saved_generation = self.generation;
    }
}

/// Drop-guard returned by [`Model::document_mut`]. Derefs to the underlying
/// `Document` so callers use it exactly like the old `&mut Document`; when it
/// drops (the borrow ends) it updates the Model's paired id->element index
/// incrementally, because the Model cannot otherwise observe edits made through
/// the raw `&mut Document` (REFERENCE_GRAPH.md §2.4). The guard captures the
/// pre-edit document (`old_doc`) at creation and diffs it against the mutated
/// document on Drop ([`incremental_update_index`], O(changed) via CoW
/// `Rc::ptr_eq`). The debug-assert gate confirms the result equals a
/// from-scratch rebuild.
pub struct DocumentMutGuard<'a> {
    model: &'a mut Model,
    /// The document as it was when the guard was created, used as the diff
    /// baseline on Drop.
    old_doc: Document,
}

impl std::ops::Deref for DocumentMutGuard<'_> {
    type Target = Document;
    fn deref(&self) -> &Document {
        &self.model.document
    }
}

impl std::ops::DerefMut for DocumentMutGuard<'_> {
    fn deref_mut(&mut self) -> &mut Document {
        &mut self.model.document
    }
}

impl Drop for DocumentMutGuard<'_> {
    fn drop(&mut self) {
        self.model.id_index = incremental_update_index(
            std::mem::take(&mut self.model.id_index),
            &self.old_doc,         // old (pre-edit baseline)
            &self.model.document,  // new (mutated in place)
        );
        debug_assert!(
            self.model.id_index == rebuild_id_index(&self.model.document),
            "id index diverged from rebuild after document_mut drop",
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_layer(name: &str) -> Element {
        Element::Layer(LayerElem {
            children: Vec::new(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps {
                name: Some(name.to_string()),
                ..Default::default()
            },
        })
    }

    #[test]
    fn default_model_has_untitled_filename() {
        let model = Model::default();
        assert!(model.filename.starts_with("Untitled-"));
    }

    #[test]
    fn default_model_has_one_layer() {
        let model = Model::default();
        assert_eq!(model.document().layers.len(), 1);
    }

    #[test]
    fn new_model_with_filename() {
        let model = Model::new(Document::default(), Some("test.svg".to_string()));
        assert_eq!(model.filename, "test.svg");
    }

    #[test]
    fn set_document() {
        let mut model = Model::default();
        let doc = Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() };
        model.set_document(doc);
        assert_eq!(model.document().layers.len(), 0);
    }

    #[test]
    fn undo_redo() {
        let mut model = Model::default();
        assert!(!model.can_undo());

        model.snapshot();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        assert!(model.can_undo());
        assert!(!model.can_redo());

        model.undo();
        assert_eq!(model.document().layers.len(), 1);
        assert!(model.can_redo());

        model.redo();
        assert_eq!(model.document().layers.len(), 0);
    }

    #[test]
    fn undo_clears_redo_on_new_edit() {
        let mut model = Model::default();
        let layer = make_layer("L1");

        model.snapshot();
        model.set_document(Document { layers: vec![layer.clone()], selected_layer: 0, selection: vec![], ..Document::default() });
        model.snapshot();
        model.set_document(Document { layers: vec![layer.clone(), layer.clone()], selected_layer: 0, selection: vec![], ..Document::default() });

        model.undo();
        assert_eq!(model.document().layers.len(), 1);
        assert!(model.can_redo());

        model.snapshot();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        assert!(!model.can_redo());
    }

    #[test]
    fn undo_empty_stack_is_noop() {
        let mut model = Model::default();
        model.undo();
        assert_eq!(model.document().layers.len(), 1);
    }

    #[test]
    fn redo_empty_stack_is_noop() {
        let mut model = Model::default();
        model.redo();
        assert_eq!(model.document().layers.len(), 1);
    }

    #[test]
    fn undo_stack_capped_at_100() {
        let mut model = Model::default();
        for _ in 0..150 {
            model.snapshot();
        }
        // Internal: undo_stack should not exceed 100
        assert!(model.undo_stack.len() <= 100);
    }

    #[test]
    fn is_modified_default_false() {
        let model = Model::default();
        assert!(!model.is_modified());
    }

    #[test]
    fn is_modified_after_set_document() {
        let mut model = Model::default();
        model.set_document(Document::default());
        assert!(model.is_modified());
    }

    #[test]
    fn is_modified_false_after_mark_saved() {
        let mut model = Model::default();
        model.set_document(Document::default());
        assert!(model.is_modified());
        model.mark_saved();
        assert!(!model.is_modified());
    }

    #[test]
    fn is_modified_after_undo() {
        let mut model = Model::default();
        model.mark_saved();
        model.snapshot();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        assert!(model.is_modified());
        model.undo();
        // After undo, generation differs from saved — still modified
        assert!(model.is_modified());
    }

    #[test]
    fn center_view_on_artboard_centers_letter_in_default_viewport() {
        // Default Letter artboard is 612x792 at (0, 0). Default
        // viewport is 888x900. At zoom 1.0 the artboard fits
        // (612 ≤ 888, 792 ≤ 900). Pan should center it:
        //   offset_x = 444 - 306 = 138
        //   offset_y = 450 - 396 = 54
        let mut model = Model::default();
        model.center_view_on_current_artboard();
        assert_eq!(model.zoom_level, 1.0);
        assert_eq!(model.view_offset_x, 138.0);
        assert_eq!(model.view_offset_y, 54.0);
    }

    #[test]
    fn center_view_on_artboard_fits_when_too_large() {
        // Artificially shrink viewport so the default Letter
        // artboard doesn't fit at 1.0. Should fall through to
        // fit_active_artboard semantics.
        let mut model = Model::default();
        model.viewport_w = 400.0;
        model.viewport_h = 400.0;
        model.center_view_on_current_artboard();
        // zoom is fit-inside with 20px padding:
        // avail = 360, zoom = min(360/612, 360/792) = 0.4545...
        assert!(model.zoom_level < 1.0);
        assert!((model.zoom_level - 360.0/792.0).abs() < 1e-9);
    }

    #[test]
    fn center_view_on_artboard_skips_with_zero_viewport() {
        let mut model = Model::default();
        model.viewport_w = 0.0;
        model.viewport_h = 0.0;
        model.zoom_level = 2.0;
        model.view_offset_x = 100.0;
        model.view_offset_y = 50.0;
        model.center_view_on_current_artboard();
        // No-op: pre-existing values preserved.
        assert_eq!(model.zoom_level, 2.0);
        assert_eq!(model.view_offset_x, 100.0);
        assert_eq!(model.view_offset_y, 50.0);
    }

    // ── Phase 4b: id->element index companion ───────────────────────────

    fn id_rect(id: &str) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some(id.to_string()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        })
    }

    #[test]
    fn id_index_paired_with_document_at_construction() {
        // Default + new() build the index up front so paint can read it.
        let model = Model::default();
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        let model2 = Model::new(Document::default(), None);
        assert_eq!(model2.id_index(), &rebuild_id_index(model2.document()));
    }

    #[test]
    fn id_index_tracks_set_document_and_document_mut() {
        let mut model = Model::default();
        // set_document refreshes the index.
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("a")));
        model.set_document(doc);
        assert!(model.id_index().get("a").is_some());
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // The document_mut drop-guard rebuilds the index when the borrow ends.
        {
            let mut d = model.document_mut();
            d.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("b")));
        }
        assert!(model.id_index().get("b").is_some());
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
    }

    #[test]
    fn id_index_matches_rebuild_after_controller_edits_and_undo_and_resolves() {
        use crate::document::controller::Controller;
        use crate::geometry::live::{
            ElementResolver, ElementRef, ReferenceElem, VisitSet, DEFAULT_PRECISION,
        };

        // A resolver that reads the Model's persistent index, so the test
        // exercises the same map paint installs (not a fresh rebuild).
        struct ModelResolver<'a>(&'a IdIndex);
        impl ElementResolver for ModelResolver<'_> {
            fn resolve(&self, id: &ElementRef) -> Option<std::rc::Rc<Element>> {
                self.0.get(&id.0).cloned()
            }
        }

        let mut model = Model::default();

        // Edit 1: add an id-bearing rect "r1" (undoable).
        model.snapshot();
        Controller::add_element(&mut model, id_rect("r1"));
        // Edit 2: add a second id-bearing rect "r2" (undoable).
        model.snapshot();
        Controller::add_element(&mut model, id_rect("r2"));
        // Both ids present, index consistent with the document.
        assert!(model.id_index().get("r1").is_some());
        assert!(model.id_index().get("r2").is_some());
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // Undo edit 2: the carried (paired) index must equal a from-scratch
        // rebuild of the restored document — this is the gate, asserted
        // explicitly (it also fires as a debug_assert inside undo()).
        model.undo();
        assert_eq!(
            model.id_index(), &rebuild_id_index(model.document()),
            "after undo the carried index equals rebuild(document)",
        );
        assert!(model.id_index().get("r1").is_some(), "r1 survives the undo");
        assert!(model.id_index().get("r2").is_none(), "r2 removed by undo");

        // The index resolves a live reference to the surviving target.
        let resolver = ModelResolver(model.id_index());
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = reference.evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting);
        assert_eq!(ps.len(), 1, "reference to r1 resolves to its single ring");

        // Redo edit 2: index again carries r2 and matches rebuild.
        model.redo();
        assert!(model.id_index().get("r2").is_some(), "redo restores r2");
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
    }

    // ── Phase 4b: incremental index maintenance wiring ──────────────────
    //
    // The Model now maintains `id_index` incrementally (O(changed)) at the
    // set_document / document_mut chokepoints instead of full rebuilds. Each
    // test asserts `id_index() == rebuild_id_index(document())` explicitly
    // after the edit (beyond the always-on debug_assert gate) and that an
    // affected reference still resolves.

    // Resolver reading the Model's persistent index, shared by the tests.
    struct IxResolver<'a>(&'a IdIndex);
    impl crate::geometry::live::ElementResolver for IxResolver<'_> {
        fn resolve(
            &self,
            id: &crate::geometry::live::ElementRef,
        ) -> Option<std::rc::Rc<Element>> {
            self.0.get(&id.0).cloned()
        }
    }

    fn resolves(model: &Model, id: &str) -> bool {
        use crate::geometry::live::{
            ReferenceElem, ElementRef, VisitSet, DEFAULT_PRECISION,
        };
        let resolver = IxResolver(model.id_index());
        let reference = ReferenceElem::new(ElementRef(id.into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        !reference
            .evaluate_with(DEFAULT_PRECISION, &resolver, &mut visiting)
            .is_empty()
    }

    #[test]
    fn incremental_set_document_leaf_insert_matches_rebuild() {
        let mut model = Model::default();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("ins")));
        model.set_document(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "ins"), "inserted target resolves");
    }

    #[test]
    fn incremental_document_mut_guard_matches_rebuild() {
        let mut model = Model::default();
        {
            let mut d = model.document_mut();
            d.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("gm")));
        }
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "gm"));
        // A second in-place edit (delete) through the guard also stays consistent.
        {
            let mut d = model.document_mut();
            d.layers[0].children_mut().unwrap().clear();
        }
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(!resolves(&model, "gm"), "deleted target no longer resolves");
    }

    #[test]
    fn incremental_subtree_replace_matches_rebuild() {
        let mut model = Model::default();
        // Seed a group with two ided descendants.
        let mut doc = model.document().clone();
        let g = Element::Group(GroupElem {
            children: vec![
                std::rc::Rc::new(id_rect("a")),
                std::rc::Rc::new(id_rect("b")),
            ],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some("g".into()), ..Default::default() },
        });
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(g));
        model.set_document(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // Replace the group wholesale via a CoW edit.
        let mut doc2 = model.document().clone();
        let g2 = Element::Group(GroupElem {
            children: vec![std::rc::Rc::new(id_rect("c"))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some("g2".into()), ..Default::default() },
        });
        doc2.layers[0].children_mut().unwrap()[0] = std::rc::Rc::new(g2);
        model.set_document(doc2);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "c"));
        assert!(!resolves(&model, "a") && !resolves(&model, "b"), "old subtree gone");
    }

    #[test]
    fn incremental_delete_selection_multi_matches_rebuild() {
        use crate::document::document::ElementSelection;
        let mut model = Model::default();
        let mut doc = model.document().clone();
        for id in ["d1", "d2", "d3"] {
            doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect(id)));
        }
        model.set_document(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // Select d1 and d3 (paths [0,0] and [0,2]) and delete them together.
        let mut doc2 = model.document().clone();
        doc2.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ];
        let after = doc2.delete_selection();
        model.set_document(after);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(!resolves(&model, "d1") && !resolves(&model, "d3"), "both deleted");
        assert!(resolves(&model, "d2"), "untouched sibling survives");
    }

    #[test]
    fn incremental_make_and_delete_symbol_matches_rebuild() {
        use crate::document::controller::Controller;
        let mut model = Model::default();
        // Place an ided rect, then promote it to a master.
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("sym")));
        model.set_document(doc);

        Controller::make_symbol(&mut model, &vec![0, 0], "sym", "inst1");
        assert_eq!(
            model.id_index(), &rebuild_id_index(model.document()),
            "make_symbol leaves index consistent",
        );
        assert!(resolves(&model, "sym"), "master resolves from doc.symbols");

        Controller::delete_symbol(&mut model, "sym");
        assert_eq!(
            model.id_index(), &rebuild_id_index(model.document()),
            "delete_symbol leaves index consistent",
        );
        assert!(!resolves(&model, "sym"), "deleted master no longer resolves");
    }

    #[test]
    fn incremental_undo_redo_matches_rebuild_and_resolves() {
        let mut model = Model::default();
        model.snapshot();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("u1")));
        model.set_document(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "u1"));

        model.undo();
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(!resolves(&model, "u1"), "undo removes the target");

        model.redo();
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "u1"), "redo restores the target");
    }

    #[test]
    fn incremental_restore_preview_snapshot_matches_rebuild() {
        let mut model = Model::default();
        // Capture a baseline, edit, then restore the snapshot.
        model.capture_preview_snapshot();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("pv")));
        model.set_document(doc);
        assert!(resolves(&model, "pv"));

        model.restore_preview_snapshot();
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(!resolves(&model, "pv"), "preview edit reverted");
    }
}
