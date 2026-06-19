import Foundation
import Combine
import Collections

/// The target that drawing tools operate on. The default is the
/// document's normal content; mask-editing mode switches the
/// target to a specific element's mask subtree so new shapes land
/// inside ``element.mask.subtree`` instead of the selected layer.
/// Mirrors ``EditingTarget`` in ``jas_dioxus``. OPACITY.md
/// §Preview interactions.
public enum EditingTarget: Equatable {
    /// The document's normal content (default).
    case content
    /// Mask-editing mode: the element at ``path`` has its mask
    /// subtree as the drawing target.
    case mask([Int])
}

private var nextUntitled = 1

/// A named version point (OP_LOG.md Increment 3a / VISION.md §6.9). Stores the
/// document + paired index at a labeled journal cursor position so
/// ``Model/restoreVersion(_:)`` is O(1) and sound regardless of whether the
/// intervening transactions carry replayable ops. Mirrors Rust's `Version`.
public struct Version {
    public var label: String
    public var journalHead: Int
    public var document: Document
    public var idIndex: IdIndex

    public init(label: String, journalHead: Int, document: Document, idIndex: IdIndex) {
        self.label = label
        self.journalHead = journalHead
        self.document = document
        self.idIndex = idIndex
    }
}

private func freshFilename() -> String {
    let name = "Untitled-\(nextUntitled)"
    nextUntitled += 1
    return name
}

/// The transaction being accumulated between ``Model/beginTxn()`` and
/// ``Model/commitTxn()`` (OP_LOG.md Increment 2). ``name`` / ``ops`` are
/// populated by the op-apply path; ``genAtBegin`` snapshots the generation at
/// the owning ``beginTxn`` so ``commitTxn`` can detect a zero-write
/// transaction without serializing. Mirrors Rust's `PendingTxn`.
private struct PendingTxn {
    var name: String? = nil
    var ops: [PrimitiveOp] = []
    var genAtBegin: UInt64
}

/// Observable model that holds the current document.
///
/// Views register callbacks via onDocumentChanged to be notified
/// whenever the document is replaced.
public class Model: ObservableObject {
    /// The current document. The setter is `private(set)`, so external code
    /// CANNOT write `model.document = ...`; it must funnel through one of the
    /// three intent methods (`setDocument` / `editDocument` /
    /// `setDocumentUnbracketed`) below. That makes the transaction-bracket
    /// enforcement in `setDocument` UNBYPASSABLE at compile time (a stray bare
    /// undoable write is a compile error, not a runtime gamble) — the strongest
    /// form of the OP_LOG.md Increment 1 enforced chokepoint, stronger than the
    /// runtime-routed property setter Python/OCaml use because Swift can make the
    /// write itself unreachable from outside. SwiftUI binding observation and
    /// external READS still work (only the *setter* is restricted).
    ///
    /// The `didSet` remains the BYTE-LEVEL chokepoint (index refresh / generation
    /// bump / notify); the three methods are the INTENT chokepoint layered on top.
    @Published public private(set) var document: Document {
        didSet {
            // The document setter is the single mutation chokepoint
            // (every edit goes through `model.document = ...`), so refresh
            // the paired id->element index here (REFERENCE_GRAPH.md §2.4
            // Phase 4b, Option B "rebuild-at-chokepoint"). undo/redo restore
            // a SNAPSHOT-CARRIED index in O(1) instead of rebuilding, so they
            // hand it in via `restoringIndex`; every other write rebuilds.
            if let carried = restoringIndex {
                idIndex = carried
                restoringIndex = nil
            } else {
                refreshIdIndex()
            }
            // Phase 4c: bump the modification generation on every document
            // write (the chokepoint covers normal edits, undo/redo, and
            // preview restore). Read at the paint entry to epoch the
            // reference-geometry recompute cache: any edit changes the
            // generation and drops the cache. Mirrors Rust `Model.generation`.
            generation &+= 1
            notify()
        }
    }

