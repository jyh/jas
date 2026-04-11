"""Observable model that holds the current document.

Views register callbacks via on_document_changed to be notified
whenever the document is replaced.
"""

from collections.abc import Callable

from document.document import Document
from geometry.element import Fill, RgbColor, Stroke

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
        self._saved_document = document
        self._filename = filename
        self._listeners: list[Callable[[Document], None]] = []
        self._filename_listeners: list[Callable[[str], None]] = []
        self._undo_stack: list[Document] = []
        self._redo_stack: list[Document] = []
        self.default_fill: Fill | None = None
        self.default_stroke: Stroke | None = Stroke(color=RgbColor(0, 0, 0))

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

    def undo(self) -> None:
        """Restore the previous document state."""
        if not self._undo_stack:
            return
        self._redo_stack.append(self._document)
        self._document = self._undo_stack.pop()
        self._notify()

    def redo(self) -> None:
        """Re-apply a previously undone document state."""
        if not self._redo_stack:
            return
        self._undo_stack.append(self._document)
        self._document = self._redo_stack.pop()
        self._notify()

    @property
    def is_modified(self) -> bool:
        return self._document is not self._saved_document

    def mark_saved(self) -> None:
        """Mark the current document as the saved version."""
        self._saved_document = self._document
        self._notify()

    @property
    def can_undo(self) -> bool:
        return len(self._undo_stack) > 0

    @property
    def can_redo(self) -> bool:
        return len(self._redo_stack) > 0

    def on_document_changed(self, callback: Callable[[Document], None]) -> None:
        """Register a callback invoked whenever the document changes."""
        self._listeners.append(callback)

    def on_filename_changed(self, callback: Callable[[str], None]) -> None:
        """Register a callback invoked whenever the filename changes."""
        self._filename_listeners.append(callback)

    def _notify(self) -> None:
        for listener in self._listeners:
            listener(self._document)
