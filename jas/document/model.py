"""Observable model that holds the current document.

Views register callbacks via on_document_changed to be notified
whenever the document is replaced.
"""

from collections.abc import Callable
from dataclasses import dataclass, field

from document.document import Document
from document.op_log import ACTOR_ARTIST, PrimitiveOp, Transaction
from geometry.element import Fill, RgbColor, Stroke
# OP_LOG.md Increment 2: the canonical "net document change is byte-identical"
# comparison for the commit no-op rule (the same canonicalization the
# cross-language gate uses).
from geometry.test_json import document_to_test_json


@dataclass
class _PendingTxn:
    """The transaction being accumulated between begin_txn and commit_txn."""
    name: str | None = None
    ops: list[PrimitiveOp] = field(default_factory=list)
    doc_at_begin: Document | None = None


@dataclass
class Version:
    """A named version point (OP_LOG.md Increment 3a / VISION.md §6.9). Stores
    the document at a labeled journal cursor position so ``restore_version`` is
    O(1) and sound regardless of whether the intervening transactions carry
    replayable ops. Mirrors ``Version`` in ``jas_dioxus`` (without the paired
    id_index, which this app does not maintain on the Model)."""
    label: str
    journal_head: int
    document: Document


@dataclass(frozen=True)
class EditingTarget:
    """The target that drawing tools operate on. The default is the
    document's normal content; mask-editing mode switches the
    target to a specific element's mask subtree so new shapes land
    inside ``element.mask.subtree`` instead of the selected layer.

    ``mask_path is None`` means content-editing mode (the default);
    a tuple-of-ints ``mask_path`` identifies the masked element
    whose subtree is the drawing target.

    Mirrors ``EditingTarget`` in ``jas_dioxus`` / ``JasSwift`` /
    ``jas_ocaml``. OPACITY.md §Preview interactions.
    """
    mask_path: tuple[int, ...] | None = None

    @staticmethod
    def content() -> "EditingTarget":
        """The default editing target — the document's normal content."""
        return EditingTarget(mask_path=None)

    @staticmethod
    def mask(path: tuple[int, ...] | list[int]) -> "EditingTarget":
        """Mask-editing mode: ``path`` identifies the masked element."""
        return EditingTarget(mask_path=tuple(path))

    @property
    def is_mask(self) -> bool:
        return self.mask_path is not None

_MAX_UNDO = 100
_next_untitled = 1


def _fresh_filename() -> str:
    global _next_untitled
    name = f"Untitled-{_next_untitled}"
    _next_untitled += 1
    return name


