"""YAML-interpreted panel body widget.

Wraps yaml_renderer to create a complete panel from a YAML spec,
managing panel-local state initialization and reactive updates.
"""

from __future__ import annotations

from PySide6.QtWidgets import QWidget, QVBoxLayout

from workspace_interpreter.loader import panel_state_defaults
from workspace_interpreter.state_store import StateStore
from workspace_interpreter.expr import evaluate
from panels.yaml_renderer import (
    render_element,
    render_panel_absolute,
    _path_b_enabled,
    _PATH_B_UNSUPPORTED,
)


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
        self._ctx = dict(ctx or {})
        self._panel_id = panel_spec.get("id", "")
        # Expose the current panel id so widget renderers can route
        # bindings that depend on which panel is rendering
        # (e.g. op_make_mask / selection_mask_* in opacity_panel).
        self._ctx["_panel_id"] = self._panel_id

        # Initialize panel state — but only on FIRST mount. When the
        # dock rebuilds (e.g. after a hamburger menu command),
        # YamlPanelView gets reconstructed; if we init_panel again
        # the user's just-made change (mode, recent_colors, etc.)
        # gets wiped back to YAML defaults (CLR-022 Python).
        defaults = panel_state_defaults(panel_spec)
        existing = store.get_panel_state(self._panel_id)
        first_mount = not existing
        if first_mount:
            self._store.init_panel(self._panel_id, defaults)
        self._store.set_active_panel(self._panel_id)
        self._first_mount = first_mount

        # Opacity panel — stash the store handle in panel_menu so
        # the hamburger-menu toggle commands
        # (toggle_new_masks_clipping / toggle_new_masks_inverted /
        # toggle_opacity_thumbnails / toggle_opacity_options) and
        # the make_opacity_mask dispatch can reach it. Mirrors the
        # OCaml opacity_store_ref pattern.
        if self._panel_id == "opacity_panel_content":
            from panels.panel_menu import set_opacity_store
            set_opacity_store(self._store)
        # Character panel — same pattern: hamburger-menu toggle
        # commands (toggle_all_caps / small_caps / superscript /
        # subscript / snap_to_glyph_visible) need to reach the
        # panel-state bools without threading the store through
        # every dispatch call site.
        if self._panel_id == "character_panel_content":
            from panels.panel_menu import set_character_store
            set_character_store(self._store)
        # Paragraph panel — same pattern: hamburger-menu Hanging
        # Punctuation toggle and Reset Panel dispatch need to reach
        # the panel-state bools without threading the store through
        # every dispatch call site.
        if self._panel_id == "paragraph_panel_content":
            from panels.panel_menu import set_paragraph_store
            set_paragraph_store(self._store)

        # Run init expressions ONLY on first mount. Re-running on
        # dock rebuild would write back the YAML's init defaults
        # via set_panel, each fire dragging in the color bridge to
        # recompute / mirror the canvas — which on a None-fill
        # click cascades through the channel writes and snaps the
        # canvas back through a series of stale colors (CLR-167
        # Python).
        if first_mount:
            self._run_init()

        # Build UI
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        content = panel_spec.get("content")
        if isinstance(content, dict):
            # Path B preview: render this panel from the shared canonical
            # layout pass (absolute rects) instead of Qt layouts. Opt-in via
            # JAS_PATH_B=1 and restricted to the panels the cross-app
            # byte-gate covers (everything except color / gradient / layers,
            # whose composite widgets the v1 pass cannot size yet), so it is
            # zero-risk to shipped panels. Mirrors the Rust / Flask / Swift
            # flag (PATH_B_DESIGN.md §5 Phase 2).
            if _path_b_enabled() and self._panel_id not in _PATH_B_UNSUPPORTED:
                widget = render_panel_absolute(
                    panel_spec, store, self._ctx, dispatch_fn)
            else:
                widget = render_element(content, store, self._ctx, dispatch_fn)
            if widget:
                layout.addWidget(widget)
                # Propagate the rendered content's minimumHeight up
                # to the panel view so the dock's outer layout
                # (DroppablePanelGroup → DockPanelWidget's scroll
                # area) allocates enough vertical space. We avoid
                # touching minimumWidth here so the QScrollArea
                # viewport can still shrink the panel width.
                self.setMinimumHeight(widget.minimumHeight())

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
