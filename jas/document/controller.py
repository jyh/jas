"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from dataclasses import replace

from document.document import (
    Document, ElementPath, ElementSelection, Selection,
    SelectionKind, _SelectionAll, _SelectionPartial,
    selection_all, selection_partial,
)
from geometry.element import (
    Element, Group, Layer, Path,
    control_point_count, control_points, move_control_points,
    move_path_handle as _move_path_handle,
)
from geometry.hit_test import (
    element_intersects_rect, point_in_rect,
)
from document.model import Model


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

    def set_filename(self, filename: str) -> None:
        """Update the filename."""
        self._model.filename = filename

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
        """Append an element to the selected layer and select it."""
        doc = self._model.document
        idx = doc.selected_layer
        layer = doc.layers[idx]
        child_idx = len(layer.children)
        new_layer = replace(layer, children=layer.children + (element,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        es = ElementSelection.all((idx, child_idx))
        self._model.document = replace(doc, layers=new_layers,
                                       selection=frozenset({es}))

    @staticmethod
    def _toggle_selection(current: Selection, new: Selection) -> Selection:
        """XOR two selections per element.

        - Elements appearing in only one input pass through unchanged.
        - Two ``.all`` selections cancel out.
        - Two ``.partial`` selections XOR their CP sets; an empty result
          drops the element.
        - Mixed ``.all``/``.partial`` collapses to ``.all`` (preserving
          the pre-refactor behavior for this rare case).
        """
        current_by_path = {es.path: es for es in current}
        new_by_path = {es.path: es for es in new}
        result: set[ElementSelection] = set()
        # Elements only in current
        for path, es in current_by_path.items():
            if path not in new_by_path:
                result.add(es)
        # Elements only in new
        for path, es in new_by_path.items():
            if path not in current_by_path:
                result.add(es)
        # Elements in both: XOR.
        for path in current_by_path.keys() & new_by_path.keys():
            cur = current_by_path[path].kind
            nw = new_by_path[path].kind
            if isinstance(cur, _SelectionAll) and isinstance(nw, _SelectionAll):
                # Cancel out — element drops out of selection.
                continue
            if isinstance(cur, _SelectionPartial) and isinstance(nw, _SelectionPartial):
                xor = cur.cps.symmetric_difference(nw.cps)
                if xor:
                    result.add(ElementSelection(
                        path=path, kind=_SelectionPartial(xor)))
            else:
                # Mixed All/Partial — keep `.all`.
                result.add(ElementSelection.all(path))
        return frozenset(result)

    def select_rect(self, x: float, y: float, width: float, height: float,
                    *, extend: bool = False) -> None:
        """Select all elements whose bounds intersect the given rectangle.

        Group expansion: if any child of a Group intersects, all children
        of that Group are selected.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if child.locked:
                    continue
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(element_intersects_rect(gc, x, y, width, height)
                           for gc in child.children):
                        entries.append(ElementSelection.all((li, ci)))
                        for gi, gc in enumerate(child.children):
                            entries.append(ElementSelection.all((li, ci, gi)))
                else:
                    if element_intersects_rect(child, x, y, width, height):
                        entries.append(ElementSelection.all((li, ci)))
        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        self._model.document = replace(doc, selection=new_sel)

    def group_select_rect(self, x: float, y: float, width: float, height: float,
                          *, extend: bool = False) -> None:
        """Group selection marquee: selects individual elements with all
        control points.  Groups are traversed (not expanded) so elements
        inside groups can be individually selected.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []

        def _check(path: ElementPath, elem: Element) -> None:
            if elem.locked:
                return
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _check(path + (i,), child)
                return
            if element_intersects_rect(elem, x, y, width, height):
                entries.append(ElementSelection.all(path))

        for li, layer in enumerate(doc.layers):
            _check((li,), layer)

        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        self._model.document = replace(doc, selection=new_sel)

    def direct_select_rect(self, x: float, y: float, width: float, height: float,
                           *, extend: bool = False) -> None:
        """Direct selection marquee: select individual elements and only the
        control points that fall within the rectangle.  Groups are not
        expanded — elements inside groups can be individually selected.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []

        def _check(path: ElementPath, elem: Element) -> None:
            if elem.locked:
                return
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _check(path + (i,), child)
                return
            # Find which control points are inside the rect
            cps = control_points(elem)
            hit_cps = [
                i for i, (px, py) in enumerate(cps)
                if point_in_rect(px, py, x, y, width, height)
            ]
            if hit_cps:
                entries.append(ElementSelection.partial(path, hit_cps))
            elif element_intersects_rect(elem, x, y, width, height):
                # Marquee crosses the body but no CPs — pick the
                # element as a whole.
                entries.append(ElementSelection.all(path))

        for li, layer in enumerate(doc.layers):
            _check((li,), layer)

        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        self._model.document = replace(doc, selection=new_sel)

    def set_selection(self, selection: Selection) -> None:
        """Set the document selection directly."""
        self._model.document = replace(self._model.document, selection=selection)

    def select_element(self, path: ElementPath) -> None:
        """Select an element by path.

        If the element's immediate parent is a Group (not a Layer), all
        children of that Group are selected.  Otherwise just the single
        element is selected.  Locked elements cannot be selected.
        """
        if not path:
            raise ValueError("Path must be non-empty")
        doc = self._model.document
        elem = doc.get_element(path)
        if elem.locked:
            return
        if len(path) >= 2:
            parent_path = path[:-1]
            parent = doc.get_element(parent_path)
            if isinstance(parent, Group) and not isinstance(parent, Layer):
                entries = [ElementSelection.all(parent_path)]
                entries.extend(
                    ElementSelection.all(parent_path + (i,))
                    for i in range(len(parent.children))
                )
                self._model.document = replace(doc, selection=frozenset(entries))
                return
        self._model.document = replace(
            doc, selection=frozenset({ElementSelection.all(path)})
        )

    def select_control_point(self, path: ElementPath, index: int) -> None:
        """Select a single control point on an element.

        The given control-point index is marked as selected.
        """
        if not path:
            raise ValueError("Path must be non-empty")
        self._model.document = replace(
            self._model.document,
            selection=frozenset({ElementSelection.partial(path, [index])}),
        )

    def move_selection(self, dx: float, dy: float) -> None:
        """Move all selected control points by (dx, dy)."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = doc.get_element(es.path)
            new_elem = move_control_points(elem, es.kind, dx, dy)
            new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.document = new_doc

    def copy_selection(self, dx: float, dy: float) -> None:
        """Duplicate selected elements, offset by (dx, dy), leaving originals unchanged."""
        doc = self._model.document
        new_doc = doc
        new_selection: set[ElementSelection] = set()
        # Sort paths in reverse so insertions don't shift earlier paths
        sorted_sels = sorted(doc.selection, key=lambda es: es.path, reverse=True)
        for es in sorted_sels:
            elem = doc.get_element(es.path)
            copied = move_control_points(elem, es.kind, dx, dy)
            new_doc = new_doc.insert_element_after(es.path, copied)
            # The copy is at path with last index incremented by 1
            copy_path = es.path[:-1] + (es.path[-1] + 1,)
            # Copying always selects the new element as a whole.
            new_selection.add(ElementSelection.all(copy_path))
        self._model.document = replace(
            new_doc, selection=frozenset(new_selection))

    def lock_selection(self) -> None:
        """Lock all selected elements and clear the selection.

        When a Group is locked, all its children are locked recursively.
        """
        doc = self._model.document
        if not doc.selection:
            return

        def _lock(elem: Element) -> Element:
            if isinstance(elem, Group) and not isinstance(elem, Layer):
                new_children = tuple(_lock(c) for c in elem.children)
                return replace(elem, children=new_children, locked=True)
            return replace(elem, locked=True)

        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_doc = new_doc.replace_element(es.path, _lock(elem))
        self._model.document = replace(new_doc, selection=frozenset())

    def unlock_all(self) -> None:
        """Unlock all locked elements and select them."""
        from geometry.element import control_point_count
        doc = self._model.document
        unlocked_paths: list[tuple[ElementPath, Element]] = []

        def _collect_locked(path: ElementPath, elem: Element) -> None:
            if isinstance(elem, Group) and not isinstance(elem, Layer):
                if elem.locked:
                    unlocked_paths.append((path, elem))
                for i, child in enumerate(elem.children):
                    _collect_locked(path + (i,), child)
            elif elem.locked:
                unlocked_paths.append((path, elem))

        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                _collect_locked((li, ci), child)

        def _unlock(elem: Element) -> Element:
            if isinstance(elem, Group):
                new_children = tuple(_unlock(c) for c in elem.children)
                return replace(elem, children=new_children, locked=False)
            return replace(elem, locked=False)

        new_layers = tuple(
            replace(layer, children=tuple(_unlock(c) for c in layer.children))
            for layer in doc.layers
        )
        # Select all newly unlocked elements
        new_selection: set[ElementSelection] = set()
        new_doc = replace(doc, layers=new_layers)
        for path, _ in unlocked_paths:
            new_selection.add(ElementSelection.all(path))
        self._model.document = replace(new_doc, selection=frozenset(new_selection))

    def move_path_handle(self, path: ElementPath, anchor_idx: int,
                         handle_type: str, dx: float, dy: float) -> None:
        """Move a Bezier handle of a path element."""
        doc = self._model.document
        elem = doc.get_element(path)
        if isinstance(elem, Path):
            new_elem = _move_path_handle(elem, anchor_idx, handle_type, dx, dy)
            self._model.document = doc.replace_element(path, new_elem)
