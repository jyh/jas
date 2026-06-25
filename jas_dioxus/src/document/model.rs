//! Observable model that holds the current document.
//!
// Public API surface; can_undo / can_redo / is_modified are wired by
// the editor shell, which isn't fully integrated yet.
#![allow(dead_code)]
//!
//! In the Dioxus version, reactivity is handled by Dioxus signals rather than
//! manual callbacks. The Model still owns undo/redo stacks and filename state.

use super::document::Document;
// Phase 4b: the persistent id->element index + its builders live in the CORE
// `document::id_index` module (not the web-gated `canvas::render`), so the
// Model — which is core — compiles under `--no-default-features` and the
// web-decoupled cross-language harness driver builds again.
use crate::document::id_index::{incremental_update_index, rebuild_id_index, IdIndex};
// OP_LOG.md Increment 2: the typed Transaction journal layered on the snapshot
// stacks. `document_to_test_json` (core, not test-gated) gives the canonical
// "net document change is byte-identical" comparison for the commit no-op rule.
use crate::document::op_log::{PrimitiveOp, Transaction};
use crate::geometry::element::{Color, Fill, Stroke};
use crate::geometry::test_json::document_to_test_json;

const MAX_UNDO: usize = 100;

static NEXT_UNTITLED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

fn fresh_filename() -> String {
    let n = NEXT_UNTITLED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("Untitled-{n}")
}

/// Highest `N` among `Untitled-N` names in `existing` (0 if none). Pure —
/// the unit-testable core of [`advance_next_untitled_past`].
fn max_untitled_n(existing: &[String]) -> usize {
    existing
        .iter()
        .filter_map(|f| f.strip_prefix("Untitled-").and_then(|s| s.parse::<usize>().ok()))
        .max()
        .unwrap_or(0)
}