    // MARK: - Intent chokepoint (OP_LOG.md Increment 1, enforced)
    //
    // Three writes funnel into the `document` setter (the byte-level chokepoint),
    // mirroring jas_dioxus `model.rs`, jas `model.py`, and jas_ocaml `model.ml`:
    //   - `setDocument`            — UNDOABLE write; asserts `isInTxn` is open.
    //   - `editDocument`           — SELF-BRACKETING undoable write (opens and
    //                                commits its own txn when none is open, else
    //                                joins the caller). What Controller mutators
    //                                use, so a standalone edit is a complete
    //                                one-step undo and a nested one joins the
    //                                owning action.
    //   - `setDocumentUnbracketed` — sanctioned NON-undoable write (selection /
    //                                preview re-apply / live drag / view-state /
    //                                undo-redo history-nav / test setup); never
    //                                asserts (OP_LOG.md §7/§8).
    // The distinct names let the live `isInTxn` guard in `setDocument` tell
    // "deliberately not undoable" from "forgot to open a transaction": the former
    // says so by calling `setDocumentUnbracketed` directly.

    /// Replace the document — the committing write for UNDOABLE mutations. The
    /// `assert(isInTxn)` is LIVE (OP_LOG.md Increment 1, enforced chokepoint):
    /// any undoable edit that skipped the transaction bracket fails the test
    /// suite, so the journal cursor is complete by construction. Active in the
    /// debug/test build (the whole suite runs in debug, like the id-index gate)
    /// and stripped under `-Ounchecked`, so it costs nothing in release.
    /// Self-bracketing mutators use ``editDocument(_:)``; sanctioned non-undoable
    /// writes use ``setDocumentUnbracketed(_:)`` (which never asserts). Mirrors
    /// the Rust `set_document`.
    public func setDocument(_ doc: Document) {
        assert(isInTxn,
            "setDocument outside a transaction: undoable edits use beginTxn/" +
            "commitTxn or withTxn; Controller mutators use editDocument; " +
            "non-undoable writes (selection, preview, live-drag, view-state, " +
            "undo/redo, test setup) use setDocumentUnbracketed.")
        document = doc
    }

    /// Self-bracketing undoable write: if no transaction is open, wrap this edit
    /// in its own begin/commit (one undo step); if one is already open, just
    /// write (joining the caller's transaction). This is what the ``Controller``
    /// mutators use, so a standalone call (a unit test, or a direct Controller
    /// call) is a complete one-step undo, while the same method called inside a
    /// UI ``withTxn(_:)`` / ``beginTxn()`` joins that action — production behavior
    /// is unchanged, and no test needs an explicit bracket. Distinct from
    /// ``setDocument(_:)`` (asserts a transaction is open) and
    /// ``setDocumentUnbracketed(_:)`` (non-undoable). Mirrors the Rust
    /// `edit_document`.
    public func editDocument(_ doc: Document) {
        let opened = !isInTxn
        if opened { beginTxn() }
        document = doc
        if opened { commitTxn() }
    }

