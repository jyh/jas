"""Immutable document model.

A Document is an ordered list of Layers.

Elements within the document are identified by their path: a tuple of integer
indices tracing the route from the document's layer list to the element.
For example, path (0, 2) means layer 0, child 2.  Path (1,) means layer 1
itself.  This allows selections and updates without requiring element identity.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterable
from dataclasses import dataclass, field
from typing import TypeVar

from geometry.element import Element, Group, Layer

_G = TypeVar("_G", bound=Group)

# A path identifies an element by its position in the document tree.
# Each integer is a child index at that level of the tree.
# (0,) -> layers[0]  (a Layer)
# (0, 2) -> layers[0].children[2]
# (0, 2, 1) -> layers[0].children[2].children[1]  (inside a group)
ElementPath = tuple[int, ...]


@dataclass(frozen=True)
class SortedCps:
    """Sorted, de-duplicated tuple of control-point indices.

    Invariant: the backing tuple is sorted ascending and contains no
    duplicates. All constructors and operations preserve it, so callers
    can rely on deterministic iteration order.
    """
    _indices: tuple[int, ...] = ()

    @staticmethod
    def from_iter(it: Iterable[int]) -> "SortedCps":
        return SortedCps(tuple(sorted(set(int(i) for i in it))))

    @staticmethod
    def single(i: int) -> "SortedCps":
        return SortedCps((int(i),))

    def __contains__(self, i: int) -> bool:
        # Linear scan is fine for the small sets we deal with; the
        # invariant guarantees the result is the same as binary search.
        return int(i) in self._indices

    def __iter__(self):
        return iter(self._indices)

    def __len__(self) -> int:
        return len(self._indices)

    def __bool__(self) -> bool:
        return bool(self._indices)

    def insert(self, i: int) -> "SortedCps":
        """Return a new SortedCps with `i` added; no-op if already present."""
        if int(i) in self._indices:
            return self
        return SortedCps.from_iter(self._indices + (int(i),))

    def symmetric_difference(self, other: "SortedCps") -> "SortedCps":
        return SortedCps.from_iter(set(self._indices) ^ set(other._indices))


@dataclass(frozen=True)
class _SelectionAll:
    """Marker for `SelectionKind.ALL` — every CP of the element selected."""
    pass


@dataclass(frozen=True)
class _SelectionPartial:
    """Subset of CPs selected (Partial Selection)."""
    cps: SortedCps


# Sum type: either `.all` or `.partial(SortedCps)`. We use a tagged
# dataclass pair instead of a true Enum so SortedCps payloads are easy
# to construct and pattern-match with `isinstance` checks.
SelectionKind = _SelectionAll | _SelectionPartial


def selection_all() -> SelectionKind:
    """Return the singleton `.all` selection kind."""
    return _SelectionAll()


def selection_partial(cps: Iterable[int]) -> SelectionKind:
    """Return a `.partial(SortedCps)` selection kind from any iterable."""
    return _SelectionPartial(SortedCps.from_iter(cps))


def selection_kind_contains(kind: SelectionKind, i: int) -> bool:
    """True if CP index `i` is selected. `.all` contains every index."""
    if isinstance(kind, _SelectionAll):
        return True
    return int(i) in kind.cps


def selection_kind_count(kind: SelectionKind, total: int) -> int:
    """Number of selected CPs. The caller supplies `total` so `.all` can answer."""
    if isinstance(kind, _SelectionAll):
        return total
    return len(kind.cps)


def selection_kind_is_all(kind: SelectionKind, total: int) -> bool:
    """True when every CP of an element with `total` CPs is selected."""
    if isinstance(kind, _SelectionAll):
        return True
    return len(kind.cps) == total


def selection_kind_to_sorted(kind: SelectionKind, total: int) -> SortedCps:
    """Materialize an explicit SortedCps for an element with `total` CPs."""
    if isinstance(kind, _SelectionAll):
        return SortedCps.from_iter(range(total))
    return kind.cps


# Per-element selection state: either the element is fully selected
# (`.all`) or only a subset of its control points are selected
# (`.partial`).  Hash/equality is by path only so that a frozenset
# behaves as a path-keyed collection.
@dataclass(frozen=True, eq=False)
class ElementSelection:
    path: ElementPath
    kind: SelectionKind = field(default_factory=selection_all)

    @staticmethod
    def all(path: ElementPath) -> "ElementSelection":
        return ElementSelection(path=path, kind=selection_all())

    @staticmethod
    def partial(path: ElementPath, cps: Iterable[int]) -> "ElementSelection":
        return ElementSelection(path=path, kind=selection_partial(cps))

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, ElementSelection):
            return NotImplemented
        return self.path == other.path

    def __hash__(self) -> int:
        return hash(self.path)

# A selection is an immutable set of ElementSelection entries (unique by path).
Selection = frozenset[ElementSelection]


@dataclass(frozen=True)
class Document:
    """A document consisting of an ordered list of layers and a selection."""
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

    def bounds(self) -> tuple[float, float, float, float]:
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
        if path[0] < 0 or path[0] >= len(self.layers):
            raise ValueError(f"Layer index {path[0]} out of range (have {len(self.layers)} layers)")
        node: Element = self.layers[path[0]]
        for idx in path[1:]:
            if not isinstance(node, Group):
                raise ValueError(f"Expected Group at path, got {type(node).__name__}")
            if idx < 0 or idx >= len(node.children):
                raise ValueError(f"Child index {idx} out of range in path {path}")
            node = node.children[idx]
        return node

    def effective_visibility(self, path: ElementPath) -> "Visibility":
        """Return the effective visibility of the element at ``path``.

        Computed as the minimum of the visibilities of every element
        along the path from the root layer down to the target. A
        parent Group or Layer caps the visibility of everything it
        contains: if any ancestor is INVISIBLE, the result is
        INVISIBLE regardless of the target's own flag.
        """
        from geometry.element import Visibility
        if not path:
            return Visibility.PREVIEW
        if path[0] >= len(self.layers):
            return Visibility.PREVIEW
        node: Element = self.layers[path[0]]
        effective = node.visibility
        for idx in path[1:]:
            if not isinstance(node, Group):
                return effective
            if idx >= len(node.children):
                return effective
            node = node.children[idx]
            if node.visibility.value < effective.value:
                effective = node.visibility
        return effective

    def replace_element(self, path: ElementPath, new_elem: Element) -> "Document":
        """Return a new Document with the element at path replaced by new_elem."""
        if not path:
            raise ValueError("Path must be non-empty")
        new_layers = list(self.layers)
        if len(path) == 1:
            if not isinstance(new_elem, Layer):
                raise ValueError("Top-level element must be a Layer")
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
            if not isinstance(new_elem, Layer):
                raise ValueError("Top-level element must be a Layer")
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


def _expect_group(node: Element, context: str) -> Group:
    """Validate that node is a Group, raising ValueError if not."""
    if not isinstance(node, Group):
        raise ValueError(f"Expected Group {context}, got {type(node).__name__}")
    return node


def _remove_from_group(node: _G, rest: ElementPath) -> _G:
    """Remove the element at rest within a group."""
    new_children = list(node.children)
    if len(rest) == 1:
        del new_children[rest[0]]
    else:
        child = _expect_group(node.children[rest[0]], "in path")
        new_children[rest[0]] = _remove_from_group(child, rest[1:])
    return dataclasses.replace(node, children=tuple(new_children))


def _insert_after_in_group(node: _G, rest: ElementPath, new_elem: Element) -> _G:
    """Insert new_elem after the position indicated by rest within a group."""
    new_children = list(node.children)
    if len(rest) == 1:
        new_children.insert(rest[0] + 1, new_elem)
    else:
        child = _expect_group(node.children[rest[0]], "in path")
        new_children[rest[0]] = _insert_after_in_group(child, rest[1:], new_elem)
    return dataclasses.replace(node, children=tuple(new_children))


def _replace_in_group(node: _G, rest: ElementPath, new_elem: Element) -> _G:
    """Recursively replace the element at rest within a group, returning the same Group subtype."""
    new_children = list(node.children)
    if len(rest) == 1:
        new_children[rest[0]] = new_elem
    else:
        child = _expect_group(node.children[rest[0]], "in path")
        new_children[rest[0]] = _replace_in_group(child, rest[1:], new_elem)
    return dataclasses.replace(node, children=tuple(new_children))
