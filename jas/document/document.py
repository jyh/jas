"""Immutable document model.

A Document is an ordered list of Layers.

Elements within the document are identified by their path: a tuple of integer
indices tracing the route from the document's layer list to the element.
For example, path (0, 2) means layer 0, child 2.  Path (1,) means layer 1
itself.  This allows selections and updates without requiring element identity.
"""

import dataclasses
from dataclasses import dataclass
from typing import Tuple, TypeVar

from geometry.element import Element, Group, Layer

_G = TypeVar("_G", bound=Group)

# A path identifies an element by its position in the document tree.
# Each integer is a child index at that level of the tree.
# (0,) -> layers[0]  (a Layer)
# (0, 2) -> layers[0].children[2]
# (0, 2, 1) -> layers[0].children[2].children[1]  (inside a group)
ElementPath = tuple[int, ...]

# Per-element selection state: which element and which of its control points
# are selected.
@dataclass(frozen=True)
class ElementSelection:
    path: ElementPath
    control_points: frozenset[int] = frozenset()

# A selection is an immutable set of ElementSelection entries (unique by path).
Selection = frozenset[ElementSelection]


@dataclass(frozen=True)
class Document:
    """A document consisting of a title, an ordered list of layers, and a selection."""
    title: str = "Untitled"
    layers: tuple[Layer, ...] = (Layer(),)
    selected_layer: int = 0
    selection: Selection = frozenset()

    def get_element_selection(self, path: ElementPath) -> ElementSelection | None:
        """Return the ElementSelection for the given path, or None."""
        for es in self.selection:
            if es.path == path:
                return es
        return None

    def selected_paths(self) -> frozenset[ElementPath]:
        """Return the set of all element paths in the selection."""
        return frozenset(es.path for es in self.selection)

    def bounds(self) -> Tuple[float, float, float, float]:
        """Return the bounding box of all layers combined."""
        if not self.layers:
            return (0, 0, 0, 0)
        all_bounds = [layer.bounds() for layer in self.layers]
        min_x = min(b[0] for b in all_bounds)
        min_y = min(b[1] for b in all_bounds)
        max_x = max(b[0] + b[2] for b in all_bounds)
        max_y = max(b[1] + b[3] for b in all_bounds)
        return (min_x, min_y, max_x - min_x, max_y - min_y)

    def get_element(self, path: ElementPath) -> Element:
        """Return the element at the given path."""
        if not path:
            raise ValueError("Path must be non-empty")
        node: Element = self.layers[path[0]]
        for idx in path[1:]:
            assert isinstance(node, Group)
            node = node.children[idx]
        return node

    def replace_element(self, path: ElementPath, new_elem: Element) -> "Document":
        """Return a new Document with the element at path replaced by new_elem."""
        if not path:
            raise ValueError("Path must be non-empty")
        new_layers = list(self.layers)
        if len(path) == 1:
            assert isinstance(new_elem, Layer)
            new_layers[path[0]] = new_elem
        else:
            new_layers[path[0]] = _replace_in_group(self.layers[path[0]], path[1:], new_elem)
        return dataclasses.replace(self, layers=tuple(new_layers))


    def insert_element_after(self, path: ElementPath, new_elem: Element) -> "Document":
        """Return a new Document with new_elem inserted immediately after path."""
        if not path:
            raise ValueError("Path must be non-empty")
        if len(path) == 1:
            new_layers = list(self.layers)
            assert isinstance(new_elem, Layer)
            new_layers.insert(path[0] + 1, new_elem)
            return dataclasses.replace(self, layers=tuple(new_layers))
        new_layers = list(self.layers)
        new_layers[path[0]] = _insert_after_in_group(
            self.layers[path[0]], path[1:], new_elem)
        return dataclasses.replace(self, layers=tuple(new_layers))


    def delete_element(self, path: ElementPath) -> "Document":
        """Return a new Document with the element at path removed."""
        if not path:
            raise ValueError("Path must be non-empty")
        new_layers = list(self.layers)
        if len(path) == 1:
            del new_layers[path[0]]
        else:
            new_layers[path[0]] = _remove_from_group(self.layers[path[0]], path[1:])
        return dataclasses.replace(self, layers=tuple(new_layers))

    def delete_selection(self) -> "Document":
        """Return a new Document with all selected elements removed and selection cleared."""
        doc = self
        # Sort paths in reverse so deletions don't shift earlier paths
        paths = sorted((es.path for es in self.selection), reverse=True)
        for path in paths:
            doc = doc.delete_element(path)
        return dataclasses.replace(doc, selection=frozenset())


def _remove_from_group(node: _G, rest: ElementPath) -> _G:
    """Remove the element at rest within a group."""
    new_children = list(node.children)
    if len(rest) == 1:
        del new_children[rest[0]]
    else:
        child = node.children[rest[0]]
        assert isinstance(child, Group)
        new_children[rest[0]] = _remove_from_group(child, rest[1:])
    return dataclasses.replace(node, children=tuple(new_children))


def _insert_after_in_group(node: _G, rest: ElementPath, new_elem: Element) -> _G:
    """Insert new_elem after the position indicated by rest within a group."""
    new_children = list(node.children)
    if len(rest) == 1:
        new_children.insert(rest[0] + 1, new_elem)
    else:
        child = node.children[rest[0]]
        assert isinstance(child, Group)
        new_children[rest[0]] = _insert_after_in_group(child, rest[1:], new_elem)
    return dataclasses.replace(node, children=tuple(new_children))


def _replace_in_group(node: _G, rest: ElementPath, new_elem: Element) -> _G:
    """Recursively replace the element at rest within a group, returning the same Group subtype."""
    new_children = list(node.children)
    if len(rest) == 1:
        new_children[rest[0]] = new_elem
    else:
        child = node.children[rest[0]]
        assert isinstance(child, Group)
        new_children[rest[0]] = _replace_in_group(child, rest[1:], new_elem)
    return dataclasses.replace(node, children=tuple(new_children))