    /// Committing write for sanctioned NON-undoable mutations — selection-only
    /// and pure view-state changes, dialog-preview re-apply, live drag, undo/redo
    /// history-nav, and test setup (OP_LOG.md §7/§8). Same effect as
    /// ``setDocument(_:)`` but the distinct name is what lets the live `isInTxn`
    /// guard in ``setDocument(_:)`` tell "deliberately not undoable" from "forgot
    /// to open a transaction": this path never asserts. Mirrors the Rust
    /// `set_document_unbracketed`.
    public func setDocumentUnbracketed(_ doc: Document) {
        document = doc
    }
    /// Monotonic modification generation (Phase 4c). Bumped in the `document`
    /// `didSet` chokepoint, so every document replacement advances it. Read at
    /// the paint entry to epoch the reference-geometry recompute cache (cleared
    /// whenever it changes). Mirrors Rust's `Model.generation`.
    public private(set) var generation: UInt64 = 0
    /// Persistent id->element index paired with `document`
    /// (REFERENCE_GRAPH.md §2.4 Phase 4b). A pure function of `document`
    /// (always equal to `rebuildIdIndex(document)`; checked by the
    /// `assert` gate in `refreshIdIndex`), so it is never serialized and
    /// never part of Document equality. Stored here, alongside the snapshot,
    /// so paint reads it without rebuilding and undo carries it in O(1)
    /// (TreeDictionary structure sharing — the undo/redo stacks pair each
    /// Document with its index for the same reason). Mirrors Rust's
    /// `Model.id_index`.
    public private(set) var idIndex: IdIndex
    /// Set by undo/redo to the snapshot-carried index just before the paired
    /// document assignment, so the setter's `didSet` adopts it in O(1) rather
    /// than rebuilding from scratch. nil for all other writes.
    private var restoringIndex: IdIndex? = nil
    @Published public var filename: String
    @Published public var defaultFill: Fill? = nil
    @Published public var defaultStroke: Stroke? = Stroke(color: .black)
    @Published public var fillOnTop: Bool = true
    /// Per-document list of recently committed colors (hex strings, no #), newest first. Max 10.
    @Published public var recentColors: [String] = []
    /// Shared StateStore for panel-scoped state. Panels call
    /// `initPanel` on first render and `setPanel` on every widget
    /// write; the store survives across re-renders so edits persist.
    /// A panel-state mutation bumps `panelStateVersion` so SwiftUI
    /// re-renders the bound views.
    public let stateStore: StateStore = StateStore()
    @Published public var panelStateVersion: Int = 0
    /// Stack of isolated container paths for the Layers panel. Each entry
    /// is a top-level path [Int]. Written by enter/exit_isolation_mode
    /// actions via YAML dispatch (see LayersPanel.dispatchYamlAction).
    @Published public var layersIsolationStack: [[Int]] = []
    /// Mask-editing mode state. ``.content`` is the default (drawing
    /// tools add to the selected layer); ``.mask(path)`` switches
    /// the editing target to ``element.mask.subtree`` at ``path``.
    /// Flipped by clicking the Opacity panel's OPACITY_PREVIEW or
    /// MASK_PREVIEW. OPACITY.md §Preview interactions.
    @Published public var editingTarget: EditingTarget = .content
    /// Mask-isolation path. When non-nil, the canvas renders only
    /// the mask subtree of the element at this path, hiding
    /// everything else. Entered by Alt/Option-clicking MASK_PREVIEW;
    /// exited by Alt-clicking MASK_PREVIEW again (or Escape in a
    /// future increment). OPACITY.md §Preview interactions.
    @Published public var maskIsolationPath: [Int]? = nil
    /// Per-document view state (per ZOOM_TOOL.md §State persistence).
    /// Persists across tab switches within a session; reset to
    /// defaults on document open. Not serialized to disk in Phase 1.
    @Published public var zoomLevel: Double = 1.0
    @Published public var viewOffsetX: Double = 0.0
    @Published public var viewOffsetY: Double = 0.0
    /// Canvas viewport dimensions in screen-space pixels. Updated by
    /// the canvas widget on layout / resize. Read by doc.zoom.fit_*
    /// effects to compute the new zoom factor that fits a rect into
    /// the visible canvas area. Defaults match
    /// workspace/layout.yaml's canvas_pane default_position.
    @Published public var viewportW: Double = 888.0
    @Published public var viewportH: Double = 900.0
    /// Live reference to the active in-place text-editing session, if
    /// any. TypeTool and TypeOnPathTool publish their session here
    /// while editing so the Character-panel write pipeline can route
    /// panel writes to the session's next-typed-character state when a
    /// bare caret is placed. Cleared when the session ends.
    public var currentEditSession: TextEditSession? = nil
    public private(set) var savedDocument: Document
    private var listeners: [(Document) -> Void] = []
    /// Undo/redo stacks pair each Document with its id->element index so
    /// undo/redo restore the index in O(1) without a rebuild (TreeDictionary
    /// copy is O(1) structure sharing). Mirrors Rust's `Vec<(Document,
    /// IdIndex)>`.
    private var undoStack: [(Document, IdIndex)] = []
    private var redoStack: [(Document, IdIndex)] = []
    private let maxUndo = 100

