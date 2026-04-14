"""Reactive state store for the workspace interpreter.

Pure Python, no Qt dependency. Uses callback-based notifications.
Platform-specific bindings (Qt signals, Dioxus signals, etc.) connect
to the subscribe mechanism.
"""

from __future__ import annotations
from typing import Callable


class StateStore:
    """Manages global state, panel-scoped state, and reactive subscriptions."""

    def __init__(self, defaults: dict | None = None):
        self._state: dict = dict(defaults) if defaults else {}
        self._panels: dict[str, dict] = {}
        self._active_panel: str | None = None
        self._subscribers: list[tuple[set | None, Callable]] = []
        self._panel_subscribers: dict[str, list[Callable]] = {}

    # ── Global state ─────────────────────────────────────────

    def get(self, key: str):
        return self._state.get(key)

    def set(self, key: str, value):
        old = self._state.get(key)
        if old is value or old == value:
            return
        self._state[key] = value
        self._notify(key, value)

    def get_all(self) -> dict:
        return dict(self._state)

    # ── Panel state ──────────────────────────────────────────

    def init_panel(self, panel_id: str, defaults: dict):
        """Initialize a panel's state scope with defaults."""
        self._panels[panel_id] = dict(defaults)

    def get_panel(self, panel_id: str, key: str):
        scope = self._panels.get(panel_id)
        if scope is None:
            return None
        return scope.get(key)

    def set_panel(self, panel_id: str, key: str, value):
        scope = self._panels.get(panel_id)
        if scope is None:
            return
        old = scope.get(key)
        if old is value or old == value:
            return
        scope[key] = value
        self._notify_panel(panel_id, key, value)

    def get_panel_state(self, panel_id: str) -> dict:
        return dict(self._panels.get(panel_id, {}))

    def set_active_panel(self, panel_id: str | None):
        self._active_panel = panel_id

    def get_active_panel_id(self) -> str | None:
        return self._active_panel

    def get_active_panel_state(self) -> dict:
        if self._active_panel is None:
            return {}
        return dict(self._panels.get(self._active_panel, {}))

    def destroy_panel(self, panel_id: str):
        self._panels.pop(panel_id, None)
        self._panel_subscribers.pop(panel_id, None)
        if self._active_panel == panel_id:
            self._active_panel = None

    # ── List operations ──────────────────────────────────────

    def list_push(self, panel_id: str, key: str, value,
                  unique: bool = False, max_length: int | None = None):
        """Push a value to the front of a list in panel state."""
        scope = self._panels.get(panel_id)
        if scope is None:
            return
        lst = scope.get(key)
        if not isinstance(lst, list):
            lst = []
        lst = list(lst)  # copy
        if unique and value in lst:
            lst.remove(value)
        lst.insert(0, value)
        if max_length is not None and len(lst) > max_length:
            lst = lst[:max_length]
        scope[key] = lst
        self._notify_panel(panel_id, key, lst)

    # ── Subscriptions ────────────────────────────────────────

    def subscribe(self, keys: list[str] | None, callback: Callable):
        """Subscribe to global state changes.

        If keys is None, callback fires for any key change.
        callback receives (key, new_value).
        """
        key_set = set(keys) if keys is not None else None
        self._subscribers.append((key_set, callback))

    def subscribe_panel(self, panel_id: str, callback: Callable):
        """Subscribe to panel state changes. callback receives (key, new_value)."""
        self._panel_subscribers.setdefault(panel_id, []).append(callback)

    def _notify(self, key: str, value):
        for key_set, callback in self._subscribers:
            if key_set is None or key in key_set:
                callback(key, value)

    def _notify_panel(self, panel_id: str, key: str, value):
        for callback in self._panel_subscribers.get(panel_id, []):
            callback(key, value)

    # ── Context for expression evaluation ────────────────────

    def eval_context(self, extra: dict | None = None) -> dict:
        """Build an evaluation context dict for the expression evaluator.

        Returns {"state": {...}, "panel": {...}, ...}.
        """
        ctx = {"state": dict(self._state)}
        if self._active_panel and self._active_panel in self._panels:
            ctx["panel"] = dict(self._panels[self._active_panel])
        else:
            ctx["panel"] = {}
        if extra:
            ctx.update(extra)
        return ctx
