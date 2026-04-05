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
