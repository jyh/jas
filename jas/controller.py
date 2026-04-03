"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from dataclasses import replace

from document import Document
from element import Layer
from model import Model


class Controller:
    """Mediates between user actions and the document model."""

    def __init__(self, model: Model = None):
        self._model = model or Model()

    @property
    def model(self) -> Model:
        return self._model

    @property
    def document(self) -> Document:
        return self._model.document

    def set_document(self, document: Document) -> None:
        """Replace the entire document."""
        self._model.document = document

    def set_title(self, title: str) -> None:
        """Update the document title."""
        self._model.document = replace(self._model.document, title=title)

    def add_layer(self, layer: Layer) -> None:
        """Append a layer to the document."""
        self._model.document = replace(
            self._model.document,
            layers=self._model.document.layers + (layer,),
        )

    def remove_layer(self, index: int) -> None:
        """Remove the layer at the given index."""
        layers = list(self._model.document.layers)
        del layers[index]
        self._model.document = replace(
            self._model.document, layers=tuple(layers),
        )
