"""YAML-interpreted panel body widget.

Wraps yaml_renderer to create a complete panel from a YAML spec,
managing panel-local state initialization and reactive updates.
"""

from __future__ import annotations

from PySide6.QtWidgets import QWidget, QVBoxLayout

from workspace_interpreter.loader import panel_state_defaults
from workspace_interpreter.state_store import StateStore
from workspace_interpreter.expr import evaluate
from panels.yaml_renderer import render_element


class YamlPanelView(QWidget):
    """Renders a panel body from its YAML spec.

    Args:
        panel_spec: The panel's YAML spec dict (with id, state, init, content).
        store: The shared state store.
        dispatch_fn: Callback(action_name, params) for action dispatch.
        ctx: Additional evaluation context (theme, data, etc.).
    """

    def __init__(self, panel_spec: dict, store: StateStore,
                 dispatch_fn=None, ctx: dict | None = None,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self._spec = panel_spec
        self._store = store
        self._dispatch_fn = dispatch_fn
        self._ctx = ctx or {}
        self._panel_id = panel_spec.get("id", "")

        # Initialize panel state
        defaults = panel_state_defaults(panel_spec)
        self._store.init_panel(self._panel_id, defaults)
        self._store.set_active_panel(self._panel_id)

        # Run init expressions
        self._run_init()

        # Build UI
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        content = panel_spec.get("content")
        if isinstance(content, dict):
            widget = render_element(content, store, self._ctx, dispatch_fn)
            if widget:
                layout.addWidget(widget)

    def _run_init(self):
        """Evaluate init expressions against current global state."""
        init_exprs = self._spec.get("init", {})
        if not init_exprs:
            return
        eval_ctx = self._store.eval_context(self._ctx)
        for key, expr in init_exprs.items():
            if isinstance(expr, str):
                result = evaluate(expr, eval_ctx)
                self._store.set_panel(self._panel_id, key, result.value)

    def activate(self):
        """Called when this panel becomes the active tab."""
        self._store.set_active_panel(self._panel_id)
        self._run_init()
