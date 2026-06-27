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
from panels.yaml_renderer import render_element, set_nonmodal_icon_size


class YamlDialogView(QDialog):
    """Renders a YAML dialog as a Qt modal dialog.

    Args:
        dialog_id: The dialog ID (key in workspace dialogs dict).
        store: The shared state store (dialog state is initialized here).
        dispatch_fn: Callback(action_name, params) for action dispatch.
        ctx: Additional evaluation context.
        parent: Parent widget.
    """

    def keyPressEvent(self, event):
        from PySide6.QtCore import Qt as _Qt
        # Swallow Enter/Return at the dialog level — the picker has
        # number_inputs that need to fire editingFinished on Enter
        # rather than have Qt auto-accept the dialog. Escape still
        # closes (calls reject) via the default QDialog behavior.
        if event.key() in (_Qt.Key_Return, _Qt.Key_Enter):
            event.accept()
            return
        super().keyPressEvent(event)

    def __init__(self, dialog_id: str, store: StateStore,
                 dispatch_fn=None, ctx: dict | None = None,
                 parent: QWidget | None = None,
                 anchor: tuple | None = None):
        super().__init__(parent)
        self._dialog_id = dialog_id
        self._store = store
        self._dispatch_fn = dispatch_fn
        self._ctx = ctx or {}
        # ``anchor`` is the global-screen (x, y) at which a NON-MODAL
        # flyout (e.g. the toolbar long-press tool-alternates) should be
        # placed — the cursor position captured at the slot button's
        # mouse_down. None means "no anchor": the dialog keeps Qt's
        # default centered-on-parent placement (color picker, tool-
        # options, print, artboard — all modal). Positioning is applied
        # in showEvent once the dialog has been sized. Mirrors the Rust
        # dialog_view branch on (is_modal, anchor): only !is_modal AND a
        # present anchor places at the cursor.
        self._anchor = anchor
        self._anchor_applied = False

        # Load dialog definition
        import os as _os
        _ws_path = _os.path.join(_os.path.dirname(__file__), "..", "..", "workspace")
        ws = load_workspace(_ws_path)
        dialogs = ws.get("dialogs", {}) if ws else {}
        self._dialog_def = dialogs.get(dialog_id, {})

        if not self._dialog_def:
            return

        # Set dialog properties
        summary = self._dialog_def.get("summary", dialog_id)
        self.setWindowTitle(summary)

        # Apply the active appearance theme to the dialog window so it
        # matches the dock/panels (otherwise the dialog renders on Qt's
        # default LIGHT palette — light-grey #ccc labels on white). The
        # QDialog / QLabel selectors are scoped so the background does not
        # cascade onto child rows (inputs keep their own darker style).
        from workspace import dock_panel
        self.setStyleSheet(
            f"QDialog {{ background-color: {dock_panel.THEME_BG}; }} "
            f"QLabel {{ color: {dock_panel.THEME_TEXT}; }}"
        )
        self._is_modal = bool(self._dialog_def.get("modal", True))
        if self._is_modal:
            self.setWindowModality(Qt.WindowModality.ApplicationModal)
        else:
            # Non-modal flyout (modal: false — tool-alternates). Render as
            # a frameless borderless popover so it reads as a compact bare
            # container placed at the cursor, NOT a centered titled dialog.
            # Mirrors the Rust dialog_view suppressing the title bar when
            # !is_modal (show_title_bar = is_modal) and the at-cursor
            # absolute placement.
            #
            # We deliberately do NOT use Qt.WindowType.Popup here. A Popup
            # installs an implicit mouse grab that (a) closes the window on
            # the very next mouse RELEASE — which, for a long-press flyout,
            # is the release that OPENED it — and (b) hides the widget
            # without clearing our store's dialog id, so the flyout could
            # not be re-opened. Instead this is a plain frameless Tool
            # window dismissed by an explicit application event filter
            # (see _install_dismiss_filter): the filter closes the flyout
            # on a genuine mouse PRESS outside its geometry while ignoring
            # the opening release, and clears the store so it can reopen.
            self.setWindowFlags(
                Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint)
        width = self._dialog_def.get("width")
        self._has_declared_width = isinstance(width, (int, float))
        if self._has_declared_width:
            self.setFixedWidth(int(width))

        # Build context with dialog namespace
        eval_ctx = store.eval_context(self._ctx)

        # Build layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Render content. For the NON-MODAL tool-alternate flyout
        # (modal: false), bracket the render with the flyout-scoped icon
        # size (28px): its size-less ``icon_button`` items then render
        # their glyphs at 28px instead of the 20px panel default,
        # matching OCaml's ``nonmodal_icon_size := Some 28`` around
        # show_nonmodal_dialog. The size is restored to None in a finally
        # so panels (also size-less icon_buttons) keep their 20px default
        # even if render raises. Modal dialogs are untouched.
        content = self._dialog_def.get("content")
        content_widget = None
        if isinstance(content, dict):
            if not self._is_modal:
                set_nonmodal_icon_size(28)
            try:
                widget = render_element(
                    content, store, eval_ctx, self._dispatch_dialog_action)
            finally:
                if not self._is_modal:
                    set_nonmodal_icon_size(None)
            if widget:
                content_widget = widget
                layout.addWidget(widget)

        # Compact-width clamp for the NON-MODAL flyout (modal: false,
        # e.g. the toolbar long-press tool-alternates). Its items carry
        # ``width: "100%"`` which _apply_style maps to a horizontally
        # Expanding size policy — correct for filling a fixed-width
        # column, but a top-level QDialog has no width to fill, so Qt
        # opens the window at the platform's default minimum (~380px on
        # macOS, 200px offscreen) and the Expanding items stretch to it,
        # leaving the small icons floating in a wide empty box. Pin the
        # flyout to its content's own sizeHint width so it reads as the
        # compact narrow icon column the Swift/OCaml flyouts already show.
        # Scoped to !is_modal AND no declared width: modal dialogs use
        # the centered path (and may declare their own width) and the
        # 32x32 checked toolbar tool buttons live in the panes, not here,
        # so both are untouched.
        if (not self._is_modal and not self._has_declared_width
                and content_widget is not None):
            hint = content_widget.sizeHint().width()
            if hint > 0:
                self.setFixedWidth(hint)

        # Subscribe to dialog state so inline effects that call
        # close_dialog (e.g. the picker's OK button) actually close
        # the QDialog window. The button's effect runs through
        # workspace_interpreter.run_effects → store.close_dialog(),
        # which clears the store but doesn't touch the widget. The
        # action-dispatch path covers the dismiss_dialog case;
        # inline effects need this hook.
        self._closing = False
        def _on_state(key, _value):
            if self._closing:
                return
            if store.get_dialog_id() is None:
                self._closing = True
                try:
                    self.accept()
                except RuntimeError:
                    pass
        store.subscribe(None, _on_state)

        # Outside-press dismissal state for the non-modal flyout. The
        # application event filter (installed in showEvent, removed on
        # close/hide) closes the flyout on a genuine mouse PRESS outside
        # its geometry. ``_dismiss_armed`` guards the OPENING release: the
        # long-press fires while the slot button is still held, so the
        # very first mouse RELEASE the app sees after the flyout shows is
        # the one that opened it — never a dismissal. We arm only once a
        # press lands inside the flyout, or once that opening release has
        # passed, so the opening release can never close the flyout.
        self._dismiss_filter_installed = False

    def showEvent(self, event):
        """Place a NON-MODAL anchored flyout at the cursor before it
        first appears, instead of Qt's default centered-on-parent.

        Mirrors the Rust dialog_view branch: the at-cursor placement
        fires only when BOTH ``modal: false`` AND an anchor is present
        (dialog_view.rs (a) branch). The popover's top-left corner is
        pinned to the anchor coords — the same as Rust's
        ``position:absolute; left:{ax}px; top:{ay}px`` with no flip /
        clamp / offset math. The dialog is sized by its layout by the
        time showEvent fires, so a light clamp keeps the bottom / right
        edges on-screen (Qt's frameless Popup would otherwise let a
        bottom-of-screen press run the flyout off the desktop — this is
        the small, harmless deviation Rust doesn't need because the web
        viewport scrolls; it never moves the top-left ABOVE / LEFT of the
        anchor so the popover still grows down-and-right from the cursor).
        Modal dialogs (anchor None) are untouched and stay centered.
        """
        if (not self._anchor_applied and self._anchor is not None
                and not getattr(self, "_is_modal", True)):
            self._anchor_applied = True
            self._place_at_anchor()
        # Arm the outside-press dismissal for the non-modal flyout once it
        # is actually on screen (after placement, so geometry() is final).
        if not getattr(self, "_is_modal", True):
            self._install_dismiss_filter()
        super().showEvent(event)

    def hideEvent(self, event):
        # Stop intercepting global mouse events the moment the flyout is
        # no longer visible (outside-press dismiss, item pick, or accept).
        self._remove_dismiss_filter()
        super().hideEvent(event)

    def closeEvent(self, event):
        self._remove_dismiss_filter()
        super().closeEvent(event)

    def _install_dismiss_filter(self) -> None:
        """Install an application-wide event filter that closes this
        non-modal flyout on a genuine mouse PRESS outside its geometry.

        This replaces Qt.WindowType.Popup's implicit grab, which closed
        the flyout on the OPENING long-press release and hid it without
        clearing the store (blocking reopen). The filter ignores the
        opening release (``_dismiss_armed`` starts False) and only acts on
        a real outside press once armed.
        """
        if self._dismiss_filter_installed:
            return
        from PySide6.QtWidgets import QApplication
        app = QApplication.instance()
        if app is None:
            return
        # The opening long-press release has not been seen yet. Stay
        # unarmed until the first release passes (or a press lands inside),
        # so that release can never be treated as an outside dismissal.
        self._dismiss_armed = False
        app.installEventFilter(self)
        self._dismiss_filter_installed = True

    def _remove_dismiss_filter(self) -> None:
        if not getattr(self, "_dismiss_filter_installed", False):
            return
        from PySide6.QtWidgets import QApplication
        app = QApplication.instance()
        if app is not None:
            app.removeEventFilter(self)
        self._dismiss_filter_installed = False

    def eventFilter(self, obj, event):
        from PySide6.QtCore import QEvent
        et = event.type()
        if et == QEvent.Type.MouseButtonRelease:
            # The first release after the flyout opens is the long-press
            # release that opened it — consume nothing, just arm so the
            # NEXT press can dismiss.
            self._dismiss_armed = True
            return super().eventFilter(obj, event)
        if et == QEvent.Type.MouseButtonPress:
            # A press inside the flyout (item pick) is handled by the
            # item's own handler; arm so a later outside press dismisses,
            # and let the event through.
            inside = self._press_is_inside(event)
            if inside:
                self._dismiss_armed = True
                return super().eventFilter(obj, event)
            # Outside press: dismiss only once armed (never the opening
            # interaction). Clearing the store lets the same flyout reopen.
            if getattr(self, "_dismiss_armed", False):
                self._dismiss_armed = False
                self._remove_dismiss_filter()
                if self._store is not None and self._store.get_dialog_id():
                    self._store.close_dialog()
                if not self._closing:
                    try:
                        self.reject()
                    except RuntimeError:
                        pass
                # Swallow this press so it does not also act on whatever is
                # behind the flyout (mirrors a popup's modal-ish dismiss).
                return True
        return super().eventFilter(obj, event)

    def _press_is_inside(self, event) -> bool:
        """True if a mouse-press event falls within the flyout's window
        rectangle (in global/screen coords)."""
        try:
            gp = event.globalPosition().toPoint()
        except AttributeError:
            gp = event.globalPos()
        return self.frameGeometry().contains(gp)

    def _place_at_anchor(self) -> None:
        from PySide6.QtCore import QPoint
        from PySide6.QtGui import QGuiApplication
        ax, ay = int(self._anchor[0]), int(self._anchor[1])
        # Ensure the geometry is computed so width()/height() reflect the
        # laid-out content before we clamp against the screen edges.
        self.adjustSize()
        w = self.width()
        h = self.height()
        screen = self.screen() or QGuiApplication.screenAt(QPoint(ax, ay)) \
            or QGuiApplication.primaryScreen()
        if screen is not None:
            geo = screen.availableGeometry()
            # Clamp so the popover stays on-screen but never above/left
            # of the cursor (it grows down-and-right like the Rust one).
            max_x = geo.right() - w
            max_y = geo.bottom() - h
            if max_x >= ax:
                pass
            elif max_x >= geo.left():
                ax = max_x
            # else: too wide for the screen; leave at cursor.
            if max_y >= ay:
                pass
            elif max_y >= geo.top():
                ay = max_y
        self.move(ax, ay)

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

    # Use open_dialog effect to initialize dialog state. Workspace
    # path is resolved relative to this file so the module works
    # regardless of the caller's cwd (the legacy ``"workspace"`` arg
    # only worked when cwd was the project root).
    import os as _os
    _ws_path = _os.path.join(_os.path.dirname(__file__), "..", "..", "workspace")
    ws = load_workspace(_ws_path)
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
