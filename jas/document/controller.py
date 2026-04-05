"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from dataclasses import replace

from document.document import Document, ElementPath, ElementSelection, Selection
from geometry.element import (
    Circle, Element, Ellipse, Group, Layer, Line, Path, Polygon, Polyline,
    Rect, Text,
    control_point_count, control_points, move_control_points,
    move_path_handle as _move_path_handle,
    _flatten_path_commands,
)
from document.model import Model


# ---------------------------------------------------------------------------
# Geometry helpers for precise hit-testing
# ---------------------------------------------------------------------------

def _point_in_rect(px: float, py: float,
                   rx: float, ry: float, rw: float, rh: float) -> bool:
    return rx <= px <= rx + rw and ry <= py <= ry + rh


def _cross(ox: float, oy: float, ax: float, ay: float,
           bx: float, by: float) -> float:
    return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)


def _on_segment(px1: float, py1: float, px2: float, py2: float,
                qx: float, qy: float) -> bool:
    return (min(px1, px2) <= qx <= max(px1, px2) and
            min(py1, py2) <= qy <= max(py1, py2))


def _segments_intersect(ax1: float, ay1: float, ax2: float, ay2: float,
                        bx1: float, by1: float, bx2: float, by2: float) -> bool:
    d1 = _cross(bx1, by1, bx2, by2, ax1, ay1)
    d2 = _cross(bx1, by1, bx2, by2, ax2, ay2)
    d3 = _cross(ax1, ay1, ax2, ay2, bx1, by1)
    d4 = _cross(ax1, ay1, ax2, ay2, bx2, by2)
    if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and \
       ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
        return True
    if d1 == 0 and _on_segment(bx1, by1, bx2, by2, ax1, ay1): return True
    if d2 == 0 and _on_segment(bx1, by1, bx2, by2, ax2, ay2): return True
    if d3 == 0 and _on_segment(ax1, ay1, ax2, ay2, bx1, by1): return True
    if d4 == 0 and _on_segment(ax1, ay1, ax2, ay2, bx2, by2): return True
    return False


def _segment_intersects_rect(x1: float, y1: float, x2: float, y2: float,
                             rx: float, ry: float, rw: float, rh: float) -> bool:
    if _point_in_rect(x1, y1, rx, ry, rw, rh):
        return True
    if _point_in_rect(x2, y2, rx, ry, rw, rh):
        return True
    edges = [
        (rx, ry, rx + rw, ry),
        (rx + rw, ry, rx + rw, ry + rh),
        (rx + rw, ry + rh, rx, ry + rh),
        (rx, ry + rh, rx, ry),
    ]
    return any(_segments_intersect(x1, y1, x2, y2, *e) for e in edges)


def _rects_intersect(ax: float, ay: float, aw: float, ah: float,
                     bx: float, by: float, bw: float, bh: float) -> bool:
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


def _circle_intersects_rect(cx: float, cy: float, r: float,
                            rx: float, ry: float, rw: float, rh: float,
                            filled: bool) -> bool:
    closest_x = max(rx, min(cx, rx + rw))
    closest_y = max(ry, min(cy, ry + rh))
    dist_sq = (cx - closest_x) ** 2 + (cy - closest_y) ** 2
    if not filled:
        # Stroke-only: the outline intersects if min_dist <= r <= max_dist
        corners = [(rx, ry), (rx + rw, ry), (rx + rw, ry + rh), (rx, ry + rh)]
        max_dist_sq = max((cx - cx2) ** 2 + (cy - cy2) ** 2 for cx2, cy2 in corners)
        return dist_sq <= r * r <= max_dist_sq
    return dist_sq <= r * r


def _ellipse_intersects_rect(cx: float, cy: float, erx: float, ery: float,
                             rx: float, ry: float, rw: float, rh: float,
                             filled: bool) -> bool:
    # Transform to unit circle space, then use circle test
    if erx == 0 or ery == 0:
        return False
    return _circle_intersects_rect(
        cx / erx, cy / ery, 1.0,
        rx / erx, ry / ery, rw / erx, rh / ery,
        filled,
    )


