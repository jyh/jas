"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from dataclasses import replace

from document import Document, ElementPath, Selection
from element import Element, Group, Layer
from model import Model


def _bounds_intersect(
    a: tuple[float, float, float, float],
    b: tuple[float, float, float, float],
) -> bool:
    """Return True if two (x, y, width, height) bounding boxes overlap."""
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


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

    def add_element(self, element: Element) -> None:
        """Append an element to the selected layer."""
        doc = self._model.document
        idx = doc.selected_layer
        layer = doc.layers[idx]
        new_layer = replace(layer, children=layer.children + (element,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        self._model.document = replace(doc, layers=new_layers)

    def select_rect(self, x: float, y: float, width: float, height: float) -> None:
        """Select all elements whose bounds intersect the given rectangle.

        Group expansion: if any child of a Group intersects, all children
        of that Group are selected.
        """
        doc = self._model.document
        sel_rect = (x, y, width, height)
        selection: set[ElementPath] = set()
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(_bounds_intersect(gc.bounds(), sel_rect)
                           for gc in child.children):
                        for gi in range(len(child.children)):
                            selection.add((li, ci, gi))
                else:
                    if _bounds_intersect(child.bounds(), sel_rect):
                        selection.add((li, ci))
        self._model.document = replace(doc, selection=frozenset(selection))

    def set_selection(self, selection: Selection) -> None:
        """Set the document selection directly."""
        self._model.document = replace(self._model.document, selection=selection)

    def select_element(self, path: ElementPath) -> None:
        """Select an element by path.

        If the element's immediate parent is a Group (not a Layer), all
        children of that Group are selected.  Otherwise just the single
        element is selected.
        """
        if not path:
            raise ValueError("Path must be non-empty")
        doc = self._model.document
        if len(path) >= 2:
            parent_path = path[:-1]
            parent = doc.get_element(parent_path)
            if isinstance(parent, Group) and not isinstance(parent, Layer):
                selection: Selection = frozenset(
                    parent_path + (i,) for i in range(len(parent.children))
                )
                self._model.document = replace(doc, selection=selection)
                return
        self._model.document = replace(doc, selection=frozenset({path}))
