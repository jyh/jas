//! Observable model that holds the current document.
//!
//! In the Dioxus version, reactivity is handled by Dioxus signals rather than
//! manual callbacks. The Model still owns undo/redo stacks and filename state.

use super::document::Document;

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
        }
    }
}

impl Model {
    pub fn new(document: Document, filename: Option<String>) -> Self {
        Self {
            saved_document: document.clone(),
            document,
            filename: filename.unwrap_or_else(fresh_filename),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    pub fn document(&self) -> &Document {
        &self.document
    }

    pub fn set_document(&mut self, doc: Document) {
        self.document = doc;
    }

    /// Save the current document state for undo.
    pub fn snapshot(&mut self) {
        self.undo_stack.push(self.document.clone());
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.redo_stack.clear();
    }

    /// Restore the previous document state.
    pub fn undo(&mut self) {
        if let Some(prev) = self.undo_stack.pop() {
            self.redo_stack.push(self.document.clone());
            self.document = prev;
        }
    }

    /// Re-apply a previously undone document state.
    pub fn redo(&mut self) {
        if let Some(next) = self.redo_stack.pop() {
            self.undo_stack.push(self.document.clone());
            self.document = next;
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn is_modified(&self) -> bool {
        // Simple pointer comparison won't work in Rust — compare structurally
        // For performance, we could add a generation counter later
        true // Conservative: always consider modified for now
    }

    pub fn mark_saved(&mut self) {
        self.saved_document = self.document.clone();
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
}
