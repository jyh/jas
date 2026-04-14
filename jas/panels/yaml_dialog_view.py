"""YAML-interpreted dialog widget for Qt/PySide6.

Renders a modal dialog from workspace YAML definitions, reusing the
existing yaml_renderer for the content tree.
"""

from __future__ import annotations

from PySide6.QtWidgets import QDialog, QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QWidget
from PySide6.QtCore import Qt

from workspace_interpreter.state_store import StateStore
from workspace_interpreter.expr import evaluate
from workspace_interpreter.loader import load_workspace
from panels.yaml_renderer import render_element


class YamlDialogView(QDialog):
    """Renders a YAML dialog as a Qt modal dialog.

    Args:
        dialog_id: The dialog ID (key in workspace dialogs dict).
        store: The shared state store (dialog state is initialized here).
        dispatch_fn: Callback(action_name, params) for action dispatch.
        ctx: Additional evaluation context.
        parent: Parent widget.
    """

    def __init__(self, dialog_id: str, store: StateStore,
                 dispatch_fn=None, ctx: dict | None = None,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self._dialog_id = dialog_id
        self._store = store
        self._dispatch_fn = dispatch_fn
        self._ctx = ctx or {}

        # Load dialog definition
        ws = load_workspace("workspace")
        dialogs = ws.get("dialogs", {}) if ws else {}
        self._dialog_def = dialogs.get(dialog_id, {})

        if not self._dialog_def:
            return

        # Set dialog properties
        summary = self._dialog_def.get("summary", dialog_id)
        self.setWindowTitle(summary)
        if self._dialog_def.get("modal", True):
            self.setWindowModality(Qt.WindowModality.ApplicationModal)
        width = self._dialog_def.get("width")
        if isinstance(width, (int, float)):
            self.setFixedWidth(int(width))

        # Build context with dialog namespace
        eval_ctx = store.eval_context(self._ctx)

        # Build layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Render content
        content = self._dialog_def.get("content")
        if isinstance(content, dict):
            widget = render_element(content, store, eval_ctx, self._dispatch_dialog_action)
            if widget:
                layout.addWidget(widget)

    def _dispatch_dialog_action(self, action_name: str, params: dict):
        """Dispatch actions from dialog buttons."""
        if action_name == "dismiss_dialog":
            self._store.close_dialog()
            self.reject()
            return

        # Forward to the app-level dispatch
        if self._dispatch_fn:
            self._dispatch_fn(action_name, params)

        # Check if the action closed the dialog
        if self._store.get_dialog_id() is None:
            self.accept()


def show_yaml_dialog(dialog_id: str, params: dict,
                     store: StateStore, dispatch_fn=None,
                     ctx: dict | None = None,
                     parent: QWidget | None = None) -> bool:
    """Open and run a YAML dialog modally.

    Initializes dialog state in the store, creates the dialog, runs it,
    and returns True if accepted (OK), False if rejected (Cancel).
    """
    from workspace_interpreter.effects import run_effects

    # Use open_dialog effect to initialize dialog state
    ws = load_workspace("workspace")
    dialogs = ws.get("dialogs", {}) if ws else {}
    run_effects(
        [{"open_dialog": {"id": dialog_id, "params": params}}],
        ctx or {}, store, dialogs=dialogs,
    )

    # Create and show dialog
    dlg = YamlDialogView(dialog_id, store, dispatch_fn=dispatch_fn,
                         ctx=ctx, parent=parent)
    result = dlg.exec()
    return result == QDialog.DialogCode.Accepted
