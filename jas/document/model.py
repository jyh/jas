"""Observable model that holds the current document.

Views register callbacks via on_document_changed to be notified
whenever the document is replaced.
"""

from typing import Callable

from document.document import Document

_MAX_UNDO = 100


class Model:
    """Holds an immutable Document and notifies listeners on change."""

    def __init__(self, document: Document = Document()):
        self._document = document
        self._listeners: list[Callable[[Document], None]] = []
        self._undo_stack: list[Document] = []
        self._redo_stack: list[Document] = []

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
    def can_undo(self) -> bool:
        return len(self._undo_stack) > 0

    @property
    def can_redo(self) -> bool:
        return len(self._redo_stack) > 0

    def on_document_changed(self, callback: Callable[[Document], None]) -> None:
        """Register a callback invoked whenever the document changes."""
        self._listeners.append(callback)

    def _notify(self) -> None:
        for listener in self._listeners:
            listener(self._document)
