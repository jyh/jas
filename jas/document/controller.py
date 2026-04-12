"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from collections.abc import Callable
from dataclasses import dataclass, replace

from document.document import (
    Document, ElementPath, ElementSelection, Selection,
    SelectionKind, _SelectionAll, _SelectionPartial,
    selection_all, selection_partial,
)
from geometry.element import (
    Element, Fill, Group, Layer, Path, Stroke, Visibility,
    control_point_count, control_points, move_control_points,
    move_path_handle as _move_path_handle,
    with_fill as _with_fill, with_stroke as _with_stroke,
    element_fill as _element_fill, element_stroke as _element_stroke,
)
from algorithms.hit_test import (
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
        - Two ``.all`` selections cancel out — this is the
          element-level deselect gesture (shift-click an already-fully-
          selected element).
        - Two ``.partial`` selections XOR their CP sets. If the result
          is empty the element stays selected as ``.partial(empty)`` —
          "element selected, no individual CPs highlighted" — rather
          than being dropped.
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
                # Keep the element even when the XOR is empty.
                xor = cur.cps.symmetric_difference(nw.cps)
                result.add(ElementSelection(
                    path=path, kind=_SelectionPartial(xor)))
            else:
                # Mixed All/Partial — keep `.all`.
                result.add(ElementSelection.all(path))
        return frozenset(result)

    # ------------------------------------------------------------------
    # Private helpers for selection
    # ------------------------------------------------------------------

    def _select_flat(self, predicate: Callable[[Element], bool],
                     *, extend: bool = False) -> None:
        """Flat 2-level selection with group expansion.

        Iterates layers and their direct children.  Groups that contain
        at least one hit are expanded (the group itself *and* every child
        are selected).  Parameterized by *predicate* which receives an
        element and returns whether it is hit.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []
        for li, layer in enumerate(doc.layers):
            if layer.visibility == Visibility.INVISIBLE:
                continue
            for ci, child in enumerate(layer.children):
                if child.locked:
                    continue
                child_vis = min(layer.visibility, child.visibility,
                                key=lambda v: v.value)
                if child_vis == Visibility.INVISIBLE:
                    continue
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(predicate(gc) for gc in child.children):
                        entries.append(ElementSelection.all((li, ci)))
                        for gi in range(len(child.children)):
                            entries.append(
                                ElementSelection.all((li, ci, gi)))
                elif predicate(child):
                    entries.append(ElementSelection.all((li, ci)))
        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        self._model.document = replace(doc, selection=new_sel)

    def _select_recursive(
        self,
        leaf_handler: Callable[
            [ElementPath, Element], ElementSelection | None],
        *, extend: bool = False,
    ) -> None:
        """Recursive selection traversal.

        Walks every layer/group tree.  When a leaf element (non-group,
        non-layer) is reached, *leaf_handler* is called with ``(path,
        element)`` and may return an :class:`ElementSelection` or
        ``None``.
        """
        doc = self._model.document
        entries: list[ElementSelection] = []

        def _walk(path: ElementPath, elem: Element,
                  ancestor_vis: Visibility) -> None:
            if elem.locked:
                return
            effective = min(ancestor_vis, elem.visibility,
                            key=lambda v: v.value)
            if effective == Visibility.INVISIBLE:
                return
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _walk(path + (i,), child, effective)
                return
            result = leaf_handler(path, elem)
            if result is not None:
                entries.append(result)

        for li, layer in enumerate(doc.layers):
            _walk((li,), layer, Visibility.PREVIEW)

        new_sel = frozenset(entries)
        if extend:
            new_sel = self._toggle_selection(doc.selection, new_sel)
        self._model.document = replace(doc, selection=new_sel)

    # ------------------------------------------------------------------
    # Public selection methods (thin wrappers)
    # ------------------------------------------------------------------

    def select_rect(self, x: float, y: float, width: float, height: float,
                    *, extend: bool = False) -> None:
        """Select all elements whose bounds intersect the given rectangle.

        Group expansion: if any child of a Group intersects, all children
        of that Group are selected.
        """
        self._select_flat(
            lambda elem: element_intersects_rect(elem, x, y, width, height),
            extend=extend,
        )

    def select_polygon(self, polygon: list[tuple[float, float]], *,
                       extend: bool = False) -> None:
        """Select all elements intersecting the given polygon."""
        from algorithms.hit_test import element_intersects_polygon
        self._select_flat(
            lambda elem: element_intersects_polygon(elem, polygon),
            extend=extend,
        )

    def group_select_rect(self, x: float, y: float, width: float, height: float,
                          *, extend: bool = False) -> None:
        """Group selection marquee: selects individual elements with all
        control points.  Groups are traversed (not expanded) so elements
        inside groups can be individually selected.
        """
        def _leaf(path: ElementPath, elem: Element) -> ElementSelection | None:
            if element_intersects_rect(elem, x, y, width, height):
                return ElementSelection.all(path)
            return None
        self._select_recursive(_leaf, extend=extend)

    def direct_select_rect(self, x: float, y: float, width: float, height: float,
                           *, extend: bool = False) -> None:
        """Direct selection marquee: select individual elements and only the
        control points that fall within the rectangle.  Groups are not
        expanded — elements inside groups can be individually selected.
        """
        def _leaf(path: ElementPath, elem: Element) -> ElementSelection | None:
            cps = control_points(elem)
            hit_cps = [
                i for i, (px, py) in enumerate(cps)
                if point_in_rect(px, py, x, y, width, height)
            ]
            if hit_cps:
                return ElementSelection.partial(path, hit_cps)
            if element_intersects_rect(elem, x, y, width, height):
                # Marquee crosses the body but no CPs. Select the
                # element with an empty CP set -- the Partial Selection
                # tool must not promote "body intersects" to "every CP
                # selected" (which is what `.all` would mean).
                return ElementSelection.partial(path, ())
            return None
        self._select_recursive(_leaf, extend=extend)

    def select_all(self) -> None:
        """Select all unlocked, visible elements."""
        self._select_flat(lambda _: True)

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
        if doc.effective_visibility(path) == Visibility.INVISIBLE:
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

    def hide_selection(self) -> None:
        """Set every element in the current selection to
        :class:`Visibility.INVISIBLE` and clear the selection.

        If an element is a Group or Layer, only the container's own
        flag is set — a parent's ``INVISIBLE`` caps every descendant,
        so the effect reaches the whole subtree without rewriting
        every node.
        """

        doc = self._model.document
        if not doc.selection:
            return
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            hidden = replace(elem, visibility=Visibility.INVISIBLE)
            new_doc = new_doc.replace_element(es.path, hidden)
        self._model.document = replace(new_doc, selection=frozenset())

    def show_all(self) -> None:
        """Traverse the document, set every element whose own
        visibility is :class:`Visibility.INVISIBLE` back to
        :class:`Visibility.PREVIEW`, and replace the current
        selection with exactly the paths that were shown.

        Elements that are effectively invisible only because an
        ancestor is invisible are *not* individually modified — it
        is the ancestor whose own flag is unset, and that cascades.
        """

        doc = self._model.document
        shown_paths: list[ElementPath] = []

        def _show(elem: Element, path: ElementPath) -> Element:
            new_elem = elem
            if elem.visibility == Visibility.INVISIBLE:
                new_elem = replace(new_elem, visibility=Visibility.PREVIEW)
                shown_paths.append(path)
            if isinstance(new_elem, (Group, Layer)):
                new_children = tuple(
                    _show(c, path + (i,))
                    for i, c in enumerate(new_elem.children)
                )
                new_elem = replace(new_elem, children=new_children)
            return new_elem

        new_layers = tuple(
            _show(layer, (li,)) for li, layer in enumerate(doc.layers)
        )
        new_selection = frozenset(
            ElementSelection.all(p) for p in shown_paths
        )
        self._model.document = replace(
            doc, layers=new_layers, selection=new_selection)

    def set_selection_fill(self, fill: Fill | None) -> None:
        """Set the fill of all selected elements."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_fill(elem, fill)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.document = new_doc

    def set_selection_stroke(self, stroke: Stroke | None) -> None:
        """Set the stroke of all selected elements."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = new_doc.get_element(es.path)
            new_elem = _with_stroke(elem, stroke)
            if new_elem is not elem:
                new_doc = new_doc.replace_element(es.path, new_elem)
        self._model.document = new_doc


# -- Fill/Stroke summary types --

@dataclass(frozen=True)
class FillSummaryNoSelection:
    """No elements are selected."""
    pass


@dataclass(frozen=True)
class FillSummaryUniform:
    """All selected elements have the same fill."""
    fill: Fill | None


@dataclass(frozen=True)
class FillSummaryMixed:
    """Selected elements have different fills."""
    pass


FillSummary = FillSummaryNoSelection | FillSummaryUniform | FillSummaryMixed


@dataclass(frozen=True)
class StrokeSummaryNoSelection:
    """No elements are selected."""
    pass


@dataclass(frozen=True)
class StrokeSummaryUniform:
    """All selected elements have the same stroke."""
    stroke: Stroke | None


@dataclass(frozen=True)
class StrokeSummaryMixed:
    """Selected elements have different strokes."""
    pass


StrokeSummary = StrokeSummaryNoSelection | StrokeSummaryUniform | StrokeSummaryMixed


def selection_fill_summary(doc: Document) -> FillSummary:
    """Compute the fill summary for the current selection."""
    if not doc.selection:
        return FillSummaryNoSelection()
    first = None
    first_set = False
    for es in doc.selection:
        fill = _element_fill(doc.get_element(es.path))
        if not first_set:
            first = fill
            first_set = True
        elif first != fill:
            return FillSummaryMixed()
    return FillSummaryUniform(fill=first)


def selection_stroke_summary(doc: Document) -> StrokeSummary:
    """Compute the stroke summary for the current selection."""
    if not doc.selection:
        return StrokeSummaryNoSelection()
    first = None
    first_set = False
    for es in doc.selection:
        stroke = _element_stroke(doc.get_element(es.path))
        if not first_set:
            first = stroke
            first_set = True
        elif first != stroke:
            return StrokeSummaryMixed()
    return StrokeSummaryUniform(stroke=first)
