//! Observable model that holds the current document.
//!
// Public API surface; can_undo / can_redo / is_modified are wired by
// the editor shell, which isn't fully integrated yet.
#![allow(dead_code)]
//!
//! In the Dioxus version, reactivity is handled by Dioxus signals rather than
//! manual callbacks. The Model still owns undo/redo stacks and filename state.

use super::document::Document;
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
    pub filename: String,
    undo_stack: Vec<Document>,
    redo_stack: Vec<Document>,
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
        Self {
            document: Document::default(),
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
        Self {
            document,
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

    /// Monotonically increasing counter bumped on every document mutation.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Mutably borrow the current document. Bumps the modification
    /// generation so the UI re-renders. Callers that want this change
    /// to be undoable should call [`snapshot`] first.
    pub fn document_mut(&mut self) -> &mut Document {
        self.generation += 1;
        &mut self.document
    }

    /// Replace the current document and bump the modification generation.
    /// Callers that want this change to be undoable should call
    /// [`snapshot`] first; `set_document` itself does not push onto the
    /// undo stack.
    pub fn set_document(&mut self, doc: Document) {
        self.document = doc;
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
            self.document = doc;
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
        self.undo_stack.push(self.document.clone());
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    /// Restore the most recently snapshotted document, moving the current
    /// document onto the redo stack. No-op if the undo stack is empty.
    pub fn undo(&mut self) {
        if let Some(prev) = self.undo_stack.pop() {
            self.redo_stack.push(self.document.clone());
            self.document = prev;
            self.generation += 1;
        }
    }

    /// Re-apply the most recently undone document, moving the current
    /// document back onto the undo stack. No-op if the redo stack is
    /// empty (e.g. after any new edit, which clears redo).
    pub fn redo(&mut self) {
        if let Some(next) = self.redo_stack.pop() {
            self.undo_stack.push(self.document.clone());
            self.document = next;
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
}