/// Bump the `Untitled-N` counter past any names already in use (e.g. from
/// session restore) so the next [`fresh_filename`] cannot collide. Without
/// this, restoring a session that contains `Untitled-1` and then doing
/// File > New produces a second `Untitled-1` tab. Mirrors OCaml
/// `Model.advance_next_untitled_past` and the Python equivalent. Only ever
/// moves the counter forward.
pub(crate) fn advance_next_untitled_past(existing: &[String]) {
    NEXT_UNTITLED.fetch_max(
        max_untitled_n(existing) + 1,
        std::sync::atomic::Ordering::Relaxed,
    );
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

/// The transaction being accumulated between `begin_txn` and `commit_txn`
/// (OP_LOG.md Increment 2). `name`/`ops` are populated by the `op_apply` path
/// (sub-step 2.2); `gen_at_open` snapshots the generation at the owning
/// `begin_txn` so `commit_txn` can detect a zero-write transaction without
/// serializing.
#[derive(Debug, Clone)]
struct PendingTxn {
    name: Option<String>,
    ops: Vec<crate::document::op_log::PrimitiveOp>,
    gen_at_open: u64,
}

/// A named version point (OP_LOG.md Increment 3a / `VISION.md` §6.9). Stores the
/// document + paired index at a labeled journal cursor position so
/// `restore_version` is O(1) and sound regardless of whether the intervening
/// transactions carry replayable ops.
#[derive(Debug, Clone)]
pub struct Version {
    pub label: String,
    pub journal_head: usize,
    pub document: Document,
    pub id_index: IdIndex,
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
    /// True while an undoable transaction is open (between `begin_txn` and
    /// `commit_txn`). OP_LOG.md Increment 1 consolidates every undoable mutation
    /// through this one bracket; `set_document` debug-asserts it so no undoable
    /// edit bypasses the bracket.
    in_txn: bool,
    // --- OP_LOG.md Increment 2: the typed Transaction journal -------------
    /// The ordered Transaction journal, layered on top of the snapshot stacks
    /// (which remain the O(1) undo/redo mechanism — OP_LOG.md §4). The journal
    /// is the legible / replayable / mergeable artifact.
    op_journal: Vec<Transaction>,
    /// Cursor into `op_journal` — the count of transactions currently applied
    /// (0..=op_journal.len()). NOT a high-water mark: `commit_txn` truncates the
    /// journal here and appends (a new edit after undo drops the redo tail);
    /// `undo` decrements it, `redo` increments it. Kept in lock-step with the
    /// undo-stack depth (modulo the MAX_UNDO cap on the snapshot stack).
    journal_head: usize,
    /// The `journal_head` captured at the last save; `is_modified` is exactly
    /// `journal_head != saved_journal_head`, so undo back to the saved point
    /// reads as not-modified (OP_LOG.md §5/§9).
    saved_journal_head: usize,
    /// The transaction being accumulated between `begin_txn` and `commit_txn`.
    /// `gen_at_open` lets `commit_txn` cheaply detect a zero-write (no-op)
    /// transaction without serializing.
    pending_txn: Option<PendingTxn>,
    /// Deterministic txn-id counter: `txn-0`, `txn-1`, … (OP_LOG.md §7), the same
    /// discipline `element_ids.json` uses for element ids, so the journal file is
    /// byte-shareable across apps.
    next_txn_counter: u64,
    /// OP_LOG.md Increment 3a: named version points (`VISION.md` §6.9). Each
    /// labels a journal cursor position and stores the document + paired index
    /// at that point, so `restore_version` is O(1) and sound even though
    /// production transactions are opaque (no op replay needed). The label is
    /// also written onto the journal's transaction at that head (the `label`
    /// field reserved in Increment 2) so it serializes into the journal artifact.
    versions: Vec<Version>,
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
            in_txn: false,
            op_journal: Vec::new(),
            journal_head: 0,
            saved_journal_head: 0,
            pending_txn: None,
            next_txn_counter: 0,
            versions: Vec::new(),
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
            in_txn: false,
            op_journal: Vec::new(),
            journal_head: 0,
            saved_journal_head: 0,
            pending_txn: None,
            next_txn_counter: 0,
            versions: Vec::new(),
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

    /// True while an undoable transaction is open. Lets a reentrant effect
    /// runner decide whether IT opened the transaction (and so should commit
    /// it) versus running nested inside an already-open one (OP_LOG.md
    /// Increment 1, sub-step 5).
    pub fn in_txn(&self) -> bool {
        self.in_txn
    }

    /// Replace the current document, update the paired id->element index
    /// incrementally (O(changed)), and bump the modification generation.
    /// Callers that want this change to be undoable should open a transaction
    /// ([`begin_txn`]/[`commit_txn`] or [`with_txn`]) first; `set_document`
    /// itself does not push onto the undo stack.
    ///
    /// This is the committing write for UNDOABLE mutations. The
    /// `debug_assert!(self.in_txn)` below is LIVE (OP_LOG.md Increment 1, enforced
    /// chokepoint): any undoable edit that skipped the transaction bracket fails
    /// the test suite, so the journal is complete by construction. Sanctioned
    /// non-undoable writes use [`set_document_unbracketed`] instead, which never
    /// asserts; self-bracketing mutators use [`edit_document`].
    pub fn set_document(&mut self, doc: Document) {
        debug_assert!(
            self.in_txn,
            "set_document outside a transaction: undoable edits use begin_txn/\
             commit_txn or with_txn; Controller mutators use edit_document; \
             non-undoable writes (selection, preview, live-drag, test setup) use \
             set_document_unbracketed.",
        );
        self.write_document(doc);
    }

    /// Self-bracketing undoable write: if no transaction is open, wrap this edit
    /// in its own begin/commit (one undo step); if one is already open, just
    /// write (joining the caller's transaction). This is what `Controller`
    /// mutators use, so a standalone call (e.g. a unit test, or a direct
    /// Controller call) is a complete one-step undo, while the same method
    /// called inside a UI `with_txn`/`begin_txn` joins that action — production
    /// behavior is unchanged, and no test needs an explicit bracket. Distinct
    /// from `set_document` (which asserts a transaction is already open, for the
    /// direct UI write paths) and `set_document_unbracketed` (non-undoable).
    pub fn edit_document(&mut self, doc: Document) {
        let opened = !self.in_txn;
        if opened {
            self.begin_txn();
        }
        self.write_document(doc);
        if opened {
            self.commit_txn();
        }
    }

    /// Committing write for sanctioned NON-undoable mutations — selection-only
    /// and pure view-state changes, dialog-preview re-apply, and live drag
    /// (OP_LOG.md §7/§8). Same effect as [`set_document`] but the distinct name
    /// is what lets the live `in_txn` guard in [`set_document`] tell "deliberately
    /// not undoable" from "forgot to open a transaction": this path never asserts.
    /// ~53 call sites route the non-undoable writes here.
    pub fn set_document_unbracketed(&mut self, doc: Document) {
        self.write_document(doc);
    }

    /// The single committing write to `self.document`: incrementally update the
    /// paired index (O(changed)), overwrite, gate `id_index == rebuild`, bump the
    /// generation. Both [`set_document`] and [`set_document_unbracketed`] funnel
    /// here so there is exactly one place document content is committed.
    fn write_document(&mut self, doc: Document) {
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
        // History navigation ends any open edit context, so the next edit
        // self-brackets fresh (OP_LOG.md Increment 1: keeps in_txn honest after
        // undo, so a post-undo edit clears redo via its own commit).
        self.in_txn = false;
        self.pending_txn = None;
        if let Some((prev_doc, prev_index)) = self.undo_stack.pop() {
            self.redo_stack.push((self.document.clone(), self.id_index.clone()));
            self.document = prev_doc;
            self.id_index = prev_index;
            debug_assert!(
                self.id_index == rebuild_id_index(&self.document),
                "id index diverged from rebuild after undo",
            );
            self.generation += 1;
            // Move the journal cursor back one transaction (OP_LOG.md §5). Only
            // when a checkpoint was actually popped, so a no-op undo at the
            // stack floor does not desync the cursor.
            if self.journal_head > 0 {
                self.journal_head -= 1;
            }
        }
    }

    /// Re-apply the most recently undone document, moving the current
    /// document back onto the undo stack. No-op if the redo stack is
    /// empty (e.g. after any new edit, which clears redo).
    pub fn redo(&mut self) {
        self.in_txn = false;
        self.pending_txn = None;
        if let Some((next_doc, next_index)) = self.redo_stack.pop() {
            self.undo_stack.push((self.document.clone(), self.id_index.clone()));
            self.document = next_doc;
            self.id_index = next_index;
            debug_assert!(
                self.id_index == rebuild_id_index(&self.document),
                "id index diverged from rebuild after redo",
            );
            self.generation += 1;
            // Advance the journal cursor one transaction (OP_LOG.md §5), bounded
            // by the journal length so a no-op redo cannot overrun.
            if self.journal_head < self.op_journal.len() {
                self.journal_head += 1;
            }
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

    /// True if the document has unsaved committed edits. The unified
    /// OP_LOG.md §5/§9 semantics: `journal_head != saved_journal_head`, the
    /// journal **cursor** rather than a monotonic counter — so an undo back to
    /// the saved point reads as not-modified, and a non-undoable write
    /// (selection / preview / live-drag, via `set_document_unbracketed`) does
    /// not mark the document modified (it moves no transaction).
    pub fn is_modified(&self) -> bool {
        self.journal_head != self.saved_journal_head
    }

    /// Record the current journal cursor as the on-disk baseline, after which
    /// [`is_modified`] returns `false` until the next committed edit (or until
    /// undo/redo move the cursor off this point). Call after a successful save.
    pub fn mark_saved(&mut self) {
        self.saved_journal_head = self.journal_head;
    }

    /// The journal cursor — the number of transactions currently applied
    /// (0..=journal length). Test/inspection accessor.
    pub fn journal_head(&self) -> usize {
        self.journal_head
    }

    /// The Transaction journal (OP_LOG.md §5). Test/inspection accessor.
    pub fn journal(&self) -> &[Transaction] {
        &self.op_journal
    }

    /// Append a primitive op to the open transaction's record (OP_LOG.md §5):
    /// the `op_apply` path calls this as each op is applied, so `commit_txn`
    /// finalizes a transaction whose `ops` replay to the same document — the
    /// `checkpoint_equivalence` gate (§6). No-op when no transaction is open
    /// (an op applied outside any bracket is not journaled), so this is safe to
    /// call unconditionally from the dispatcher.
    pub fn record_op(&mut self, op: PrimitiveOp) {
        if let Some(p) = self.pending_txn.as_mut() {
            p.ops.push(op);
        }
    }

    /// Set the open transaction's artist/AI-legible name (an `actions.yaml`
    /// verb). No-op when no transaction is open. Used by the `op_apply` path /
    /// action dispatch to label the transaction for the semantic-summary
    /// surface (OP_LOG.md §5).
    pub fn name_txn(&mut self, name: &str) {
        if let Some(p) = self.pending_txn.as_mut() {
            p.name = Some(name.to_string());
        }
    }

    // --- Versioning labels (OP_LOG.md Increment 3a / VISION.md §6.9) -------

    /// Mark the current document state as a named version point. Stores the
    /// document + paired index (so `restore_version` is O(1) and sound even
    /// though production transactions are opaque) and writes `label` onto the
    /// journal's transaction at the current head (the field reserved in
    /// Increment 2), so the label serializes into the journal artifact. Naming
    /// is idempotent: re-labeling an existing name re-points it here.
    pub fn label_version(&mut self, name: &str) {
        // Stamp the label onto the most-recent committed transaction, if any
        // (a version at the origin labels no transaction).
        if self.journal_head > 0 {
            if let Some(t) = self.op_journal.get_mut(self.journal_head - 1) {
                t.label = Some(name.to_string());
            }
        }
        let version = Version {
            label: name.to_string(),
            journal_head: self.journal_head,
            document: self.document.clone(),
            id_index: self.id_index.clone(),
        };
        if let Some(existing) = self.versions.iter_mut().find(|v| v.label == name) {
            *existing = version;
        } else {
            self.versions.push(version);
        }
    }

    /// The named version points, in creation order. Test/inspection accessor.
    pub fn versions(&self) -> &[Version] {
        &self.versions
    }

    /// Restore the document to a named version. This is an ordinary undoable
    /// edit (one transaction "restore version N"), so it stays on the linear
    /// undo/redo timeline rather than jumping the cursor non-linearly; the
    /// no-op rule makes restoring to the already-current state a no-op. Returns
    /// false if no such version exists.
    pub fn restore_version(&mut self, name: &str) -> bool {
        let Some(version) = self.versions.iter().find(|v| v.label == name) else {
            return false;
        };
        let doc = version.document.clone();
        self.with_txn(|m| {
            m.name_txn(&format!("restore version {}", name));
            m.set_document(doc);
        });
        true
    }

    // --- Transaction bracket (OP_LOG.md Increment 1) ----------------------
    //
    // The operation-log spine consolidates every undoable mutation through one
    // bracket: `begin_txn()` captures the pre-edit checkpoint, the caller commits
    // the edit via `set_document`, and `commit_txn()` finalizes (relocating the
    // redo-clear here, off of `snapshot()`). This is the bool-primitive form:
    // `begin_txn` is idempotent while a transaction is already open, so a session
    // that calls it on every keystroke (e.g. the type tools) still pushes exactly
    // one checkpoint per session and commits once at the end — without holding a
    // borrowing guard across event-handler calls (which Rust's borrow rules make
    // impractical). `with_txn` is the scoped one-shot form. Nothing calls these
    // yet in this sub-step; the existing `snapshot()` path is untouched, so undo
    // behavior is byte-identical until the call sites migrate.

    /// Open an undoable transaction: push the pre-edit checkpoint (the document
    /// and its paired index) onto the undo stack, exactly like [`snapshot`] but
    /// WITHOUT clearing the redo stack — the redo-clear happens at
    /// [`commit_txn`], so a new edit clears redo only once the edit commits.
    /// Idempotent while a transaction is already open (a nested `begin_txn` is a
    /// no-op), so many edits can ride one checkpoint.
    pub fn begin_txn(&mut self) {
        if self.in_txn {
            return;
        }
        self.undo_stack
            .push((self.document.clone(), self.id_index.clone()));
        if self.undo_stack.len() > MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.in_txn = true;
        // Start accumulating the transaction (OP_LOG.md Increment 2). `ops` is
        // populated by the `op_apply` path (sub-step 2.2); `gen_at_open` lets
        // `commit_txn` detect a zero-write no-op without serializing.
        self.pending_txn = Some(PendingTxn {
            name: None,
            ops: Vec::new(),
            gen_at_open: self.generation,
        });
    }

    /// Finalize the open transaction: clear the redo stack (the relocated
    /// "new edit invalidates redo" semantics — previously in [`snapshot`]) and
    /// close the bracket. **No-op when no transaction is open**, so a caller that
    /// commits unconditionally at the end of a possibly-no-edit session (e.g. the
    /// type tools, which open the bracket lazily on the first keystroke) does not
    /// spuriously clear redo when nothing was edited.
    pub fn commit_txn(&mut self) {
        if !self.in_txn {
            return;
        }
        self.in_txn = false;
        let pending = self.pending_txn.take();

        // No-op rule (OP_LOG.md §5/§9): a transaction whose net document change
        // is byte-identical is NOT journaled, and its undo checkpoint is dropped
        // so it leaves no undo step (keeping the undo stack and the journal
        // cursor in lock-step). Fast path: if no write happened at all
        // (generation unchanged since the owning begin_txn) it is definitely a
        // no-op; otherwise fall back to the canonical `document_to_test_json`
        // byte-compare against the checkpoint (the same canonicalization the
        // cross-language gate uses).
        //
        // CANONICALLY-INVISIBLE FIELDS (OP_LOG.md §9 Phase P6 follow-up):
        // `document_to_test_json` deliberately OMITS some authoritative fields
        // — notably the Path `stroke_brush` / `stroke_brush_overrides` brush
        // bindings — to keep the cross-language byte-gate compatible with legacy
        // fixtures. That makes the JSON compare BLIND to a transaction whose
        // ONLY net change is a brush edit (e.g. apply_brush_to_selection fired
        // on an already-selected path, where the selection does not change),
        // which would otherwise be dropped here: neither journaled NOR given an
        // undo step. So when the JSON says "no change" we additionally compare
        // the authoritative element trees (`layers` + the `symbols` master
        // store, the only homes of brush-bearing Paths) via `Element`'s derived
        // `PartialEq`, which DOES see those fields. A transaction is a no-op
        // only if BOTH the canonical JSON and the structural compare agree it
        // changed nothing; any canonically-invisible field edit keeps it.
        let gen_at_open = pending
            .as_ref()
            .map(|p| p.gen_at_open)
            .unwrap_or(self.generation);
        let no_net_change = self.generation == gen_at_open
            || self.undo_stack.last().is_some_and(|(chk, _)| {
                document_to_test_json(chk) == document_to_test_json(&self.document)
                    && chk.layers == self.document.layers
                    && chk.symbols == self.document.symbols
            });
        if no_net_change {
            // Drop the no-op checkpoint; leave redo and the journal untouched.
            self.undo_stack.pop();
            return;
        }

        // --- Per-frame drag coalescing (OP_LOG.md §9 follow-up) ------------
        //
        // A live drag commits ONE transaction PER FRAME: selection.yaml fires
        // `doc.snapshot` only on the first mousemove, and each subsequent
        // `on_mousemove` is its own `run_effects` batch that `begin_txn`s +
        // commits. So a drag of N frames lands as N consecutive single-op move
        // transactions in the journal — verbose, and N separate undo steps.
        //
        // Coalesce ADJACENT same-gesture move transactions into ONE (summed
        // delta), which also collapses the N undo steps into one. This is the
        // ONLY correct layer: `record_op` only ever sees the ops WITHIN one
        // pending_txn (a drag puts each frame's move in a SEPARATE pending_txn),
        // so the two consecutive drag moves only become adjacent HERE, where the
        // pending txn is finalized against the journal tip. The no-op rule above
        // runs FIRST, unchanged — a zero-delta single frame is dropped before we
        // ever reach coalescing.
        //
        // Coalescable verbs are EXACTLY the additive translates of the same
        // target set via `Controller::move_selection`: `move_selection` and its
        // id-primary twin `move_by_ids`. Never copy_selection/copy_by_ids (a
        // copy is non-additive — two copies != one copy), never the
        // selection-only verbs (run boundaries).
        if self.try_coalesce_drag_frame(pending.as_ref()) {
            // Merged into the journal tip in place; the pending txn is dropped
            // and its redundant undo checkpoint popped, so the undo stack and
            // the journal cursor stay in lock-step (one drag == one undo step).
            return;
        }

        // A real edit invalidates redo on BOTH representations: clear the redo
        // snapshot stack and truncate the journal's redo tail (the relocated
        // "new edit invalidates redo" semantics — OP_LOG.md §5).
        self.redo_stack.clear();
        self.op_journal.truncate(self.journal_head);
        let parent = self.op_journal.last().map(|t| t.txn_id.clone());
        let txn = Transaction {
            txn_id: format!("txn-{}", self.next_txn_counter),
            name: pending.as_ref().and_then(|p| p.name.clone()),
            ops: pending.map(|p| p.ops).unwrap_or_default(),
            summary: None,
            actor: Transaction::ACTOR_ARTIST.to_string(),
            parent,
            lamport: self.next_txn_counter,
            label: None,
        };
        self.next_txn_counter += 1;
        self.op_journal.push(txn);
        self.journal_head = self.op_journal.len();
    }

    /// Per-frame drag coalescing (OP_LOG.md §9 follow-up). Called by
    /// [`commit_txn`] AFTER the no-op early-return and BEFORE the normal
    /// truncate/append: try to merge the just-finalized pending transaction
    /// `T_new` into the journal tip `T_prev = op_journal[journal_head - 1]` as a
    /// summed-delta translate. Returns `true` iff it coalesced (the caller then
    /// returns early — the pending txn was absorbed, no new journal entry, and
    /// the redundant undo checkpoint was popped so the undo stack stays in
    /// lock-step with the journal cursor: one continuous drag == one undo step).
    ///
    /// PREDICATE (all must hold):
    ///  (guard) we are at the journal TIP: `journal_head == op_journal.len()`.
    ///    If the user undid then dragged, `journal_head < len`, and the tail
    ///    about to be truncated is NOT a valid merge target — do not coalesce.
    ///  (a) `T_new` has EXACTLY ONE op whose verb is a coalescable translate
    ///      (`move_selection` or `move_by_ids`).
    ///  (b) `T_prev.ops.last()` exists and has the SAME verb.
    ///  (c) targets BYTE-EQUAL: `T_prev.ops.last().targets == T_new.ops[0].targets`
    ///      (for `move_selection` these are the pre-mutation selection ids; for
    ///      `move_by_ids` the params `ids` array must ALSO be byte-equal).
    ///  (d) SAME NAME: `T_prev.name == T_new.name` — drag-scoped, so two
    ///      DELIBERATE separate same-target moves (e.g. a fresh gesture) stay
    ///      distinct undo steps rather than silently fusing.
    ///  (e) the ONLY params that differ are `dx`/`dy`.
    ///
    /// MERGE: sum `T_new`'s dx/dy into `T_prev`'s last op's params in place and
    /// drop `T_new` entirely. NET-ZERO WHOLE-DRAG: if the merged op's net delta
    /// is (0,0) AND the merged `T_prev` now byte-matches its ORIGIN checkpoint
    /// (the whole drag round-tripped), drop `T_prev` too and pop its origin
    /// checkpoint — the no-op rule extended across the coalesced run, leaving no
    /// journal entry and no undo step. Coalescing pops the LATER checkpoint and
    /// keeps the EARLIER/origin one, so the origin byte-compare stays valid.
    fn try_coalesce_drag_frame(&mut self, pending: Option<&PendingTxn>) -> bool {
        const COALESCABLE: [&str; 2] = ["move_selection", "move_by_ids"];

        // (guard) only at the journal tip; a post-undo drag must not merge into
        // the about-to-be-truncated redo tail.
        if self.journal_head != self.op_journal.len() {
            return false;
        }
        // (a) T_new is exactly one coalescable move op.
        let Some(pending) = pending else { return false };
        if pending.ops.len() != 1 {
            return false;
        }
        let new_op = &pending.ops[0];
        if !COALESCABLE.contains(&new_op.op.as_str()) {
            return false;
        }
        // T_prev = the journal tip; its LAST op is the merge target.
        let Some(prev) = self.op_journal.last() else {
            return false;
        };
        // (d) same drag-scoped name.
        if prev.name != pending.name {
            return false;
        }
        let Some(prev_op) = prev.ops.last() else {
            return false;
        };
        // (b) same verb.
        if prev_op.op != new_op.op {
            return false;
        }
        // (c) byte-equal targets (and, for move_by_ids, byte-equal `ids`).
        if prev_op.targets != new_op.targets {
            return false;
        }
        if new_op.op == "move_by_ids"
            && prev_op.params.get("ids") != new_op.params.get("ids")
        {
            return false;
        }
        // (e) the only params that differ are dx/dy: strip dx/dy from both and
        // require the remainder byte-equal. (This also catches a `move_by_ids`
        // whose non-`ids` payload diverged, and would catch any future param a
        // verb grows.)
        let strip = |p: &serde_json::Value| -> serde_json::Value {
            let mut p = p.clone();
            if let serde_json::Value::Object(m) = &mut p {
                m.remove("dx");
                m.remove("dy");
            }
            p
        };
        if strip(&prev_op.params) != strip(&new_op.params) {
            return false;
        }

        // --- MERGE: sum dx/dy into T_prev's last op in place. -------------
        let new_dx = new_op.params.get("dx").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let new_dy = new_op.params.get("dy").and_then(|v| v.as_f64()).unwrap_or(0.0);
        // Re-borrow mutably now that all the immutable checks have passed.
        let tip_idx = self.op_journal.len() - 1;
        let prev = &mut self.op_journal[tip_idx];
        let prev_op = prev.ops.last_mut().expect("checked non-empty above");
        let merged_dx =
            prev_op.params.get("dx").and_then(|v| v.as_f64()).unwrap_or(0.0) + new_dx;
        let merged_dy =
            prev_op.params.get("dy").and_then(|v| v.as_f64()).unwrap_or(0.0) + new_dy;
        if let serde_json::Value::Object(m) = &mut prev_op.params {
            m.insert("dx".into(), serde_json::json!(merged_dx));
            m.insert("dy".into(), serde_json::json!(merged_dy));
        }

        // Pop the redundant per-frame undo checkpoint (the same mechanism the
        // no-op rule uses): this frame contributes no new undo step, so the
        // undo stack stays in lock-step with the (unchanged) journal length.
        // After this pop, `undo_stack.last()` is T_prev's ORIGIN checkpoint.
        self.undo_stack.pop();

        // --- NET-ZERO WHOLE-DRAG: the coalesced run round-tripped. ---------
        // If the merged delta is exactly (0,0) AND the live document now
        // byte-matches T_prev's origin checkpoint, the whole drag (including
        // this frame) cancelled out: drop T_prev entirely and pop its origin
        // checkpoint too, so a round-trip drag leaves NO journal entry and NO
        // undo step (the no-op rule, extended across the coalesced run).
        if merged_dx == 0.0 && merged_dy == 0.0 {
            let round_tripped = self.undo_stack.last().is_some_and(|(chk, _)| {
                document_to_test_json(chk) == document_to_test_json(&self.document)
                    && chk.layers == self.document.layers
                    && chk.symbols == self.document.symbols
            });
            if round_tripped {
                self.op_journal.pop();
                self.journal_head = self.op_journal.len();
                self.undo_stack.pop();
            }
        }
        true
    }

    /// Abandon the open transaction, rolling the document and index back to the
    /// pre-edit checkpoint and discarding it (no redo entry). A `begin_txn`
    /// immediately followed by `abort_txn` is a no-op. No call site uses this in
    /// Increment 1; it exists for Increment 2 (e.g. an AI proposal the artist
    /// rejects after edits were applied through the bracket).
    pub fn abort_txn(&mut self) {
        if self.in_txn {
            if let Some((doc, index)) = self.undo_stack.pop() {
                self.document = doc;
                self.id_index = index;
            }
            self.in_txn = false;
            // An aborted transaction was never journaled, so the journal and its
            // cursor are untouched (OP_LOG.md §5).
            self.pending_txn = None;
        }
    }

    /// Run `f` inside a transaction: `begin_txn`, then `f(self)` (which performs
    /// the edit via [`set_document`] / Controller methods), then `commit_txn`.
    /// The scoped one-shot form of the bracket — no borrowing guard, so `f` has
    /// full `&mut Model` access. Returns whatever `f` returns.
    pub fn with_txn<R>(&mut self, f: impl FnOnce(&mut Model) -> R) -> R {
        self.begin_txn();
        let r = f(self);
        self.commit_txn();
        r
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
    fn max_untitled_n_finds_highest() {
        assert_eq!(max_untitled_n(&[]), 0);
        assert_eq!(max_untitled_n(&["drawing.svg".to_string()]), 0);
        assert_eq!(max_untitled_n(&["Untitled-1".to_string()]), 1);
        assert_eq!(
            max_untitled_n(&[
                "Untitled-1".to_string(),
                "Untitled-3".to_string(),
                "logo.svg".to_string(),
            ]),
            3
        );
        // Non-numeric / malformed suffixes are ignored.
        assert_eq!(max_untitled_n(&["Untitled-".to_string(), "Untitled-x".to_string()]), 0);
    }

    #[test]
    fn advance_past_restored_untitled_avoids_collision() {
        // A restored `Untitled-1` must push the next fresh name past it.
        // The counter is a process-global, so other tests may have advanced
        // it further; the invariant is only that the next name never collides
        // with the restored `Untitled-1` (i.e. its N is >= 2).
        advance_next_untitled_past(&["Untitled-1".to_string()]);
        let name = fresh_filename();
        let n: usize = name.strip_prefix("Untitled-").unwrap().parse().unwrap();
        assert!(n >= 2, "expected Untitled-2 or later, got {name}");
    }

    #[test]
    fn set_document() {
        let mut model = Model::default();
        let doc = Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() };
        model.with_txn(|m| m.set_document(doc));
        assert_eq!(model.document().layers.len(), 0);
    }

    #[test]
    fn undo_redo() {
        let mut model = Model::default();
        assert!(!model.can_undo());

        model.begin_txn();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        model.commit_txn();
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

        model.begin_txn();
        model.set_document(Document { layers: vec![layer.clone()], selected_layer: 0, selection: vec![], ..Document::default() });
        model.commit_txn();
        model.begin_txn();
        model.set_document(Document { layers: vec![layer.clone(), layer.clone()], selected_layer: 0, selection: vec![], ..Document::default() });
        model.commit_txn();

        model.undo();
        assert_eq!(model.document().layers.len(), 1);
        assert!(model.can_redo());

        model.begin_txn();
        model.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        model.commit_txn();
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
    fn is_modified_after_committed_edit() {
        // OP_LOG.md §9: is_modified tracks the journal cursor, so a committed
        // (undoable) transaction marks the document modified.
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document::default()));
        assert!(model.is_modified());
    }

    #[test]
    fn is_modified_unbracketed_write_does_not_modify() {
        // OP_LOG.md §9 unified semantics: a non-undoable write (selection /
        // preview / live-drag, via set_document_unbracketed) moves no
        // transaction, so it does NOT mark the document modified. This is the
        // observable flip from the old generation/identity semantics, and the
        // correct behavior — selecting something should not dirty the file.
        let mut model = Model::default();
        model.set_document_unbracketed(Document {
            layers: vec![make_layer("L")],
            ..Document::default()
        });
        assert!(!model.is_modified());
    }

    #[test]
    fn is_modified_false_after_mark_saved() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document::default()));
        assert!(model.is_modified());
        model.mark_saved();
        assert!(!model.is_modified());
    }

    #[test]
    fn is_modified_false_after_undo_back_to_saved() {
        // OP_LOG.md §9 headline change: with the journal-head cursor, undo back
        // to the saved point reads as NOT modified (the generation/identity
        // semantics reported modified here, because every write — including
        // undo — bumped the generation). This is the 4-way observable flip.
        let mut model = Model::default();
        model.mark_saved(); // saved at journal_head 0
        model.with_txn(|m| {
            m.set_document(Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() });
        });
        assert!(model.is_modified(), "a committed edit is modified");
        model.undo();
        assert!(!model.is_modified(), "undo back to the saved point is not modified");
        model.redo();
        assert!(model.is_modified(), "redo past the saved point is modified again");
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
    fn id_index_tracks_set_document() {
        let mut model = Model::default();
        // set_document refreshes the index incrementally.
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("a")));
        model.set_document_unbracketed(doc);
        assert!(model.id_index().get("a").is_some());
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // A second clone -> mutate -> set_document keeps the index consistent.
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("b")));
        model.set_document_unbracketed(doc);
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
    // single set_document chokepoint instead of full rebuilds. Each
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
        model.set_document_unbracketed(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "ins"), "inserted target resolves");
    }

    #[test]
    fn incremental_insert_then_delete_matches_rebuild() {
        let mut model = Model::default();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("gm")));
        model.set_document_unbracketed(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(resolves(&model, "gm"));
        // A second edit (delete) through set_document also stays consistent.
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().clear();
        model.set_document_unbracketed(doc);
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
        model.set_document_unbracketed(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // Replace the group wholesale via a CoW edit.
        let mut doc2 = model.document().clone();
        let g2 = Element::Group(GroupElem {
            children: vec![std::rc::Rc::new(id_rect("c"))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some("g2".into()), ..Default::default() },
        });
        doc2.layers[0].children_mut().unwrap()[0] = std::rc::Rc::new(g2);
        model.set_document_unbracketed(doc2);
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
        model.set_document_unbracketed(doc);
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));

        // Select d1 and d3 (paths [0,0] and [0,2]) and delete them together.
        let mut doc2 = model.document().clone();
        doc2.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ];
        let after = doc2.delete_selection();
        model.set_document_unbracketed(after);
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
        model.set_document_unbracketed(doc);

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
        model.begin_txn();
        let mut doc = model.document().clone();
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(id_rect("u1")));
        model.set_document(doc);
        model.commit_txn();
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
        model.set_document_unbracketed(doc);
        assert!(resolves(&model, "pv"));

        model.restore_preview_snapshot();
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
        assert!(!resolves(&model, "pv"), "preview edit reverted");
    }

    // --- Transaction bracket (OP_LOG.md Increment 1, sub-step 1) ----------
    //
    // These pin the new begin_txn/commit_txn/abort_txn/with_txn primitives.
    // The bracket is byte-equivalent to the old snapshot()+set_document path
    // except the redo-clear is relocated to commit_txn (not begin) — verified
    // explicitly below.

    fn empty_doc() -> Document {
        Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() }
    }

    #[test]
    #[should_panic(expected = "set_document outside a transaction")]
    fn set_document_outside_txn_panics() {
        // The enforced chokepoint (OP_LOG.md Increment 1): an undoable write that
        // skipped the transaction bracket fails the test suite via the live
        // debug_assert!(in_txn) in set_document. Non-undoable writes that need no
        // bracket use set_document_unbracketed (no assert) instead.
        let mut model = Model::default();
        model.set_document(empty_doc()); // no begin_txn -> debug_assert fires
    }

    #[test]
    fn begin_txn_captures_pre_edit_doc_for_undo() {
        // begin_txn pushes the PRE-edit checkpoint; after a set_document edit and
        // commit, undo restores the document as it was before begin_txn.
        let mut model = Model::default();
        assert_eq!(model.document().layers.len(), 1); // pre-edit state

        model.begin_txn();
        assert!(model.in_txn);
        model.set_document(empty_doc()); // the edit
        model.commit_txn();
        assert!(!model.in_txn);
        assert_eq!(model.document().layers.len(), 0);

        model.undo();
        assert_eq!(model.document().layers.len(), 1, "undo restored the pre-begin_txn document");
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
    }

    #[test]
    fn redo_clears_at_commit_not_begin() {
        // The redo-clear moved from snapshot() into commit_txn(). So after an
        // undo (redo non-empty), begin_txn must LEAVE redo intact and only
        // commit_txn clears it.
        let mut model = Model::default();
        model.begin_txn();
        model.set_document(empty_doc());
        model.commit_txn();
        model.undo();
        assert!(model.can_redo(), "undo populates redo");

        model.begin_txn();
        assert!(model.can_redo(), "begin_txn does NOT clear redo");
        model.set_document(empty_doc());
        model.commit_txn();
        assert!(!model.can_redo(), "commit_txn clears redo (new edit invalidates redo)");
    }

    #[test]
    fn begin_txn_is_idempotent_while_open() {
        // A session that calls begin_txn repeatedly pushes exactly ONE checkpoint
        // and undoes in one step (the type-tool lazy-session shape).
        let mut model = Model::default();
        let before = model.undo_stack.len();
        model.begin_txn();
        model.set_document(empty_doc());
        model.begin_txn(); // nested / repeated — no-op while open
        model.set_document(Document { layers: vec![make_layer("L")], ..Document::default() });
        model.commit_txn();
        assert_eq!(model.undo_stack.len(), before + 1, "exactly one checkpoint for the session");

        model.undo();
        assert_eq!(model.document().layers.len(), 1, "one undo step reverts the whole session");
    }

    #[test]
    fn abort_txn_rolls_back_edits() {
        let mut model = Model::default();
        let undo_before = model.undo_stack.len();

        model.begin_txn();
        model.set_document(empty_doc()); // edit
        model.abort_txn();

        assert!(!model.in_txn);
        assert_eq!(model.document().layers.len(), 1, "abort restored the pre-edit document");
        assert_eq!(model.undo_stack.len(), undo_before, "abort discarded the checkpoint");
        assert_eq!(model.id_index(), &rebuild_id_index(model.document()));
    }

    #[test]
    fn begin_then_abort_with_no_edit_is_noop() {
        let mut model = Model::default();
        let gen_before = model.generation();
        let undo_before = model.undo_stack.len();

        model.begin_txn();
        model.abort_txn();

        assert!(!model.in_txn);
        assert_eq!(model.generation(), gen_before, "no generation churn");
        assert_eq!(model.undo_stack.len(), undo_before);
        assert_eq!(model.document().layers.len(), 1);
    }

    #[test]
    fn with_txn_brackets_one_undo_step() {
        let mut model = Model::default();
        model.with_txn(|m| {
            m.set_document(empty_doc());
            m.set_document(Document { layers: vec![make_layer("A"), make_layer("B")], ..Document::default() });
        });
        assert!(!model.in_txn);
        assert_eq!(model.document().layers.len(), 2);

        model.undo();
        assert_eq!(model.document().layers.len(), 1, "the whole with_txn body is one undo step");
    }

    #[test]
    fn set_document_unbracketed_matches_set_document() {
        // Behavior-identical in this sub-step: same resulting document, same
        // generation bump, index stays consistent — but no checkpoint is pushed
        // (it is the non-undoable channel).
        let mut a = Model::default();
        let mut b = Model::default();
        let g_a = a.generation();
        let g_b = b.generation();

        a.with_txn(|m| m.set_document(empty_doc()));
        b.set_document_unbracketed(empty_doc());

        assert_eq!(a.document().layers.len(), b.document().layers.len());
        assert_eq!(a.generation() - g_a, b.generation() - g_b, "both bump generation by one");
        assert_eq!(b.id_index(), &rebuild_id_index(b.document()));
        assert!(!b.can_undo(), "unbracketed write pushes no checkpoint");
        assert!(a.can_undo(), "bracketed write pushes a checkpoint");
    }

    // --- Transaction journal (OP_LOG.md Increment 2, sub-step 2.1) ---------
    //
    // These pin the journal as a cursor: commit appends one Transaction per
    // net-change transaction, undo/redo move the cursor, the redo tail is
    // dropped on a new commit, no-op transactions are not journaled, and the
    // txn ids are a deterministic counter. The ops list is populated in a later
    // sub-step; here the journal's transaction COUNT + cursor are what matter.

    #[test]
    fn commit_journals_one_transaction_per_net_change_edit() {
        let mut model = Model::default();
        assert_eq!(model.journal().len(), 0);
        assert_eq!(model.journal_head(), 0);

        model.with_txn(|m| m.set_document(empty_doc()));
        assert_eq!(model.journal().len(), 1, "one committed edit = one transaction");
        assert_eq!(model.journal_head(), 1, "cursor advanced to the new transaction");

        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        assert_eq!(model.journal().len(), 2);
        assert_eq!(model.journal_head(), 2);
    }

    #[test]
    fn txn_ids_are_a_deterministic_counter() {
        // OP_LOG.md §7: txn-0, txn-1, … so the journal file is byte-shareable.
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(empty_doc()));
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        assert_eq!(model.journal()[0].txn_id, "txn-0");
        assert_eq!(model.journal()[1].txn_id, "txn-1");
        // The causal parent edge points at the prior transaction.
        assert_eq!(model.journal()[0].parent, None);
        assert_eq!(model.journal()[1].parent.as_deref(), Some("txn-0"));
    }

    #[test]
    fn no_op_transaction_is_not_journaled_and_leaves_no_undo_step() {
        // OP_LOG.md §5/§9: an empty / zero-net-change transaction is elided from
        // BOTH the journal and the undo stack.
        let mut model = Model::default();
        model.with_txn(|_m| { /* no edit */ });
        assert_eq!(model.journal().len(), 0, "no-op is not journaled");
        assert_eq!(model.journal_head(), 0);
        assert!(!model.can_undo(), "no-op leaves no undo step");

        // A write that nets back to the checkpoint document is also a no-op
        // (compared via document_to_test_json — the canonical byte form).
        let checkpoint = model.document().clone();
        model.with_txn(|m| {
            m.set_document(empty_doc());
            m.set_document(checkpoint.clone()); // back to the exact checkpoint
        });
        assert_eq!(model.journal().len(), 0, "net-identical transaction is not journaled");
        assert!(!model.can_undo());
        assert!(!model.is_modified());
    }

    #[test]
    fn undo_and_redo_move_the_journal_cursor() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(empty_doc()));
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        assert_eq!(model.journal_head(), 2);

        model.undo();
        assert_eq!(model.journal_head(), 1, "undo moves the cursor back");
        model.undo();
        assert_eq!(model.journal_head(), 0);
        // The journal itself is retained across undo (it is a cursor, not a high-water mark).
        assert_eq!(model.journal().len(), 2);

        model.redo();
        assert_eq!(model.journal_head(), 1, "redo moves the cursor forward");
        model.redo();
        assert_eq!(model.journal_head(), 2);
    }

    #[test]
    fn new_commit_after_undo_drops_the_redo_tail_of_the_journal() {
        // OP_LOG.md §5: commit truncates the journal at journal_head and appends,
        // so a new edit after undo drops the undone (redo) transactions.
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(empty_doc()));                       // txn-0
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() })); // txn-1
        assert_eq!(model.journal().len(), 2);

        model.undo(); // cursor at 1, txn-1 is now the redo tail
        assert_eq!(model.journal_head(), 1);

        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("B")], ..Document::default() })); // new txn
        assert_eq!(model.journal().len(), 2, "redo tail dropped, new txn appended");
        assert_eq!(model.journal_head(), 2);
        assert_eq!(model.journal()[1].txn_id, "txn-2", "counter keeps advancing");
        assert!(!model.can_redo(), "redo cleared on the new edit");
    }

    #[test]
    fn abort_does_not_journal_or_move_the_cursor() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(empty_doc())); // txn-0
        let head = model.journal_head();
        let len = model.journal().len();

        model.begin_txn();
        model.set_document(Document { layers: vec![make_layer("Z")], ..Document::default() });
        model.abort_txn();

        assert_eq!(model.journal().len(), len, "aborted transaction is not journaled");
        assert_eq!(model.journal_head(), head, "cursor unmoved by abort");
        assert_eq!(model.document().layers.len(), 0, "abort rolled back the edit");
    }

    // --- Versioning labels (OP_LOG.md Increment 3a) -----------------------

    #[test]
    fn label_version_stores_a_version_and_stamps_the_transaction() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        model.label_version("v1");

        assert_eq!(model.versions().len(), 1);
        assert_eq!(model.versions()[0].label, "v1");
        assert_eq!(model.versions()[0].journal_head, 1);
        // The label is stamped onto the committed transaction (serializes into
        // the journal artifact).
        assert_eq!(model.journal()[0].label.as_deref(), Some("v1"));
    }

    #[test]
    fn restore_version_is_an_undoable_edit_back_to_the_labeled_state() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        model.label_version("v1");
        // Edit past the version.
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A"), make_layer("B")], ..Document::default() }));
        assert_eq!(model.document().layers.len(), 2);

        assert!(model.restore_version("v1"));
        assert_eq!(model.document().layers.len(), 1, "restored the labeled document");
        // Restore is an ordinary transaction on the linear timeline — undoable.
        assert!(model.can_undo());
        model.undo();
        assert_eq!(model.document().layers.len(), 2, "undo reverts the restore");
    }

    #[test]
    fn restore_version_to_current_state_is_a_noop() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        model.label_version("v1");
        let head = model.journal_head();
        // Already at v1's state — restoring is a no-op (not journaled).
        assert!(model.restore_version("v1"));
        assert_eq!(model.journal_head(), head, "no transaction for a no-op restore");
    }

    #[test]
    fn label_version_relabel_repoints_and_unknown_restore_returns_false() {
        let mut model = Model::default();
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A")], ..Document::default() }));
        model.label_version("v1");
        model.with_txn(|m| m.set_document(Document { layers: vec![make_layer("A"), make_layer("B")], ..Document::default() }));
        model.label_version("v1"); // re-point to the new state

        assert_eq!(model.versions().len(), 1, "re-label re-points, no duplicate");
        assert_eq!(model.versions()[0].journal_head, 2);
        assert!(!model.restore_version("nope"), "unknown version restore is a no-op false");
    }
}
