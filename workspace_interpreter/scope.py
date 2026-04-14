"""Immutable lexical scope for expression evaluation.

Bindings are stored as frozen mappings. New scopes are created via
extend() (push child scope) or | merge (add bindings at the same
level). The scope chain implements static scoping — inner scopes
shadow outer bindings without mutating them.
"""

from __future__ import annotations

from types import MappingProxyType


class Scope:
    """Immutable lexical scope with parent chain.

    Usage::

        root = Scope({"state": {...}, "panel": {...}, "data": {...}})
        lib_scope = root | {"lib": item_data}          # merge at same level
        swatch_scope = lib_scope.extend(swatch=swatch)  # push child scope
        ctx = swatch_scope.to_dict()                    # flatten for evaluator
    """

    __slots__ = ('_bindings', '_parent')

    def __init__(self, bindings: dict | None = None,
                 parent: Scope | None = None):
        self._bindings = MappingProxyType(dict(bindings or {}))
        self._parent = parent

    # ── Lookup ────────────────────────────────────────────

    def get(self, key: str):
        """Resolve a top-level key through the scope chain."""
        if key in self._bindings:
            return self._bindings[key]
        if self._parent is not None:
            return self._parent.get(key)
        return None

    def __contains__(self, key: str) -> bool:
        if key in self._bindings:
            return True
        if self._parent is not None:
            return key in self._parent
        return False

    # ── Scope creation ────────────────────────────────────

    def extend(self, **bindings) -> Scope:
        """Push a child scope. Self becomes the parent.

        Used when entering a repeat body — the loop variable is bound
        in the child scope, shadowing any same-named binding in the
        parent without mutating it.

            inner = outer.extend(lib=item_data)
        """
        return Scope(bindings, parent=self)

    def __or__(self, bindings: dict) -> Scope:
        """Merge operator: create a new scope at the same level.

        New bindings override existing ones. Neither self nor the
        input dict is modified. The parent chain is preserved.

            enriched = scope | {"data": swatch_libraries}
        """
        merged = dict(self._bindings)
        merged.update(bindings)
        return Scope(merged, parent=self._parent)

    # ── Flattening ────────────────────────────────────────

    def to_dict(self) -> dict:
        """Flatten the scope chain to a plain dict.

        Parent bindings are included; child bindings shadow parents.
        The result is suitable for the expression evaluator.
        """
        if self._parent is not None:
            result = self._parent.to_dict()
        else:
            result = {}
        result.update(self._bindings)
        return result

    def __repr__(self) -> str:
        keys = list(self._bindings.keys())
        depth = 0
        p = self._parent
        while p is not None:
            depth += 1
            p = p._parent
        return f"Scope({keys}, depth={depth})"