    // MARK: - Transaction journal (OP_LOG.md Increment 2, full journal)
    //
    // The journal-head cursor + the typed Transaction journal, layered on the
    // snapshot stacks (which remain the undo/redo mechanism — OP_LOG.md §4).
    // `snapshot()` (the production undoable-edit boundary) advances the cursor
    // but records NO Transaction; `beginTxn`/`commitTxn` build the typed journal
    // (the op-apply / harness path). Both advance `journalHead`; a given flow
    // uses one path or the other.

    /// The journal cursor — the count of transactions currently applied
    /// (0...op_journal length). NOT a high-water mark: `commitTxn` truncates the
    /// journal here and appends (a new edit after undo drops the redo tail);
    /// `undo` decrements it, `redo` increments it. `snapshot()` increments it
    /// (an uncapped count of undoable edits, unlike the MAX_UNDO-capped stack).
    /// Mirrors Rust's `journal_head`.
    private var journalHead: Int = 0
    /// The `journalHead` captured at the last save; `isModified` is exactly
    /// `journalHead != savedJournalHead`, so undo back to the saved point reads
    /// as not-modified (OP_LOG.md §5/§9). Mirrors Rust's `saved_journal_head`.
    private var savedJournalHead: Int = 0
    /// The ordered Transaction journal (OP_LOG.md §5). The legible / replayable /
    /// mergeable artifact. Mirrors Rust's `op_journal`.
    private var opJournal: [Transaction] = []
    /// The transaction being accumulated between `beginTxn` and `commitTxn`.
    private var pendingTxn: PendingTxn? = nil
    /// True while an undoable transaction is open (OP_LOG.md Increment 1).
    private var inTxn: Bool = false
    /// Deterministic txn-id counter: txn-0, txn-1, … (OP_LOG.md §7), the same
    /// discipline element ids use, so the journal file is byte-shareable across
    /// apps. Mirrors Rust's `next_txn_counter`.
    private var nextTxnCounter: UInt64 = 0
    /// OP_LOG.md Increment 3a: named version points (VISION.md §6.9). Each labels
    /// a journal cursor position and stores the document + paired index at that
    /// point, so ``restoreVersion(_:)`` is O(1) and sound even though production
    /// transactions are opaque (no op replay needed). The label is also written
    /// onto the journal's transaction at that head (the `label` field reserved in
    /// Increment 2) so it serializes into the journal artifact. Mirrors Rust's
    /// `versions`.
    private var versionsStore: [Version] = []

    /// True if the document has unsaved committed edits. The unified OP_LOG.md
    /// §5/§9 semantics: `journalHead != savedJournalHead`, the journal CURSOR
    /// rather than a document-identity compare — so an undo back to the saved
    /// point reads as not-modified, and a non-undoable selection-only write that
    /// does not snapshot does not mark the document modified. Mirrors Rust's
    /// `is_modified`.
    public var isModified: Bool { journalHead != savedJournalHead }

    public init(document: Document = Document(), filename: String? = nil) {
        // Build the companion index BEFORE assigning `document`, because the
        // setter's `didSet` reads `idIndex`/`restoringIndex` (both must be
        // initialized first). The didSet then rebuilds it from `document`, so
        // the stored value equals a fresh rebuild from the first observable
        // point. Mirrors Rust building the index in `Model::new`.
        self.idIndex = rebuildIdIndex(document)
        self.document = document
        self.savedDocument = document
        self.filename = filename ?? freshFilename()
        // Center the current artboard in the default viewport at
        // construction time. Per ZOOM_TOOL.md §Document-open
        // behavior. The first canvas-size sync re-centers using the
        // real viewport dimensions.
        self.centerViewOnCurrentArtboard()
    }

