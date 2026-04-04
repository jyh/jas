"""Document controller (MVC pattern).

The Controller provides mutation operations on the Model's document.
Since the Document is immutable, mutations produce a new Document
that replaces the old one in the Model.
"""

from dataclasses import replace

from document import Document, ElementPath, Selection
from element import (
    Circle, Element, Ellipse, Group, Layer, Line, Path, Polygon, Polyline,
    Rect, Text,
    MoveTo, LineTo, CurveTo, SmoothCurveTo, QuadTo, SmoothQuadTo, ArcTo,
    ClosePath,
)
from model import Model


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
            segs: list[tuple[float, float, float, float]] = []
            cur_x, cur_y = 0.0, 0.0
            for cmd in cmds:
                match cmd:
                    case MoveTo(x=x, y=y):
                        cur_x, cur_y = x, y
                    case LineTo(x=x, y=y):
                        segs.append((cur_x, cur_y, x, y))
                        cur_x, cur_y = x, y
                    case CurveTo(x=x, y=y) | SmoothCurveTo(x=x, y=y) | \
                         QuadTo(x=x, y=y) | SmoothQuadTo(x=x, y=y):
                        segs.append((cur_x, cur_y, x, y))
                        cur_x, cur_y = x, y
                    case ArcTo(x=x, y=y):
                        segs.append((cur_x, cur_y, x, y))
                        cur_x, cur_y = x, y
                    case ClosePath():
                        pass
            return segs
        case _:
            return []


def _element_intersects_rect(elem: Element,
                             rx: float, ry: float, rw: float, rh: float) -> bool:
    """Test whether the visible drawn portion of elem intersects the selection rect."""
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
        selection: set[ElementPath] = set()
        for li, layer in enumerate(doc.layers):
            for ci, child in enumerate(layer.children):
                if isinstance(child, Group) and not isinstance(child, Layer):
                    if any(_element_intersects_rect(gc, x, y, width, height)
                           for gc in child.children):
                        for gi in range(len(child.children)):
                            selection.add((li, ci, gi))
                else:
                    if _element_intersects_rect(child, x, y, width, height):
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
