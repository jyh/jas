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

/// Holds an immutable Document with undo/redo support.
#[derive(Debug, Clone)]
pub struct Model {
    document: Document,
    saved_document: Document,
    pub filename: String,
    undo_stack: Vec<Document>,
    redo_stack: Vec<Document>,
    generation: u64,
    saved_generation: u64,
    /// Default fill for newly created elements.
    pub default_fill: Option<Fill>,
    /// Default stroke for newly created elements.
    pub default_stroke: Option<Stroke>,
}

impl Default for Model {
    fn default() -> Self {
        let doc = Document::default();
        Self {
            saved_document: doc.clone(),
            document: doc,
            filename: fresh_filename(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            generation: 0,
            saved_generation: 0,
            default_fill: None,
            default_stroke: Some(Stroke::new(Color::BLACK, 1.0)),
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
            saved_document: document.clone(),
            document,
            filename: filename.unwrap_or_else(fresh_filename),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            generation: 0,
            saved_generation: 0,
            default_fill: None,
            default_stroke: Some(Stroke::new(Color::BLACK, 1.0)),
        }
    }

    /// Borrow the current document. The returned reference is invalidated
    /// by any subsequent mutating call on this model.
    pub fn document(&self) -> &Document {
        &self.document
    }

    /// Replace the current document and bump the modification generation.
    /// Callers that want this change to be undoable should call
    /// [`snapshot`] first; `set_document` itself does not push onto the
    /// undo stack.
    pub fn set_document(&mut self, doc: Document) {
        self.document = doc;
        self.generation += 1;
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
        self.saved_document = self.document.clone();
        self.saved_generation = self.generation;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_layer(name: &str) -> Element {
        Element::Layer(LayerElem {
            name: name.to_string(), children: Vec::new(), common: CommonProps::default(),
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
        let doc = Document { layers: vec![], selected_layer: 0, selection: vec![] };
        model.set_document(doc);
        assert_eq!(model.document().layers.len(), 0);
    }

    #[test]
    fn undo_redo() {
        let mut model = Model::default();
        assert!(!model.can_undo());

        model.snapshot();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![] });
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
        model.set_document(Document { layers: vec![layer.clone()], selected_layer: 0, selection: vec![] });
        model.snapshot();
        model.set_document(Document { layers: vec![layer.clone(), layer.clone()], selected_layer: 0, selection: vec![] });

        model.undo();
        assert_eq!(model.document().layers.len(), 1);
        assert!(model.can_redo());

        model.snapshot();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![] });
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
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![] });
        assert!(model.is_modified());
        model.undo();
        // After undo, generation differs from saved — still modified
        assert!(model.is_modified());
    }
}