    /// Center the canvas view on the current artboard using the
    /// stored viewportW / viewportH. If the artboard fits at the
    /// current zoom, set pan to center it; otherwise apply
    /// fit-inside semantics with 20px screen-space padding.
    /// Per ZOOM_TOOL.md §Document-open behavior.
    public func centerViewOnCurrentArtboard() {
        guard let ab = document.artboards.first else { return }
        guard viewportW > 0, viewportH > 0 else { return }
        let abW = Double(ab.width)
        let abH = Double(ab.height)
        let abX = Double(ab.x)
        let abY = Double(ab.y)
        let fits = abW * zoomLevel <= viewportW
            && abH * zoomLevel <= viewportH
        if fits {
            viewOffsetX = viewportW / 2.0 - (abX + abW / 2.0) * zoomLevel
            viewOffsetY = viewportH / 2.0 - (abY + abH / 2.0) * zoomLevel
        } else {
            let pad = 20.0
            let availW = viewportW - 2.0 * pad
            let availH = viewportH - 2.0 * pad
            if availW > 0, availH > 0 {
                let zFit = min(availW / abW, availH / abH)
                let zClamped = min(max(zFit, 0.1), 64.0)
                zoomLevel = zClamped
                viewOffsetX = viewportW / 2.0 - (abX + abW / 2.0) * zClamped
                viewOffsetY = viewportH / 2.0 - (abY + abH / 2.0) * zClamped
            }
        }
    }

    public func markSaved() {
        // OP_LOG.md §9: record the current journal cursor as the on-disk
        // baseline, after which `isModified` returns false until the next
        // committed edit (or until undo/redo move the cursor off this point).
        savedJournalHead = journalHead
        savedDocument = document
        objectWillChange.send()
    }