def _segments_of_element(elem: Element) -> list[tuple[float, float, float, float]]:
    """Return the line segments that make up the visible drawn edges of an element."""
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2):
            return [(x1, y1, x2, y2)]
        case Rect(x=x, y=y, width=w, height=h):
            return [(x, y, x+w, y), (x+w, y, x+w, y+h),
                    (x+w, y+h, x, y+h), (x, y+h, x, y)]
        case Polyline(points=pts):
            return [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)] if len(pts) >= 2 else []
        case Polygon(points=pts):
            if len(pts) < 2:
                return []
            segs = [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)]
            segs.append((pts[-1][0], pts[-1][1], pts[0][0], pts[0][1]))
            return segs
        case Path(d=cmds):
            # Flatten Bezier curves into a polyline for accurate hit-testing
            pts = _flatten_path_commands(cmds)
            return [(pts[i][0], pts[i][1], pts[i+1][0], pts[i+1][1])
                    for i in range(len(pts) - 1)] if len(pts) >= 2 else []
        case _:
            return []


def _all_cps(elem: Element) -> frozenset[int]:
    """Return a frozenset of all control point indices for an element."""
    return frozenset(range(control_point_count(elem)))


def _element_intersects_rect(elem: Element,
                             rx: float, ry: float, rw: float, rh: float) -> bool:
    """Test whether the visible drawn portion of elem intersects the selection rect.

    TODO: This ignores the element's transform. If an element has a non-identity
    transform, its visual position differs from its raw coordinates. To fix,
    inverse-transform the selection rect into the element's local coordinate
    space before testing (inheriting transforms from parent groups).
    """
    match elem:
        case Line():
            return _segment_intersects_rect(elem.x1, elem.y1, elem.x2, elem.y2,
                                            rx, ry, rw, rh)
        case Rect():
            if elem.fill is not None:
                return _rects_intersect(elem.x, elem.y, elem.width, elem.height,
                                        rx, ry, rw, rh)
            return any(_segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in _segments_of_element(elem))

        case Circle():
            return _circle_intersects_rect(elem.cx, elem.cy, elem.r,
                                           rx, ry, rw, rh,
                                           elem.fill is not None)
        case Ellipse():
            return _ellipse_intersects_rect(elem.cx, elem.cy, elem.rx, elem.ry,
                                            rx, ry, rw, rh,
                                            elem.fill is not None)
        case Polyline():
            if elem.fill is not None:
                # TODO: Uses bounding-box approximation. For concave shapes,
                # this over-selects in the concave region. Should use
                # point-in-polygon (ray casting) to test rect corners.
                return _rects_intersect(*elem.bounds(), rx, ry, rw, rh)
            return any(_segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in _segments_of_element(elem))

        case Polygon():
            if elem.fill is not None:
                # Check if any vertex is in rect, any rect corner in polygon, or edges cross
                pts = elem.points
                if any(_point_in_rect(px, py, rx, ry, rw, rh) for px, py in pts):
                    return True
                return any(_segment_intersects_rect(*seg, rx, ry, rw, rh)
                           for seg in _segments_of_element(elem))
            return any(_segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in _segments_of_element(elem))

        case Path():
            if elem.fill is not None:
                segs = _segments_of_element(elem)
                endpoints = [(s[0], s[1]) for s in segs] + [(s[2], s[3]) for s in segs]
                if any(_point_in_rect(px, py, rx, ry, rw, rh) for px, py in endpoints):
                    return True
                return any(_segment_intersects_rect(*seg, rx, ry, rw, rh) for seg in segs)
            return any(_segment_intersects_rect(*seg, rx, ry, rw, rh)
                       for seg in _segments_of_element(elem))

        case Text():
            return _rects_intersect(*elem.bounds(), rx, ry, rw, rh)

        case _:
            return _rects_intersect(*elem.bounds(), rx, ry, rw, rh)


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
        """Append an element to the selected layer."""
        doc = self._model.document
        idx = doc.selected_layer
        layer = doc.layers[idx]
        new_layer = replace(layer, children=layer.children + (element,))
        new_layers = doc.layers[:idx] + (new_layer,) + doc.layers[idx + 1:]
        self._model.document = replace(doc, layers=new_layers)

    @staticmethod
    def _toggle_selection(current: Selection, new: Selection) -> Selection:
        """Toggle at the control-point level.

        For elements only in one set, keep them as-is.
        For elements in both sets, toggle individual control points
        (symmetric difference).  If no CPs remain, remove the element.
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
        # Elements in both: toggle CPs
        for path in current_by_path.keys() & new_by_path.keys():
            cur = current_by_path[path]
            nw = new_by_path[path]
            toggled_cps = cur.control_points ^ nw.control_points
            if toggled_cps:
                result.add(ElementSelection(path=path, control_points=toggled_cps))
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
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(_element_intersects_rect(gc, x, y, width, height)
                           for gc in child.children):
                        for gi, gc in enumerate(child.children):
                            entries.append(ElementSelection(
                                path=(li, ci, gi),
                                control_points=_all_cps(gc)))
                else:
                    if _element_intersects_rect(child, x, y, width, height):
                        entries.append(ElementSelection(
                            path=(li, ci),
                            control_points=_all_cps(child)))
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
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _check(path + (i,), child)
                return
            if _element_intersects_rect(elem, x, y, width, height):
                entries.append(ElementSelection(
                    path=path,
                    control_points=_all_cps(elem)))

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
            if isinstance(elem, (Group, Layer)):
                for i, child in enumerate(elem.children):
                    _check(path + (i,), child)
                return
            # Find which control points are inside the rect
            cps = control_points(elem)
            hit_cps = frozenset(
                i for i, (px, py) in enumerate(cps)
                if _point_in_rect(px, py, x, y, width, height)
            )
            if hit_cps or _element_intersects_rect(elem, x, y, width, height):
                entries.append(ElementSelection(
                    path=path,
                    control_points=hit_cps))

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
                    ElementSelection(path=parent_path + (i,),
                                     control_points=_all_cps(parent.children[i]))
                    for i in range(len(parent.children))
                )
                self._model.document = replace(doc, selection=selection)
                return
        elem = doc.get_element(path)
        self._model.document = replace(
            doc, selection=frozenset({ElementSelection(path=path,
                                                       control_points=_all_cps(elem))})
        )

    def select_control_point(self, path: ElementPath, index: int) -> None:
        """Select a single control point on an element.

        The given control-point index is marked as selected.
        """
        if not path:
            raise ValueError("Path must be non-empty")
        self._model.document = replace(
            self._model.document,
            selection=frozenset({
                ElementSelection(path=path,
                                 control_points=frozenset({index}))
            }),
        )

    def move_selection(self, dx: float, dy: float) -> None:
        """Move all selected control points by (dx, dy)."""
        doc = self._model.document
        new_doc = doc
        for es in doc.selection:
            elem = doc.get_element(es.path)
            new_elem = move_control_points(elem, es.control_points, dx, dy)
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
            copied = move_control_points(elem, es.control_points, dx, dy)
            new_doc = new_doc.insert_element_after(es.path, copied)
            # The copy is at path with last index incremented by 1
            copy_path = es.path[:-1] + (es.path[-1] + 1,)
            all_cps = frozenset(range(control_point_count(copied)))
            new_selection.add(ElementSelection(path=copy_path,
                                               control_points=all_cps))
        self._model.document = replace(
            new_doc, selection=frozenset(new_selection))

    def move_path_handle(self, path: ElementPath, anchor_idx: int,
                         handle_type: str, dx: float, dy: float) -> None:
        """Move a Bezier handle of a path element."""
        doc = self._model.document
        elem = doc.get_element(path)
        if isinstance(elem, Path):
            new_elem = _move_path_handle(elem, anchor_idx, handle_type, dx, dy)
            self._model.document = doc.replace_element(path, new_elem)
