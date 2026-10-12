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


def hit_test(x: float, y: float):
    """Top-level layer-child scan. Returns ``[li, ci]`` of the topmost
    child whose PAINTED geometry is under the point, or ``None`` on
    miss / no registered doc. The law is ``hit_law`` (SELECTION_TOOL.md
    § Hit test: painted geometry); a group is hit when any child is."""
    from workspace_interpreter import hit_law
    if _current is None:
        return None
    layers = _current.layers
    for li in range(len(layers) - 1, -1, -1):
        layer = layers[li]
        vis = hit_law.blocks_hit(layer, _layer_cap())
        if vis is None:
            continue
        local = hit_law.to_local(layer, x, y)
        if local is None:
            continue
        children = getattr(layer, "children", ())
        for ci in range(len(children) - 1, -1, -1):
            if hit_law.painted_hit(children[ci], local[0], local[1], vis):
                return [li, ci]
    return None


def hit_test_deep(x: float, y: float):
    """Recurse into groups; returns the path of the deepest painted leaf."""
    from workspace_interpreter import hit_law
    if _current is None:
        return None
    layers = _current.layers
    for li in range(len(layers) - 1, -1, -1):
        r = hit_law.deep_hit(layers[li], [li], x, y, _layer_cap())
        if r is not None:
            return r
    return None


def _layer_cap():
    from geometry.element import Visibility
    return Visibility.PREVIEW


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