class Model:
    """Holds an immutable Document and notifies listeners on change."""

    def __init__(self, document: Document = Document(),
                 filename: str | None = None):
        if filename is None:
            filename = _fresh_filename()
        self._document = document
        self._filename = filename
        self._listeners: list[Callable[[Document], None]] = []
        self._filename_listeners: list[Callable[[str], None]] = []
        self._undo_stack: list[Document] = []
        self._redo_stack: list[Document] = []
        # OP_LOG.md Increment 2: the journal-head cursor. An uncapped count of
        # undoable edits applied (snapshot increments it, undo/redo move it),
        # so is_modified is journal_head != saved_journal_head — undo back to the
        # saved point reads as not-modified. Replaces the old identity compare
        # against a saved-document reference. (Cursor-only port: tied to the
        # existing snapshot/undo/redo mechanism, not a transaction bracket.)
        self._journal_head: int = 0
        self._saved_journal_head: int = 0
        # OP_LOG.md Increment 2 (full journal): the typed Transaction journal
        # layered on the snapshot stacks. Built via begin_txn/commit_txn/record_op
        # (the op_apply / harness path); production snapshot() edits advance the
        # journal_head cursor but record no Transaction (opaque). See op_log.py.
        self._op_journal: list[Transaction] = []
        self._pending_txn: _PendingTxn | None = None
        self._in_txn: bool = False
        self._next_txn_counter: int = 0
        # OP_LOG.md Increment 3a: named version points (VISION.md §6.9). Each
        # labels a journal cursor position and stores the document at that
        # point, so restore_version is O(1) and sound even though production
        # transactions are opaque (no op replay needed). The label is also
        # written onto the journal's transaction at that head (the `label`
        # field reserved in Increment 2) so it serializes into the journal
        # artifact.
        self._versions: list[Version] = []
        self.default_fill: Fill | None = None
        self.default_stroke: Stroke | None = Stroke(color=RgbColor(0, 0, 0))
        self.fill_on_top: bool = True
        self.recent_colors: list[str] = []
        # Live reference to the active in-place text-editing session,
        # if any. TypeTool / TypeOnPathTool publish their session here
        # while editing so the Character-panel pipeline can reach it.
        # Cleared when the session ends. Type is
        # ``tools.text_edit.TextEditSession | None`` but we avoid the
        # import at module top to keep document/ free of tools/
        # dependencies.
        self.current_edit_session = None
        # Mask-editing mode state. Defaults to content-mode; flipped
        # to mask-mode when the user clicks the Opacity panel's
        # MASK_PREVIEW with a masked selection.
        # OPACITY.md §Preview interactions.
        self.editing_target: EditingTarget = EditingTarget.content()
        # Mask-isolation path. When non-None, the canvas renders
        # only the mask subtree of the element at this path,
        # hiding everything else. Entered by Alt/Option-clicking
        # MASK_PREVIEW; exited by Alt-clicking again.
        # OPACITY.md §Preview interactions.
        self.mask_isolation_path: tuple[int, ...] | None = None
        # Per-document view state (per ZOOM_TOOL.md §State persistence).
        # Persists across tab switches within a session; reset to
        # defaults on document open. Not serialized to disk in Phase 1.
        self.zoom_level: float = 1.0
        self.view_offset_x: float = 0.0
        self.view_offset_y: float = 0.0
        # Canvas viewport dimensions in screen-space pixels. Updated
        # by the canvas widget on layout / resize. Read by
        # doc.zoom.fit_* effects to compute the new zoom factor.
        # Defaults match workspace/layout.yaml canvas_pane
        # default_position.
        self.viewport_w: float = 888.0
        self.viewport_h: float = 900.0
        # Center the canvas view on the current artboard at
        # construction time using the default viewport. The first
        # canvas paint with the real viewport will re-center.
        self.center_view_on_current_artboard()

    def center_view_on_current_artboard(self) -> None:
        """Center the canvas view on the current artboard using the
        stored ``viewport_w`` / ``viewport_h``. If the artboard
        fits at the current zoom, set pan to center it; otherwise
        apply fit-inside semantics with 20px screen-space padding.
        Per ZOOM_TOOL.md §Document-open behavior.
        """
        artboards = list(self._document.artboards)
        if not artboards or self.viewport_w <= 0 or self.viewport_h <= 0:
            return
        ab = artboards[0]
        ab_w = float(ab.width)
        ab_h = float(ab.height)
        ab_x = float(ab.x)
        ab_y = float(ab.y)
        fits = (ab_w * self.zoom_level <= self.viewport_w
                and ab_h * self.zoom_level <= self.viewport_h)
        if fits:
            self.view_offset_x = (
                self.viewport_w / 2.0 - (ab_x + ab_w / 2.0) * self.zoom_level)
            self.view_offset_y = (
                self.viewport_h / 2.0 - (ab_y + ab_h / 2.0) * self.zoom_level)
        else:
            pad = 20.0
            avail_w = self.viewport_w - 2.0 * pad
            avail_h = self.viewport_h - 2.0 * pad
            if avail_w > 0 and avail_h > 0:
                z_fit = min(avail_w / ab_w, avail_h / ab_h)
                z_clamped = max(0.1, min(64.0, z_fit))
                self.zoom_level = z_clamped
                self.view_offset_x = (
                    self.viewport_w / 2.0 - (ab_x + ab_w / 2.0) * z_clamped)
                self.view_offset_y = (
                    self.viewport_h / 2.0 - (ab_y + ab_h / 2.0) * z_clamped)

    @property
    def filename(self) -> str:
        return self._filename

    @filename.setter
    def filename(self, filename: str) -> None:
        self._filename = filename
        for listener in self._filename_listeners:
            listener(filename)

    @property
    def document(self) -> Document:
        return self._document

    @document.setter
    def document(self, document: Document) -> None:
        self._document = document
        self._notify()

    def snapshot(self) -> None:
        """Save the current document state for undo."""
        self._undo_stack.append(self._document)
        if len(self._undo_stack) > _MAX_UNDO:
            self._undo_stack.pop(0)
        self._redo_stack.clear()
        # Advance the journal cursor: one undoable edit (OP_LOG.md §5). The
        # counter is uncapped, unlike the MAX_UNDO-capped stack, so is_modified
        # stays correct past the cap.
        self._journal_head += 1

    # ── Preview snapshot (dialog Preview flows) ────────────────
    # Out-of-band snapshot used by the Scale / Rotate / Shear
    # Options dialogs. Captured at dialog open, restored on
    # Cancel, cleared on OK. Distinct from _undo_stack so
    # preview-driven applies do not pollute undo history.
    # See SCALE_TOOL.md §Preview.

    def capture_preview_snapshot(self) -> None:
        self._preview_doc_snapshot: Document | None = self._document

    def restore_preview_snapshot(self) -> None:
        snap = getattr(self, "_preview_doc_snapshot", None)
        if snap is not None:
            self._document = snap
            self._notify()

    def clear_preview_snapshot(self) -> None:
        self._preview_doc_snapshot = None

    @property
    def has_preview_snapshot(self) -> bool:
        return getattr(self, "_preview_doc_snapshot", None) is not None

    def undo(self) -> None:
        """Restore the previous document state."""
        if not self._undo_stack:
            return
        self._redo_stack.append(self._document)
        self._document = self._undo_stack.pop()
        if self._journal_head > 0:
            self._journal_head -= 1
        self._notify()

    def redo(self) -> None:
        """Re-apply a previously undone document state."""
        if not self._redo_stack:
            return
        self._undo_stack.append(self._document)
        self._document = self._redo_stack.pop()
        self._journal_head += 1
        self._notify()

    @property
    def is_modified(self) -> bool:
        # OP_LOG.md §9 unified semantics: the journal-head cursor, so undo back
        # to the saved point reads as not-modified (and a non-undoable write
        # that does not snapshot does not mark the document modified).
        return self._journal_head != self._saved_journal_head

    def mark_saved(self) -> None:
        """Mark the current journal cursor as the saved version."""
        self._saved_journal_head = self._journal_head
        self._notify()

    @property
    def can_undo(self) -> bool:
        return len(self._undo_stack) > 0

    @property
    def can_redo(self) -> bool:
        return len(self._redo_stack) > 0

    # ── Transaction journal (OP_LOG.md Increment 2, full journal) ──────────
    #
    # begin_txn / commit_txn build the typed Transaction journal (the op_apply /
    # harness path). They sit alongside snapshot() (the production undoable-edit
    # boundary, which advances the journal_head cursor but records no
    # Transaction). Both advance journal_head; a given flow uses one path or the
    # other. record_op / name_txn populate the open transaction.

    @property
    def journal(self) -> list[Transaction]:
        return self._op_journal

    @property
    def journal_head(self) -> int:
        return self._journal_head

    @property
    def in_txn(self) -> bool:
        """True while a transaction is open (between begin_txn and
        commit_txn/abort_txn). Read by ``op_apply``'s lazy begin_txn so a bare
        drag frame opens (and the batch owner commits) exactly one transaction
        (OP_LOG.md §9, Increment 3b-B)."""
        return self._in_txn

    def begin_txn(self) -> None:
        """Open an undoable transaction: push the pre-edit checkpoint (no
        redo-clear — that moves to commit_txn). Idempotent while already open."""
        if self._in_txn:
            return
        self._undo_stack.append(self._document)
        if len(self._undo_stack) > _MAX_UNDO:
            self._undo_stack.pop(0)
        self._in_txn = True
        self._pending_txn = _PendingTxn(doc_at_begin=self._document)

    def commit_txn(self) -> None:
        """Finalize the open transaction. No-op rule (OP_LOG.md §5/§9): a
        zero-net-change transaction is not journaled and its undo checkpoint is
        dropped. Otherwise append one Transaction (deterministic txn-N id),
        truncating the journal's redo tail at journal_head, and clear redo."""
        if not self._in_txn:
            return
        self._in_txn = False
        pending = self._pending_txn
        self._pending_txn = None
        checkpoint = self._undo_stack[-1] if self._undo_stack else None
        # No-op rule + P6 hardening (OP_LOG.md §9): a transaction whose net
        # document change is byte-identical is dropped. The canonical
        # document_to_test_json OMITS Path brush fields (stroke_brush /
        # stroke_brush_overrides), so a brush-only edit (set_attr_on_selection)
        # would FALSELY read as a no-op under the JSON compare alone. AND a
        # structural layers/symbols object compare onto the JSON compare so a
        # brush-only edit is correctly journaled. Mirrors the Rust commit_txn.
        no_net_change = checkpoint is not None and (
            self._document is checkpoint
            or (
                document_to_test_json(self._document)
                == document_to_test_json(checkpoint)
                and self._document.layers == checkpoint.layers
                and self._document.symbols == checkpoint.symbols
            )
        )
        if no_net_change:
            if self._undo_stack:
                self._undo_stack.pop()
            return
        self._redo_stack.clear()
        del self._op_journal[self._journal_head:]
        parent = self._op_journal[-1].txn_id if self._op_journal else None
        self._op_journal.append(Transaction(
            txn_id=f"txn-{self._next_txn_counter}",
            ops=list(pending.ops) if pending else [],
            name=pending.name if pending else None,
            actor=ACTOR_ARTIST,
            parent=parent,
            lamport=self._next_txn_counter,
        ))
        self._next_txn_counter += 1
        self._journal_head = len(self._op_journal)

    def abort_txn(self) -> None:
        """Roll back the open transaction to its checkpoint, discarding it (no
        redo entry, no journal entry, no cursor move)."""
        if not self._in_txn:
            return
        self._in_txn = False
        self._pending_txn = None
        if self._undo_stack:
            self._document = self._undo_stack.pop()
            self._notify()

    def with_txn(self, body: Callable[[], None]) -> None:
        """Scoped bracket: begin_txn, run body, commit_txn."""
        self.begin_txn()
        body()
        self.commit_txn()

    def record_op(self, op: PrimitiveOp) -> None:
        """Append a primitive op to the open transaction (no-op when none open)."""
        if self._pending_txn is not None:
            self._pending_txn.ops.append(op)

    def name_txn(self, name: str) -> None:
        """Set the open transaction's legible name (no-op when none open)."""
        if self._pending_txn is not None:
            self._pending_txn.name = name

    # ── Versioning labels (OP_LOG.md Increment 3a / VISION.md §6.9) ─────────

    @property
    def versions(self) -> list[Version]:
        """The named version points, in creation order. Test/inspection."""
        return self._versions

    def label_version(self, name: str) -> None:
        """Mark the current document state as a named version point. Stores the
        document (so restore_version is O(1) and sound even though production
        transactions are opaque) and writes ``label`` onto the journal's
        transaction at the current head (the field reserved in Increment 2), so
        the label serializes into the journal artifact. Naming is idempotent:
        re-labeling an existing name re-points it here."""
        # Stamp the label onto the most-recent committed transaction, if any
        # (a version at the origin labels no transaction).
        if self._journal_head > 0 and self._journal_head <= len(self._op_journal):
            self._op_journal[self._journal_head - 1].label = name
        version = Version(
            label=name,
            journal_head=self._journal_head,
            document=self._document,
        )
        for i, existing in enumerate(self._versions):
            if existing.label == name:
                self._versions[i] = version
                return
        self._versions.append(version)

    def restore_version(self, name: str) -> bool:
        """Restore the document to a named version. This is an ordinary
        undoable edit (one transaction "restore version N"), so it stays on the
        linear undo/redo timeline rather than jumping the cursor non-linearly;
        the no-op rule makes restoring to the already-current state a no-op.
        Returns False if no such version exists."""
        version = next(
            (v for v in self._versions if v.label == name), None)
        if version is None:
            return False
        doc = version.document

        def body() -> None:
            self.name_txn(f"restore version {name}")
            self.document = doc

        self.with_txn(body)
        return True

    def on_document_changed(self, callback: Callable[[Document], None]) -> None:
        """Register a callback invoked whenever the document changes."""
        self._listeners.append(callback)

    def on_filename_changed(self, callback: Callable[[str], None]) -> None:
        """Register a callback invoked whenever the filename changes."""
        self._filename_listeners.append(callback)

    def _notify(self) -> None:
        for listener in self._listeners:
            listener(self._document)
