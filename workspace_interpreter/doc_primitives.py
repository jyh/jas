"""Document-aware evaluator primitives.

``hit_test`` / ``hit_test_deep`` / ``selection_contains`` /
``selection_empty`` need access to the current Document while
expressions are being evaluated. ``YamlTool``'s dispatch handler
calls :func:`register_document` before running a handler's effects;
the returned guard's ``restore`` method reinstates the prior
document (typically at the end of the dispatch block).

Returns plain Python types (``list | None`` for paths, ``bool``
for selection checks) so ``expr_eval`` can wrap them as
:class:`Value`\\s without importing this module at the top. GTK/
Qt apps run single-threaded, so the module-local ``_current``
ref plays the role of Rust's thread-local.
"""

from __future__ import annotations

from typing import Callable


# Module-local slot for the current Document. None means no document
# is registered; hit_test and friends return their "miss" values.
_current = None


class DocGuard:
    """Registration handle returned by :func:`register_document`.

    Call ``guard.restore()`` to reinstate the prior document slot.
    Nested registrations stack via the captured ``_prior``.
    """

    def __init__(self, prior):
        self._prior = prior

    def restore(self) -> None:
        global _current
        _current = self._prior


def register_document(doc) -> DocGuard:
    """Register ``doc`` as the current document for doc-aware
    primitives. Returns a guard; call ``guard.restore()`` to put
    back the prior document (which may be ``None``)."""
    global _current
    prior = _current
    _current = doc
    return DocGuard(prior)


class with_doc:
    """Context-manager equivalent of register_document + restore."""

    def __init__(self, doc):
        self._doc = doc
        self._guard: DocGuard | None = None

    def __enter__(self):
        self._guard = register_document(self._doc)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._guard is not None:
            self._guard.restore()
        return False


def _child_is_locked(elem) -> bool:
    # Elements expose ``.locked`` consistently via their CommonProps.
    try:
        return bool(elem.locked)
    except AttributeError:
        return False


def _child_visibility_invisible(elem) -> bool:
    try:
        from geometry.element import Visibility
        return elem.visibility == Visibility.INVISIBLE
    except Exception:
        return False


def _child_bounds(elem):
    try:
        return elem.bounds()
    except TypeError:
        return elem.bounds


def hit_test(x: float, y: float):
    """Top-level layer-child scan. Returns ``[li, ci]`` path or
    ``None`` on miss / no registered doc."""
    if _current is None:
        return None
    doc = _current
    layers = doc.layers
    for li in range(len(layers) - 1, -1, -1):
        layer = layers[li]
        if _child_is_locked(layer) or _child_visibility_invisible(layer):
            continue
        children = getattr(layer, "children", ())
        for ci in range(len(children) - 1, -1, -1):
            child = children[ci]
            if _child_is_locked(child) or _child_visibility_invisible(child):
                continue
            b = _child_bounds(child)
            bx, by, bw, bh = b[0], b[1], b[2], b[3]
            if bx <= x <= bx + bw and by <= y <= by + bh:
                return [li, ci]
    return None


def _recurse_deep(path: list[int], elem, x: float, y: float):
    if _child_is_locked(elem) or _child_visibility_invisible(elem):
        return None
    children = getattr(elem, "children", None)
    if children is not None and len(children) > 0 and not _elem_is_leaf(elem):
        for i in range(len(children) - 1, -1, -1):
            r = _recurse_deep(path + [i], children[i], x, y)
            if r is not None:
                return r
        return None
    b = _child_bounds(elem)
    bx, by, bw, bh = b[0], b[1], b[2], b[3]
    if bx <= x <= bx + bw and by <= y <= by + bh:
        return path
    return None


def _elem_is_leaf(elem) -> bool:
    # Group and Layer are the only containers; treat everything else
    # as a leaf even if it happens to expose a `.children` attr.
    try:
        from geometry.element import Group, Layer
        return not isinstance(elem, (Group, Layer))
    except Exception:
        return True


def hit_test_deep(x: float, y: float):
    """Recurse into groups; returns the deepest-leaf path."""
    if _current is None:
        return None
    doc = _current
    layers = doc.layers
    for li in range(len(layers) - 1, -1, -1):
        r = _recurse_deep([li], layers[li], x, y)
        if r is not None:
            return r
    return None


def selection_contains(path) -> bool:
    """True when ``path`` is in the current doc's selection
    (regardless of kind)."""
    if _current is None:
        return False
    doc = _current
    target = tuple(path)
    for es in doc.selection:
        if es.path == target:
            return True
    return False


def selection_empty() -> bool:
    """True when the current doc's selection is empty (or no doc)."""
    if _current is None:
        return True
    return len(_current.selection) == 0
