// Document model with undo/redo — JS port skeleton.
//
// Mirrors `jas/document/model.py`, `jas_dioxus/src/document/model.rs`,
// `JasSwift/Sources/Document/Model.swift`, `jas_ocaml/lib/document/model.ml`.
// Shape matches the Rust post-saved_document cleanup we shipped on
// codebase-review-tier1: only a `generation` / `saved_generation`
// counter for the modified indicator — no saved-document clone.
//
// Mutations outside this class are plain functions returning new
// Documents (see `document.mjs`). The Model wraps those results with
// snapshot/undo/redo bookkeeping and a monotonic generation counter
// that drives UI re-render.

import { emptyDocument, cloneDocument } from "./document.mjs";

const MAX_UNDO = 100;

export class Model {
  constructor(document = null, filename = null) {
    this._document = document || emptyDocument();
    this._filename = filename || freshUntitled();
    this._undoStack = [];
    this._redoStack = [];
    this._generation = 0;
    // OP_LOG.md Increment 2: the journal-head cursor drives isModified. An
    // uncapped count of undoable edits applied (snapshot increments it,
    // undo/redo move it), so isModified is journalHead !== savedJournalHead —
    // undo back to the saved point reads as not-modified. `generation` is kept
    // separately, as the monotonic counter that drives UI re-render. Cursor-only
    // port: tied to the existing snapshot/undo/redo mechanism.
    this._journalHead = 0;
    this._savedJournalHead = 0;
    this._listeners = [];
  }

  /** Immutable read of the current document. */
  get document() { return this._document; }

  /** User-visible filename (no path). */
  get filename() { return this._filename; }
  set filename(name) { this._filename = name; }

  /** Monotonically increasing counter bumped on every mutation. */
  get generation() { return this._generation; }

  /** Selection-reads are common enough to get a convenience getter. */
  get selection() { return this._document.selection; }

  /**
   * Replace the document. Bumps generation; triggers any listeners.
   * Callers that want the change to be undoable must call snapshot()
   * first — set_document itself does not push onto the undo stack.
   */
  setDocument(doc) {
    this._document = doc;
    this._generation += 1;
    this._notify();
  }

  /**
   * Apply a pure mutation to the current document, returning the new
   * document and bumping generation. `fn(doc) -> newDoc`.
   */
  mutate(fn) {
    this._document = fn(this._document);
    this._generation += 1;
    this._notify();
  }

  /**
   * Push the current document onto the undo stack and clear redo.
   * Tools should call this exactly once per user-visible action,
   * BEFORE mutating. The undo stack is capped at MAX_UNDO; older
   * snapshots are silently dropped.
   */
  snapshot() {
    this._undoStack.push(cloneDocument(this._document));
    if (this._undoStack.length > MAX_UNDO) {
      this._undoStack.shift();
    }
    this._redoStack.length = 0;
    // Advance the journal cursor: one undoable edit (OP_LOG.md §5). Uncapped,
    // unlike the MAX_UNDO-capped stack, so isModified stays correct past the cap.
    this._journalHead += 1;
  }

  /**
   * Restore the most recent snapshot. No-op on empty undo stack.
   * Moves the current document onto the redo stack first.
   */
  undo() {
    if (this._undoStack.length === 0) return;
    this._redoStack.push(cloneDocument(this._document));
    this._document = this._undoStack.pop();
    this._generation += 1;
    if (this._journalHead > 0) this._journalHead -= 1;
    this._notify();
  }

  /**
   * Re-apply the most recently undone snapshot. No-op on empty redo
   * stack (cleared whenever a new edit lands).
   */
  redo() {
    if (this._redoStack.length === 0) return;
    this._undoStack.push(cloneDocument(this._document));
    this._document = this._redoStack.pop();
    this._generation += 1;
    this._journalHead += 1;
    this._notify();
  }

  get canUndo() { return this._undoStack.length > 0; }
  get canRedo() { return this._redoStack.length > 0; }

  /**
   * True if the document has unsaved committed edits. OP_LOG.md §9 unified
   * semantics: the journal-head cursor (journalHead !== savedJournalHead), so
   * undo back to the saved point reads as not-modified (and a non-undoable
   * write that does not snapshot does not mark the document modified). Matches
   * the native apps' Increment-2 cursor.
   */
  get isModified() {
    return this._journalHead !== this._savedJournalHead;
  }

  /**
   * Record the current journal cursor as the on-disk baseline. Call after a
   * successful save so `isModified` flips back to false.
   */
  markSaved() {
    this._savedJournalHead = this._journalHead;
  }

  /** Register a listener invoked with (model) on every change. */
  addListener(fn) {
    this._listeners.push(fn);
    return () => {
      const i = this._listeners.indexOf(fn);
      if (i >= 0) this._listeners.splice(i, 1);
    };
  }

  _notify() {
    for (const fn of this._listeners) fn(this);
  }
}

// Fresh "Untitled-N" counter so multiple unnamed models don't collide.
let _untitledCounter = 0;
function freshUntitled() {
  _untitledCounter += 1;
  return `Untitled-${_untitledCounter}`;
}