    /// View shortcuts shared between the canvas keyDown handler and
    /// the View menu commands. Both paths must call into the same
    /// place — otherwise the SwiftUI menu's keyboardShortcut steals
    /// the chord before the canvas sees it, leaving the menu button
    /// the only working invocation surface (and a stub menu button is
    /// what bit us in the smoke before this landed). Hard-coded zoom
    /// limits match workspace prefs (zoom_step 1.2, min/max 0.1 / 64).
    public func zoomIn() { applyZoomCentered(factor: 1.2) }
    public func zoomOut() { applyZoomCentered(factor: 1.0 / 1.2) }
    public func zoomToActualSize() {
        zoomLevel = min(max(1.0, 0.1), 64.0)
    }
    public func fitActiveArtboard() {
        guard let ab = document.artboards.first else { return }
        fitRect(x: Double(ab.x), y: Double(ab.y),
                w: Double(ab.width), h: Double(ab.height))
    }
    public func fitAllArtboards() {
        let abs = document.artboards
        guard !abs.isEmpty else { return }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for ab in abs {
            minX = min(minX, Double(ab.x))
            minY = min(minY, Double(ab.y))
            maxX = max(maxX, Double(ab.x + ab.width))
            maxY = max(maxY, Double(ab.y + ab.height))
        }
        fitRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    private func applyZoomCentered(factor: Double) {
        let cx = viewportW / 2.0
        let cy = viewportH / 2.0
        let docCx = (cx - viewOffsetX) / zoomLevel
        let docCy = (cy - viewOffsetY) / zoomLevel
        let z = min(max(zoomLevel * factor, 0.1), 64.0)
        zoomLevel = z
        viewOffsetX = cx - docCx * z
        viewOffsetY = cy - docCy * z
    }

    private func fitRect(x: Double, y: Double, w: Double, h: Double) {
        guard w > 0, h > 0, viewportW > 0, viewportH > 0 else { return }
        let pad = 20.0
        let availW = viewportW - 2 * pad
        let availH = viewportH - 2 * pad
        guard availW > 0, availH > 0 else { return }
        let z = min(max(min(availW / w, availH / h), 0.1), 64.0)
        zoomLevel = z
        viewOffsetX = viewportW / 2.0 - (x + w / 2.0) * z
        viewOffsetY = viewportH / 2.0 - (y + h / 2.0) * z
    }

    public func onDocumentChanged(_ callback: @escaping (Document) -> Void) {
        listeners.append(callback)
    }

    public func snapshot() {
        // Pair the index with the document on the stack so undo/redo restore
        // it in O(1) without a rebuild (TreeDictionary copy is O(1) structure
        // sharing). Mirrors Rust `snapshot` pushing `(document, id_index)`.
        undoStack.append((document, idIndex))
        if undoStack.count > maxUndo {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        // Advance the journal cursor: one undoable edit (OP_LOG.md §5). The
        // counter is uncapped, unlike the MAX_UNDO-capped stack, so isModified
        // stays correct past the cap. snapshot() is the production boundary —
        // it advances the cursor but records NO Transaction (production edits
        // are opaque), matching Rust.
        journalHead += 1
    }

    /// Rebuild the id->element index from the current document and assert it
    /// equals a from-scratch rebuild. Called from the `document` `didSet`
    /// chokepoint (every non-undo/redo write). The `assert` is the trust gate
    /// (REFERENCE_GRAPH.md §2.3): active in debug — the whole test suite runs
    /// in debug — so it proves the stored index always matches a fresh
    /// rebuild, with zero release-build cost. Mirrors Rust's
    /// `refresh_id_index` + `debug_assert!`.
    private func refreshIdIndex() {
        idIndex = rebuildIdIndex(document)
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after refresh")
    }

    /// Out-of-band document snapshot used by dialog Preview flows
    /// (Scale Options, Rotate Options, Shear Options). Captured at
    /// dialog open, restored on Cancel, cleared on OK. Distinct
    /// from the undo stack so preview-driven applies do not
    /// pollute undo history. See SCALE_TOOL.md §Preview.
    private var previewDocSnapshot: Document?

    public func capturePreviewSnapshot() {
        previewDocSnapshot = document
    }

    public func restorePreviewSnapshot() {
        if let snap = previewDocSnapshot {
            document = snap
            notify()
            objectWillChange.send()
        }
    }

    public func clearPreviewSnapshot() {
        previewDocSnapshot = nil
    }

    public var hasPreviewSnapshot: Bool { previewDocSnapshot != nil }

    public func undo() {
        // History navigation ends any open edit context, so the next edit
        // self-brackets fresh (OP_LOG.md Increment 1: keeps inTxn honest after
        // undo). Mirrors Rust `undo` clearing in_txn / pending_txn.
        inTxn = false
        pendingTxn = nil
        guard let (prevDoc, prevIndex) = undoStack.popLast() else { return }
        redoStack.append((document, idIndex))
        // Hand the snapshot-carried index to the setter so its didSet adopts
        // it in O(1) instead of rebuilding (Option B O(1) carry). The
        // refresh-path assert below confirms it still equals a fresh rebuild.
        restoringIndex = prevIndex
        document = prevDoc
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after undo")
        // Move the journal cursor back one transaction (OP_LOG.md §5). Only
        // when a checkpoint was actually popped, so a no-op undo at the stack
        // floor does not desync the cursor.
        if journalHead > 0 {
            journalHead -= 1
        }
    }

    public func redo() {
        inTxn = false
        pendingTxn = nil
        guard let (nextDoc, nextIndex) = redoStack.popLast() else { return }
        undoStack.append((document, idIndex))
        restoringIndex = nextIndex
        document = nextDoc
        assert(idIndex == rebuildIdIndex(document),
               "id index diverged from rebuild after redo")
        // Advance the journal cursor one transaction (OP_LOG.md §5). On a
        // successful redo-stack pop the cursor always moves forward, including
        // the snapshot-driven flow (which advances the cursor without growing
        // the typed journal). Mirrors Python's unconditional redo increment.
        journalHead += 1
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Transaction journal (OP_LOG.md Increment 2, full journal)
    //
    // beginTxn / commitTxn build the typed Transaction journal (the op-apply /
    // harness path). They sit alongside snapshot() (the production undoable-edit
    // boundary, which advances the journal cursor but records no Transaction).
    // record_op / name_txn populate the open transaction.

    /// The Transaction journal (OP_LOG.md §5). Test/inspection accessor.
    public var journal: [Transaction] { opJournal }

    /// The journal cursor — the number of transactions currently applied
    /// (0...journal length). Test/inspection accessor.
    public var journalHeadValue: Int { journalHead }

    /// True while an undoable transaction is open (between `beginTxn` and
    /// `commitTxn`). Lets a reentrant caller decide whether IT opened the
    /// transaction (and so should commit it) versus running nested inside an
    /// already-open one. Mirrors Rust's `in_txn`.
    public var isInTxn: Bool { inTxn }

    /// Open an undoable transaction: push the pre-edit checkpoint (the document
    /// and its paired index) onto the undo stack, exactly like ``snapshot()``
    /// but WITHOUT clearing the redo stack — the redo-clear happens at
    /// ``commitTxn()``, so a new edit clears redo only once the edit commits.
    /// Idempotent while a transaction is already open (a nested `beginTxn` is a
    /// no-op), so many edits can ride one checkpoint. Mirrors Rust's `begin_txn`.
    public func beginTxn() {
        if inTxn { return }
        undoStack.append((document, idIndex))
        if undoStack.count > maxUndo {
            undoStack.removeFirst()
        }
        inTxn = true
        // Start accumulating the transaction (OP_LOG.md Increment 2). `ops` is
        // populated by the op-apply path; `genAtBegin` lets `commitTxn` detect
        // a zero-write no-op without serializing.
        pendingTxn = PendingTxn(genAtBegin: generation)
    }

    /// Finalize the open transaction. No-op rule (OP_LOG.md §5/§9): a
    /// zero-net-change transaction is NOT journaled and its undo checkpoint is
    /// dropped (keeping the undo stack and the journal cursor in lock-step).
    /// Otherwise append one Transaction (deterministic txn-N id), truncating the
    /// journal's redo tail at `journalHead`, and clear redo. **No-op when no
    /// transaction is open**, so a caller that commits unconditionally at the end
    /// of a possibly-no-edit session does not spuriously clear redo. Mirrors
    /// Rust's `commit_txn`.
    public func commitTxn() {
        if !inTxn { return }
        inTxn = false
        let pending = pendingTxn
        pendingTxn = nil

        // No-op rule (OP_LOG.md §5/§9). Fast path: if no write happened at all
        // (generation unchanged since the owning beginTxn) it is definitely a
        // no-op. Otherwise fall back to the canonical `documentToTestJson`
        // byte-compare against the checkpoint (the same canonicalization the
        // cross-language gate uses).
        //
        // CANONICALLY-INVISIBLE FIELDS (OP_LOG.md §9 Phase P6 follow-up):
        // `documentToTestJson` deliberately OMITS some authoritative fields —
        // notably the Path `strokeBrush` / `strokeBrushOverrides` brush bindings
        // — to keep the cross-language byte-gate compatible with legacy fixtures.
        // That makes the JSON compare BLIND to a transaction whose ONLY net
        // change is a brush edit (e.g. set_attr_on_selection fired on an
        // already-selected path, where the selection does not change), which
        // would otherwise be dropped here: neither journaled NOR given an undo
        // step. So when the JSON says "no change" we additionally compare the
        // authoritative element trees (`layers` + the `symbols` master store, the
        // only homes of brush-bearing Paths) via the derived `Equatable`, which
        // DOES see those fields. A transaction is a no-op only if BOTH the
        // canonical JSON and the structural compare agree it changed nothing; any
        // canonically-invisible field edit keeps it. Mirrors Rust
        // `Model::commit_txn`.
        let genAtBegin = pending?.genAtBegin ?? generation
        let checkpoint = undoStack.last?.0
        let noNetChange = generation == genAtBegin
            || (checkpoint.map {
                documentToTestJson($0) == documentToTestJson(document)
                    && $0.layers == document.layers
                    && $0.symbols == document.symbols
            } ?? false)
        if noNetChange {
            // Drop the no-op checkpoint; leave redo and the journal untouched.
            if !undoStack.isEmpty { undoStack.removeLast() }
            return
        }

        // A real edit invalidates redo on BOTH representations: clear the redo
        // snapshot stack and truncate the journal's redo tail (the relocated
        // "new edit invalidates redo" semantics — OP_LOG.md §5).
        redoStack.removeAll()
        if journalHead < opJournal.count {
            opJournal.removeLast(opJournal.count - journalHead)
        }
        let parent = opJournal.last?.txnId
        let txn = Transaction(
            txnId: "txn-\(nextTxnCounter)",
            ops: pending?.ops ?? [],
            name: pending?.name,
            actor: actorArtist,
            parent: parent,
            lamport: nextTxnCounter)
        nextTxnCounter += 1
        opJournal.append(txn)
        journalHead = opJournal.count
    }

    /// Abandon the open transaction, rolling the document and index back to the
    /// pre-edit checkpoint and discarding it (no redo entry, no journal entry,
    /// no cursor move). A `beginTxn` immediately followed by `abortTxn` is a
    /// no-op. Mirrors Rust's `abort_txn`.
    public func abortTxn() {
        if !inTxn { return }
        inTxn = false
        pendingTxn = nil
        if let (doc, index) = undoStack.popLast() {
            restoringIndex = index
            document = doc
        }
    }

    /// Run `body` inside a transaction: ``beginTxn()``, then `body()`, then
    /// ``commitTxn()``. The scoped one-shot form of the bracket. Mirrors Rust's
    /// `with_txn`.
    public func withTxn(_ body: () -> Void) {
        beginTxn()
        body()
        commitTxn()
    }

    /// Append a primitive op to the open transaction's record (OP_LOG.md §5):
    /// the op-apply path calls this as each op is applied, so ``commitTxn()``
    /// finalizes a transaction whose `ops` replay to the same document — the
    /// checkpoint_equivalence gate (§6). No-op when no transaction is open (an
    /// op applied outside any bracket is not journaled). Mirrors Rust's
    /// `record_op`.
    public func recordOp(_ op: PrimitiveOp) {
        pendingTxn?.ops.append(op)
    }

    /// Set the open transaction's artist/AI-legible name. No-op when no
    /// transaction is open. Mirrors Rust's `name_txn`.
    public func nameTxn(_ name: String) {
        pendingTxn?.name = name
    }

    // MARK: - Versioning labels (OP_LOG.md Increment 3a / VISION.md §6.9)

    /// The named version points, in creation order. Test/inspection accessor.
    /// Mirrors Rust's `versions`.
    public var versions: [Version] { versionsStore }

    /// Mark the current document state as a named version point. Stores the
    /// document + paired index (so ``restoreVersion(_:)`` is O(1) and sound even
    /// though production transactions are opaque) and writes `label` onto the
    /// journal's transaction at the current head (the field reserved in
    /// Increment 2), so the label serializes into the journal artifact. Naming
    /// is idempotent: re-labeling an existing name re-points it here. Mirrors
    /// Rust's `label_version`.
    public func labelVersion(_ name: String) {
        // Stamp the label onto the most-recent committed transaction, if any
        // (a version at the origin labels no transaction).
        if journalHead > 0, journalHead - 1 < opJournal.count {
            opJournal[journalHead - 1].label = name
        }
        let version = Version(
            label: name,
            journalHead: journalHead,
            document: document,
            idIndex: idIndex)
        if let i = versionsStore.firstIndex(where: { $0.label == name }) {
            versionsStore[i] = version
        } else {
            versionsStore.append(version)
        }
    }

    /// Restore the document to a named version. This is an ordinary undoable
    /// edit (one transaction "restore version N"), so it stays on the linear
    /// undo/redo timeline rather than jumping the cursor non-linearly; the
    /// no-op rule makes restoring to the already-current state a no-op. Returns
    /// false if no such version exists. Mirrors Rust's `restore_version`.
    @discardableResult
    public func restoreVersion(_ name: String) -> Bool {
        guard let version = versionsStore.first(where: { $0.label == name }) else {
            return false
        }
        let doc = version.document
        withTxn {
            nameTxn("restore version \(name)")
            document = doc
        }
        return true
    }

    private func notify() {
        for listener in listeners {
            listener(document)
        }
    }
}
