"""Observable model that holds the current document.

Views register callbacks via on_document_changed to be notified
whenever the document is replaced.
"""

from typing import Callable

from document.document import Document


class Model:
    """Holds an immutable Document and notifies listeners on change."""

    def __init__(self, document: Document = Document()):
        self._document = document
        self._listeners: list[Callable[[Document], None]] = []

    @property
    def document(self) -> Document:
        return self._document

    @document.setter
    def document(self, document: Document) -> None:
        self._document = document
        self._notify()

    def on_document_changed(self, callback: Callable[[Document], None]) -> None:
        """Register a callback invoked whenever the document changes."""
        self._listeners.append(callback)

    def _notify(self) -> None:
        for listener in self._listeners:
            listener(self._document)
