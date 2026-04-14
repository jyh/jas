"""Native ColorBarWidget for the YAML interpreter.

A 2D HSB gradient canvas that can't be rendered generically — it
paints pixel-by-pixel. Registered in the native widget registry as
'color_bar'. The YAML spec provides style, bind, and behavior
properties; this widget handles its own painting and mouse input.
"""

from __future__ import annotations

from PySide6.QtWidgets import QWidget
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QPainter, QImage, QMouseEvent

from workspace_interpreter.color_util import hsb_to_rgb
from panels import widget_registry


class ColorBarWidget(QWidget):
    """2D HSB gradient. Hue varies along x (0-359), saturation/brightness along y."""

    def __init__(self, el: dict, store, ctx: dict, parent=None):
        super().__init__(parent)
        self._store = store
        self._el = el
        self._ctx = ctx
        self.setFixedHeight(64)
        self.setMinimumWidth(50)
        self.setCursor(Qt.CrossCursor)
        self._dragging = False

    def paintEvent(self, event):
        painter = QPainter(self)
        w, h = self.width(), self.height()
        if w <= 0 or h <= 0:
            return
        img = QImage(w, h, QImage.Format_RGB32)
        mid_y = h / 2.0
        for y in range(h):
            yf = float(y)
            if yf <= mid_y:
                t = yf / mid_y
                sat, br = t * 100, 100 - t * 20
            else:
                t = (yf - mid_y) / (h - mid_y) if h > mid_y else 0
                sat, br = 100, 80 * (1.0 - t)
            for x in range(w):
                hue = 360.0 * x / (w - 1) if w > 1 else 0
                r, g, b = hsb_to_rgb(hue, sat, br)
                img.setPixelColor(x, y, QColor(r, g, b))
        painter.drawImage(0, 0, img)

    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            self._dragging = True
            self._handle_point(event.position().x(), event.position().y(), commit=False)

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._dragging:
            self._handle_point(event.position().x(), event.position().y(), commit=False)

    def mouseReleaseEvent(self, event: QMouseEvent):
        if self._dragging:
            self._dragging = False
            self._handle_point(event.position().x(), event.position().y(), commit=True)

    def _handle_point(self, x: float, y: float, commit: bool):
        """Convert click/drag position to HSB and update panel state."""
        w = max(self.width(), 1)
        h = max(self.height(), 1)
        x = max(0.0, min(x, w - 1))
        y = max(0.0, min(y, h - 1))
        mid_y = h / 2.0

        hue = 360.0 * x / w
        if y <= mid_y:
            t = y / mid_y
            sat, br = t * 100, 100 - t * 20
        else:
            t = (y - mid_y) / (h - mid_y) if h > mid_y else 0
            sat, br = 100, 80 * (1 - t)

        # Update panel state
        panel_id = self._store.get_active_panel_id()
        if panel_id:
            self._store.set_panel(panel_id, "h", round(hue) % 360)
            self._store.set_panel(panel_id, "s", round(sat))
            self._store.set_panel(panel_id, "b", round(br))

            # Compute the hex color and update
            r, g, b = hsb_to_rgb(hue, sat, br)
            from workspace_interpreter.color_util import rgb_to_hex
            hex_color = rgb_to_hex(r, g, b)
            self._store.set_panel(panel_id, "hex",
                                  hex_color[1:] if hex_color.startswith("#") else hex_color)

            if commit:
                # Set the active color in global state
                fill_on_top = self._store.get("fill_on_top")
                if fill_on_top:
                    self._store.set("fill_color", hex_color)
                else:
                    self._store.set("stroke_color", hex_color)


def _color_bar_factory(el: dict, store, ctx: dict) -> QWidget:
    """Factory function for the widget registry."""
    return ColorBarWidget(el, store, ctx)


def register_color_bar():
    """Register the color_bar native widget."""
    widget_registry.register("color_bar", _color_bar_factory)
