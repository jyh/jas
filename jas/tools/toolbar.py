from enum import Enum, auto

from tools.tool import LONG_PRESS_MS

from PySide6.QtCore import Qt, Signal, QTimer, QPoint
from PySide6.QtGui import QPainter, QColor, QPen, QBrush, QPainterPath, QFont
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QToolButton, QButtonGroup,
    QMenu, QPushButton,
)


def _theme_qcolor(hex_str: str) -> QColor:
    """Convert a hex color string like '#cccccc' to a QColor."""
    return QColor(hex_str)


def _icon_color() -> QColor:
    from workspace.dock_panel import THEME_TEXT
    return _theme_qcolor(THEME_TEXT)


def _checked_bg() -> QColor:
    from workspace.dock_panel import THEME_BG_TAB
    return _theme_qcolor(THEME_BG_TAB)


def _inactive_bg() -> QColor:
    from workspace.dock_panel import THEME_BG_DARK
    return _theme_qcolor(THEME_BG_DARK)


class Tool(Enum):
    SELECTION = auto()
    PARTIAL_SELECTION = auto()
    INTERIOR_SELECTION = auto()
    PEN = auto()
    ADD_ANCHOR_POINT = auto()
    DELETE_ANCHOR_POINT = auto()
    ANCHOR_POINT = auto()
    PENCIL = auto()
    PAINTBRUSH = auto()
    PATH_ERASER = auto()
    SMOOTH = auto()
    TYPE = auto()
    TYPE_ON_PATH = auto()
    LINE = auto()
    RECT = auto()
    ROUNDED_RECT = auto()
    POLYGON = auto()
    STAR = auto()
    LASSO = auto()


def _draw_arrow_path() -> QPainterPath:
    """Return the shared arrow cursor path."""
    path = QPainterPath()
    path.moveTo(5, 2)
    path.lineTo(5, 24)
    path.lineTo(10, 18)
    path.lineTo(15, 26)
    path.lineTo(18, 24)
    path.lineTo(13, 16)
    path.lineTo(20, 16)
    path.closeSubpath()
    return path


class ToolButton(QToolButton):
    """A toolbar button that draws a tool icon."""

    ICON_SIZE = 28
    ARTWORK_SIZE = 28
    BUTTON_SIZE = 32

    # Emitted when the user double-clicks a tool icon. Toolbar bubbles
    # this as its own tool_options_requested signal, which jas_app
    # dispatches as an open_dialog effect using the tool's
    # tool_options_dialog field (PAINTBRUSH_TOOL.md §Tool options).
    tool_options_requested = Signal(object)

    def __init__(self, tool, parent=None, has_alternates=False):
        super().__init__(parent)
        self.tool = tool
        self.has_alternates = has_alternates
        self.setCheckable(True)
        self.setFixedSize(self.BUTTON_SIZE, self.BUTTON_SIZE)

    def mouseDoubleClickEvent(self, event):
        # Double-click: request the tool's options dialog. Qt also
        # fires mousePressEvent for this click, so the tool still
        # gets selected normally.
        self.tool_options_requested.emit(self.tool)
        super().mouseDoubleClickEvent(event)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Background on checked
        if self.isChecked():
            painter.fillRect(self.rect(), _checked_bg())

        # Center the icon
        ox = (self.width() - self.ICON_SIZE) / 2.0
        oy = (self.height() - self.ICON_SIZE) / 2.0
        painter.translate(ox, oy)

        pen = QPen(_icon_color(), 1.5)
        painter.setPen(pen)

        if self.tool == Tool.SELECTION:
            self._draw_selection_arrow(painter)
        elif self.tool == Tool.PARTIAL_SELECTION:
            self._draw_partial_selection_arrow(painter)
        elif self.tool == Tool.INTERIOR_SELECTION:
            self._draw_interior_selection_arrow(painter)
        elif self.tool == Tool.LINE:
            self._draw_line_tool(painter)
        elif self.tool == Tool.RECT:
            self._draw_rect_tool(painter)
        elif self.tool == Tool.ROUNDED_RECT:
            self._draw_rounded_rect_tool(painter)
        elif self.tool == Tool.PEN:
            self._draw_pen_tool(painter)
        elif self.tool == Tool.ADD_ANCHOR_POINT:
            self._draw_add_anchor_point_tool(painter)
        elif self.tool == Tool.DELETE_ANCHOR_POINT:
            self._draw_delete_anchor_point_tool(painter)
        elif self.tool == Tool.ANCHOR_POINT:
            self._draw_anchor_point_tool(painter)
        elif self.tool == Tool.PENCIL:
            self._draw_pencil_tool(painter)
        elif self.tool == Tool.PAINTBRUSH:
            self._draw_paintbrush_tool(painter)
        elif self.tool == Tool.PATH_ERASER:
            self._draw_path_eraser_tool(painter)
        elif self.tool == Tool.SMOOTH:
            self._draw_smooth_tool(painter)
        elif self.tool == Tool.TYPE:
            self._draw_type_tool(painter)
        elif self.tool == Tool.TYPE_ON_PATH:
            self._draw_type_on_path_tool(painter)
        elif self.tool == Tool.POLYGON:
            self._draw_polygon_tool(painter)
        elif self.tool == Tool.STAR:
            self._draw_star_tool(painter)
        elif self.tool == Tool.LASSO:
            self._draw_lasso_tool(painter)

        if self.has_alternates:
            self._draw_alternate_triangle(painter)

    def _draw_selection_arrow(self, painter):
        """Black arrow with white border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#ffffff"), 1.0))
        painter.setBrush(QColor("#000000"))
        painter.drawPath(path)

    def _draw_partial_selection_arrow(self, painter):
        """White arrow with black border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)

    def _draw_interior_selection_arrow(self, painter):
        """White arrow with black border and '+' badge."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)
        # Draw '+' in the lower-right
        painter.setPen(QPen(_icon_color(), 1.5))
        painter.drawLine(20, 20, 27, 20)
        painter.drawLine(23.5, 16.5, 23.5, 23.5)

    def _draw_line_tool(self, painter):
        # Line icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(_icon_color(), 8))
        painter.drawLine(30.79, 232.04, 231.78, 31.05)
        painter.restore()

    def _draw_rect_tool(self, painter):
        painter.setPen(QPen(_icon_color(), 1.5))
        painter.drawRect(4, 4, self.ICON_SIZE - 8, self.ICON_SIZE - 8)

    def _draw_rounded_rect_tool(self, painter):
        # Rounded Rectangle icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        from PySide6.QtCore import QRectF
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(_icon_color(), 8))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawRoundedRect(QRectF(23.33, 58.26, 212.06, 139.47), 30.0, 30.0)
        painter.restore()

    def _draw_pen_tool(self, painter):
        # Pen icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0  # 0.109375
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer path (icon color)
        outer = QPainterPath()
        outer.moveTo(163.07, 190.51)
        outer.lineTo(175.61, 210.03)
        outer.lineTo(84.93, 255.99)
        outer.lineTo(72.47, 227.94)
        outer.cubicTo(58.86, 195.29, 32.68, 176.45, 0.13, 161.51)
        outer.lineTo(0, 4.58)
        outer.cubicTo(0, 2.38, 2.8, -0.28, 4.11, -0.37)
        outer.cubicTo(5.42, -0.46, 8.07, 0.08, 9.42, 0.97)
        outer.lineTo(94.84, 57.3)
        outer.lineTo(143.22, 89.45)
        outer.cubicTo(135.93, 124.03, 139.17, 161.04, 163.08, 190.51)
        outer.closeSubpath()
        # Inner cutout
        outer.moveTo(61.7, 49.58)
        outer.lineTo(23.48, 24.2)
        outer.lineTo(65.56, 102.31)
        outer.cubicTo(73.04, 102.48, 79.74, 105.2, 83.05, 111.1)
        outer.cubicTo(86.36, 117.0, 86.92, 124.26, 82.1, 129.97)
        outer.cubicTo(75.74, 137.51, 64.43, 138.54, 57.38, 133.01)
        outer.cubicTo(49.55, 126.87, 47.97, 116.88, 54.52, 108.06)
        outer.lineTo(12.09, 30.4)
        outer.lineTo(12.53, 100.36)
        outer.lineTo(12.24, 154.67)
        outer.cubicTo(37.86, 166.32, 59.12, 182.87, 73.77, 206.51)
        outer.lineTo(138.57, 173.27)
        outer.cubicTo(127.46, 148.19, 124.88, 122.64, 130.1, 95.08)
        outer.lineTo(61.7, 49.58)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        painter.restore()

    def _draw_add_anchor_point_tool(self, painter):
        # Add Anchor Point icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer pen nib path + inner cutout (OddEvenFill)
        outer = QPainterPath()
        # Outer path
        outer.moveTo(170.82, 209.27)
        outer.lineTo(82.74, 256.0)
        outer.lineTo(71.75, 230.69)
        outer.cubicTo(60.04, 197.72, 31.98, 175.62, 0.51, 162.2)
        outer.lineTo(0.07, 55.68)
        outer.lineTo(0.0, 7.02)
        outer.cubicTo(0.0, 5.03, 0.62, 2.32, 1.66, 1.26)
        outer.cubicTo(2.7, 0.2, 6.93, -0.46, 8.2, 0.39)
        outer.lineTo(138.64, 88.51)
        outer.cubicTo(133.74, 121.05, 134.34, 154.96, 153.1, 182.9)
        outer.lineTo(170.8, 209.29)
        outer.closeSubpath()
        # Inner cutout (white in SVG)
        outer.moveTo(126.44, 94.04)
        outer.cubicTo(124.22, 105.79, 123.56, 115.97, 123.97, 126.68)
        outer.cubicTo(124.49, 142.78, 127.77, 157.48, 135.08, 172.91)
        outer.lineTo(72.22, 206.36)
        outer.cubicTo(57.84, 183.55, 37.99, 166.42, 12.09, 155.28)
        outer.lineTo(11.47, 30.25)
        outer.lineTo(53.28, 108.01)
        outer.cubicTo(48.06, 116.03, 47.97, 124.37, 53.59, 130.5)
        outer.cubicTo(59.69, 137.16, 68.89, 137.6, 76.64, 131.24)
        outer.cubicTo(83.21, 126.7, 84.48, 118.99, 81.68, 112.36)
        outer.cubicTo(78.79, 105.53, 72.96, 101.16, 64.53, 102.02)
        outer.lineTo(22.84, 24.63)
        outer.lineTo(126.44, 94.04)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        # Plus sign path
        plus = QPainterPath()
        plus.moveTo(232.87, 153.61)
        plus.cubicTo(229.4, 156.72, 224.13, 159.41, 219.01, 161.41)
        plus.lineTo(200.67, 127.38)
        plus.lineTo(166.99, 145.47)
        plus.lineTo(159.35, 132.09)
        plus.lineTo(193.51, 113.89)
        plus.lineTo(175.05, 78.74)
        plus.lineTo(188.64, 71.1)
        plus.lineTo(207.47, 106.52)
        plus.lineTo(240.85, 88.53)
        plus.lineTo(248.17, 101.98)
        plus.lineTo(214.87, 120.12)
        plus.lineTo(232.86, 153.58)
        plus.closeSubpath()
        painter.drawPath(plus)
        painter.restore()

    def _draw_delete_anchor_point_tool(self, painter):
        # Delete Anchor Point icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer pen nib path + inner cutout (OddEvenFill)
        outer = QPainterPath()
        outer.moveTo(171.16, 209.05)
        outer.lineTo(83.32, 256.0)
        outer.cubicTo(79.37, 247.74, 75.66, 239.67, 72.34, 231.11)
        outer.cubicTo(58.84, 196.29, 34.83, 177.34, 0.8, 161.2)
        outer.lineTo(0.4, 106.59)
        outer.lineTo(0.0, 6.21)
        outer.cubicTo(0.0, 3.95, 2.53, 0.66, 4.05, 0.16)
        outer.cubicTo(5.57, -0.34, 8.47, 0.37, 10.38, 1.67)
        outer.lineTo(138.0, 87.83)
        outer.cubicTo(137.83, 93.34, 137.19, 98.26, 136.44, 104.0)
        outer.cubicTo(133.14, 129.08, 137.75, 154.95, 149.25, 177.57)
        outer.lineTo(171.15, 209.05)
        outer.closeSubpath()
        # Inner cutout
        outer.moveTo(126.23, 94.28)
        outer.lineTo(23.74, 25.13)
        outer.lineTo(64.38, 101.36)
        outer.cubicTo(59.16, 109.38, 59.07, 117.72, 64.69, 123.85)
        outer.cubicTo(70.79, 130.51, 79.99, 130.95, 87.74, 124.59)
        outer.cubicTo(94.31, 120.05, 95.58, 112.34, 92.78, 105.71)
        outer.cubicTo(90.23, 99.59, 83.64, 94.52, 75.2, 95.38)
        outer.lineTo(23.73, 25.13)
        outer.lineTo(126.23, 94.28)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        # Minus sign (rotated rectangle from SVG)
        painter.save()
        painter.translate(-31.37, 110.38)
        painter.rotate(-28)
        painter.drawRect(158.95, 110.41, 93.43, 15.36)
        painter.restore()
        painter.restore()

    def _draw_anchor_point_tool(self, painter):
        """Convert Anchor Point: a center anchor square with two
        diagonal handle lines, suggesting a smooth/corner convert."""
        cx = self.ICON_SIZE / 2.0
        cy = self.ICON_SIZE / 2.0
        painter.save()
        painter.setPen(QPen(_icon_color(), 1.5))
        # Diagonal handle line
        painter.drawLine(int(cx - 10), int(cy - 10), int(cx + 10), int(cy + 10))
        # Handle endpoint circles (filled)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        r = 2.5
        for hx, hy in ((cx - 10, cy - 10), (cx + 10, cy + 10)):
            painter.drawEllipse(QPoint(int(hx), int(hy)), int(r), int(r))
        # Anchor square (filled with black outline)
        half = 4
        painter.drawRect(int(cx - half), int(cy - half), half * 2, half * 2)
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawRect(int(cx - half), int(cy - half), half * 2, half * 2)
        painter.restore()

    def _draw_pencil_tool(self, painter):
        # Pencil icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer path (main outline)
        outer = QPainterPath()
        outer.moveTo(57.6, 233.77)
        outer.lineTo(5.83, 255.77)
        outer.cubicTo(2.04, 257.38, -0.59, 250.2, 0.12, 246.99)
        outer.lineTo(15.75, 175.88)
        outer.cubicTo(16.99, 170.25, 17.94, 166.36, 21.83, 161.79)
        outer.lineTo(108.97, 59.4)
        outer.lineTo(152.73, 9.16)
        outer.cubicTo(159.64, 1.23, 172.84, -3.41, 181.96, 3.06)
        outer.cubicTo(195.07, 12.36, 206.14, 22.95, 217.94, 33.93)
        outer.cubicTo(225.32, 40.79, 226.65, 54.5, 220.25, 62.13)
        outer.lineTo(191.96, 95.82)
        outer.lineTo(84.39, 222.9)
        outer.cubicTo(75.27, 227.22, 66.72, 229.9, 57.6, 233.78)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(_inactive_bg())
        f1 = QPainterPath()
        f1.moveTo(208.57, 55.33)
        f1.cubicTo(212.62, 47.93, 207.38, 40.51, 202.08, 36.15)
        f1.lineTo(177.08, 15.57)
        f1.cubicTo(166.42, 6.79, 154.72, 26.62, 149.01, 33.89)
        f1.cubicTo(163.45, 47.79, 177.29, 60.62, 193.41, 72.64)
        f1.cubicTo(199.05, 66.99, 204.86, 62.09, 208.57, 55.33)
        f1.closeSubpath()
        painter.drawPath(f1)
        f2 = QPainterPath()
        f2.moveTo(70.01, 189.48)
        f2.cubicTo(64.87, 189.83, 59.66, 190.72, 56.07, 188.36)
        f2.cubicTo(53.24, 186.5, 52.14, 178.64, 53.23, 174.8)
        f2.lineTo(154.47, 55.84)
        f2.cubicTo(160.42, 60.73, 165.14, 64.9, 170.13, 70.41)
        f2.lineTo(70.01, 189.48)
        f2.closeSubpath()
        painter.drawPath(f2)
        f3 = QPainterPath()
        f3.moveTo(47.55, 169.12)
        f3.cubicTo(43.7, 170.57, 37.83, 169.44, 34.86, 166.85)
        f3.lineTo(76.41, 117.48)
        f3.lineTo(108.97, 79.49)
        f3.lineTo(138.8, 44.51)
        f3.cubicTo(142.42, 44.61, 145.79, 48.23, 147.44, 51.6)
        f3.lineTo(102.14, 104.57)
        f3.lineTo(47.55, 169.11)
        f3.closeSubpath()
        painter.drawPath(f3)
        f4 = QPainterPath()
        f4.moveTo(161.36, 111.12)
        f4.lineTo(93.27, 191.72)
        f4.cubicTo(88.75, 197.06, 84.94, 201.71, 79.55, 206.85)
        f4.cubicTo(76.45, 203.48, 74.45, 196.7, 78.52, 191.88)
        f4.lineTo(176.03, 76.63)
        f4.cubicTo(179.47, 77.08, 184.55, 80.31, 184.28, 83.19)
        f4.lineTo(161.36, 111.13)
        f4.closeSubpath()
        painter.drawPath(f4)
        # White tip highlight
        painter.setBrush(QColor("white"))
        tip = QPainterPath()
        tip.moveTo(71.47, 214.03)
        tip.cubicTo(60.16, 218.55, 50.33, 222.1, 39.16, 227.63)
        tip.lineTo(21.93, 214.37)
        tip.cubicTo(22.92, 208.81, 23.28, 203.26, 24.61, 197.77)
        tip.lineTo(29.0, 179.73)
        tip.cubicTo(30.63, 176.51, 40.55, 177.54, 42.67, 180.44)
        tip.cubicTo(45.87, 184.84, 45.86, 192.69, 49.8, 196.26)
        tip.cubicTo(53.77, 199.86, 60.42, 197.04, 64.72, 199.43)
        tip.cubicTo(69.02, 201.82, 69.61, 208.63, 71.47, 214.03)
        tip.closeSubpath()
        painter.drawPath(tip)
        painter.restore()

    def _draw_paintbrush_tool(self, painter):
        """Paintbrush icon — angled handle + ferrule + bristled tip,
        visually distinct from Pencil. Matches PAINTBRUSH_TOOL.md
        §Tool icon (Rust icons.rs / Swift Toolbar.swift equivalents)."""
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(Qt.PenStyle.NoPen)

        # Handle (diagonal rectangle)
        painter.setBrush(_icon_color())
        handle = QPainterPath()
        handle.moveTo(30, 230)
        handle.lineTo(60, 255)
        handle.lineTo(200, 115)
        handle.lineTo(165, 80)
        handle.closeSubpath()
        painter.drawPath(handle)

        # Ferrule (darker band)
        painter.save()
        painter.translate(187, 75)
        painter.rotate(-45)
        painter.translate(-187, -75)
        painter.setBrush(_inactive_bg())
        painter.drawRect(165, 60, 45, 30)
        painter.restore()

        # Bristled tip (rounded)
        painter.setBrush(_icon_color())
        tip = QPainterPath()
        tip.moveTo(195, 45)
        tip.quadTo(225, 20, 250, 40)
        tip.quadTo(255, 70, 225, 90)
        tip.lineTo(185, 65)
        tip.closeSubpath()
        painter.drawPath(tip)

        # Bristle highlights (white strokes)
        painter.setPen(QPen(QColor("white"), 4))
        painter.drawLine(205, 55, 225, 82)
        painter.drawLine(220, 45, 238, 70)
        painter.drawLine(235, 45, 242, 75)
        painter.setPen(Qt.PenStyle.NoPen)

        painter.restore()

    def _draw_path_eraser_tool(self, painter):
        # Path eraser icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Outer path (main outline)
        outer = QPainterPath()
        outer.moveTo(169.86, 33.13)
        outer.lineTo(243.34, 1.82)
        outer.cubicTo(246.77, 0.36, 249.73, -1.15, 253.26, 1.3)
        outer.cubicTo(255.47, 2.84, 256.6, 6.18, 255.67, 10.06)
        outer.lineTo(236.36, 90.59)
        outer.lineTo(128.34, 216.3)
        outer.lineTo(100.36, 247.5)
        outer.cubicTo(90.73, 258.24, 75.45, 258.84, 64.8, 249.13)
        outer.lineTo(36.8, 223.61)
        outer.cubicTo(27.71, 215.33, 27.26, 200.13, 35.38, 190.66)
        outer.lineTo(76.02, 143.21)
        outer.lineTo(169.85, 33.13)
        outer.closeSubpath()
        outer.setFillRule(Qt.FillRule.OddEvenFill)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(_inactive_bg())
        f1 = QPainterPath()
        f1.moveTo(184.63, 65.93)
        f1.cubicTo(189.51, 66.39, 194.59, 66.2, 198.13, 68.25)
        f1.cubicTo(201.04, 69.93, 203.57, 78.45, 201.14, 81.28)
        f1.lineTo(116.25, 180.28)
        f1.cubicTo(109.28, 176.56, 104.39, 171.21, 100.36, 164.52)
        f1.lineTo(184.63, 65.93)
        f1.closeSubpath()
        painter.drawPath(f1)
        f2 = QPainterPath()
        f2.moveTo(44.69, 212.9)
        f2.cubicTo(36.95, 201.82, 53.37, 190.58, 61.74, 180.12)
        f2.lineTo(106.79, 221.05)
        f2.lineTo(90.97, 239.52)
        f2.cubicTo(82.2, 249.76, 69.76, 237.13, 64.2, 232.21)
        f2.cubicTo(57.24, 226.04, 50.08, 220.63, 44.68, 212.9)
        f2.closeSubpath()
        painter.drawPath(f2)
        f3 = QPainterPath()
        f3.moveTo(207.17, 85.96)
        f3.cubicTo(211.98, 85.74, 215.71, 86.73, 220.02, 89.55)
        f3.lineTo(154.89, 165.84)
        f3.lineTo(131.54, 192.84)
        f3.cubicTo(127.63, 191.48, 125.1, 188.78, 122.92, 184.95)
        f3.lineTo(207.17, 85.97)
        f3.closeSubpath()
        painter.drawPath(f3)
        f4 = QPainterPath()
        f4.moveTo(124.64, 106.13)
        f4.lineTo(175.0, 47.68)
        f4.cubicTo(177.8, 51.64, 180.01, 56.74, 178.33, 59.8)
        f4.cubicTo(173.13, 69.28, 165.51, 76.42, 158.5, 84.62)
        f4.lineTo(95.94, 157.83)
        f4.cubicTo(93.95, 160.16, 90.93, 158.89, 89.56, 157.97)
        f4.cubicTo(87.97, 156.9, 84.31, 153.0, 86.41, 151.47)
        f4.cubicTo(96.6, 139.21, 107.11, 127.91, 116.95, 115.69)
        f4.lineTo(124.64, 106.13)
        f4.closeSubpath()
        painter.drawPath(f4)
        # White eraser tip + band
        painter.setBrush(QColor("white"))
        tip = QPainterPath()
        tip.moveTo(183.88, 41.54)
        tip.cubicTo(191.96, 36.87, 200.2, 34.23, 208.22, 31.18)
        tip.cubicTo(221.06, 26.3, 214.11, 26.93, 232.64, 41.38)
        tip.cubicTo(235.55, 41.71, 227.33, 76.83, 225.67, 77.25)
        tip.cubicTo(222.3, 80.28, 212.1, 79.09, 210.75, 75.03)
        tip.lineTo(205.76, 60.03)
        tip.lineTo(189.06, 56.22)
        tip.cubicTo(184.53, 55.19, 184.95, 47.11, 183.89, 41.54)
        tip.closeSubpath()
        painter.drawPath(tip)
        band = QPainterPath()
        band.addRect(88.74, 155.97, 14.58, 61.84)
        from PySide6.QtGui import QTransform
        xf = QTransform()
        xf.translate(299.56, 239.09)
        xf.rotate(131.58)
        band = xf.map(band)
        painter.drawPath(band)
        painter.restore()

    def _draw_smooth_tool(self, painter):
        # Smooth icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        # Pencil body + "S" lettering from the smooth tool SVG.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        # Pencil body
        outer = QPainterPath()
        outer.moveTo(70.89, 227.68)
        outer.lineTo(4.52, 255.09)
        outer.cubicTo(0.88, 256.59, -0.91, 248.43, -0.16, 245.21)
        outer.lineTo(17.39, 169.99)
        outer.cubicTo(24.75, 160.38, 31.97, 152.72, 39.68, 143.64)
        outer.lineTo(131.03, 36.05)
        outer.lineTo(144.21, 21.29)
        outer.cubicTo(154.4, 9.87, 168.74, 11.64, 179.56, 21.24)
        outer.lineTo(205.01, 43.83)
        outer.cubicTo(214.73, 52.45, 213.09, 65.99, 204.99, 75.55)
        outer.lineTo(174.64, 111.37)
        outer.lineTo(86.01, 216.71)
        outer.cubicTo(81.53, 222.03, 77.91, 224.78, 70.89, 227.68)
        outer.closeSubpath()
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(_inactive_bg())
        f1 = QPainterPath()
        f1.moveTo(66.39, 191.49)
        f1.cubicTo(63.13, 195.37, 55.31, 192.23, 52.22, 192.25)
        f1.cubicTo(50.62, 187.3, 49.74, 184.33, 49.59, 179.38)
        f1.lineTo(145.52, 66.15)
        f1.cubicTo(151.28, 70.25, 156.08, 74.56, 160.81, 79.96)
        f1.lineTo(112.0, 137.22)
        f1.lineTo(66.39, 191.49)
        f1.closeSubpath()
        painter.drawPath(f1)
        f2 = QPainterPath()
        f2.moveTo(194.82, 68.3)
        f2.cubicTo(190.49, 73.55, 186.85, 77.91, 182.22, 82.5)
        f2.lineTo(141.05, 44.73)
        f2.cubicTo(147.58, 35.76, 157.41, 18.57, 169.33, 28.72)
        f2.lineTo(192.63, 48.55)
        f2.cubicTo(198.53, 53.57, 199.92, 62.13, 194.83, 68.3)
        f2.closeSubpath()
        painter.drawPath(f2)
        f3 = QPainterPath()
        f3.moveTo(32.69, 171.62)
        f3.cubicTo(35.03, 169.5, 35.9, 166.47, 38.13, 163.87)
        f3.lineTo(86.71, 107.09)
        f3.lineTo(131.67, 54.87)
        f3.cubicTo(134.96, 55.93, 137.97, 58.23, 139.63, 61.75)
        f3.lineTo(44.81, 173.16)
        f3.cubicTo(41.4, 174.85, 37.29, 173.22, 32.69, 171.62)
        f3.closeSubpath()
        painter.drawPath(f3)
        f4 = QPainterPath()
        f4.moveTo(74.85, 208.97)
        f4.cubicTo(72.95, 205.46, 70.31, 201.15, 71.65, 197.51)
        f4.lineTo(134.32, 122.98)
        f4.cubicTo(138.19, 118.38, 141.65, 114.55, 145.53, 109.99)
        f4.lineTo(166.6, 85.22)
        f4.cubicTo(169.52, 87.53, 172.2, 88.21, 174.12, 90.63)
        f4.cubicTo(167.84, 101.81, 159.75, 109.64, 151.85, 119.0)
        f4.lineTo(83.45, 199.98)
        f4.cubicTo(80.68, 203.26, 78.45, 205.5, 74.84, 208.97)
        f4.closeSubpath()
        painter.drawPath(f4)
        # White tip highlight
        painter.setBrush(QColor("white"))
        tip = QPainterPath()
        tip.moveTo(61.28, 200.71)
        tip.cubicTo(64.24, 205.11, 65.93, 209.9, 66.93, 215.37)
        tip.lineTo(35.72, 228.83)
        tip.lineTo(20.11, 215.85)
        tip.lineTo(26.48, 181.11)
        tip.cubicTo(30.34, 181.56, 36.75, 180.57, 39.5, 183.8)
        tip.cubicTo(43.15, 188.1, 42.2, 194.89, 45.63, 199.46)
        tip.cubicTo(50.38, 200.86, 55.12, 200.42, 61.27, 200.72)
        tip.closeSubpath()
        painter.drawPath(tip)
        # "S" lettering (right side)
        painter.setBrush(_icon_color())
        s_path = QPainterPath()
        s_path.moveTo(210.2, 175.94)
        s_path.cubicTo(221.68, 185.28, 259.83, 188.72, 255.69, 222.01)
        s_path.cubicTo(254.5, 231.57, 248.08, 241.8, 237.42, 246.05)
        s_path.cubicTo(222.73, 251.9, 206.61, 250.52, 192.05, 244.82)
        s_path.cubicTo(192.52, 240.14, 193.6, 236.89, 195.16, 233.15)
        s_path.cubicTo(204.66, 236.94, 214.74, 238.68, 224.8, 236.57)
        s_path.cubicTo(233.48, 234.75, 238.62, 228.4, 239.23, 220.41)
        s_path.cubicTo(239.88, 211.86, 235.9, 205.22, 227.47, 201.4)
        s_path.lineTo(206.01, 191.68)
        s_path.cubicTo(194.41, 186.43, 187.58, 176.16, 187.67, 163.79)
        s_path.cubicTo(187.75, 152.1, 194.35, 141.45, 206.21, 136.42)
        s_path.cubicTo(220.61, 130.31, 237.7, 132.02, 251.7, 139.29)
        s_path.cubicTo(251.19, 144.18, 248.58, 147.49, 247.15, 151.76)
        s_path.cubicTo(233.82, 143.01, 205.83, 143.47, 204.03, 159.51)
        s_path.cubicTo(203.3, 166.01, 204.94, 171.65, 210.2, 175.93)
        s_path.closeSubpath()
        painter.drawPath(s_path)
        painter.restore()

    def _draw_type_tool(self, painter):
        # Type icon from assets/icons/type.svg (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        path = QPainterPath()
        path.moveTo(156.78, 197.66)
        path.lineTo(100.75, 197.48)
        path.cubicTo(96.82, 194.4, 96.71, 181.39, 100.77, 178.84)
        path.cubicTo(104.79, 176.31, 116.01, 180.43, 117.52, 175.37)
        path.lineTo(117.81, 79.15)
        path.cubicTo(104.22, 77.42, 92.22, 77.65, 79.61, 78.96)
        path.lineTo(77.77, 97.29)
        path.cubicTo(71.41, 98.59, 65.94, 98.55, 59.23, 97.22)
        path.cubicTo(58.49, 84.22, 58.18, 72.18, 59.38, 58.35)
        path.lineTo(196.62, 58.35)
        path.cubicTo(197.80, 72.10, 197.59, 84.19, 196.75, 97.25)
        path.cubicTo(190.10, 98.62, 184.66, 98.52, 178.21, 97.25)
        path.lineTo(176.38, 78.97)
        path.cubicTo(163.73, 77.71, 151.71, 77.51, 138.23, 79.15)
        path.lineTo(138.23, 176.88)
        path.lineTo(156.82, 178.76)
        path.cubicTo(158.02, 184.54, 158.40, 189.25, 156.78, 197.67)
        path.closeSubpath()
        painter.setPen(QPen(_icon_color(), 0))
        painter.setBrush(_icon_color())
        painter.drawPath(path)
        painter.restore()

    def _draw_type_on_path_tool(self, painter):
        # Type on a Path icon from assets/icons/type on a path.svg
        # (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(_icon_color(), 0))
        painter.setBrush(_icon_color())
        # Caret/insertion-point glyph (top stroke).
        path1 = QPainterPath()
        path1.moveTo(146.65, 143.92)
        path1.cubicTo(146.90, 149.81, 136.63, 147.47, 133.15, 143.77)
        path1.lineTo(115.23, 124.75)
        path1.cubicTo(112.23, 121.57, 114.91, 117.25, 116.23, 114.81)
        path1.cubicTo(117.93, 111.69, 124.83, 117.32, 126.72, 115.88)
        path1.cubicTo(141.92, 103.01, 156.13, 87.44, 170.36, 72.51)
        path1.cubicTo(173.34, 69.38, 167.59, 65.27, 165.59, 63.83)
        path1.cubicTo(159.29, 59.29, 144.76, 74.47, 146.36, 57.74)
        path1.cubicTo(146.98, 51.26, 159.88, 39.14, 166.61, 44.99)
        path1.cubicTo(184.78, 60.79, 201.40, 78.14, 217.12, 95.93)
        path1.cubicTo(219.01, 102.34, 205.42, 115.82, 199.03, 115.42)
        path1.cubicTo(189.98, 114.86, 201.34, 101.38, 197.33, 95.66)
        path1.cubicTo(195.60, 93.19, 189.73, 87.53, 186.13, 91.11)
        path1.lineTo(146.09, 130.89)
        path1.lineTo(146.65, 143.92)
        path1.closeSubpath()
        painter.drawPath(path1)
        # Underlying curve glyph.
        path2 = QPainterPath()
        path2.moveTo(194.00, 177.67)
        path2.cubicTo(196.66, 188.47, 189.71, 199.52, 182.32, 203.63)
        path2.cubicTo(158.52, 216.88, 137.39, 188.98, 120.34, 168.89)
        path2.cubicTo(105.40, 151.28, 88.87, 136.25, 72.65, 119.71)
        path2.cubicTo(68.96, 115.94, 63.09, 114.70, 59.42, 116.74)
        path2.cubicTo(47.24, 123.50, 54.88, 134.76, 45.63, 135.65)
        path2.cubicTo(27.42, 135.43, 43.44, 109.53, 51.73, 106.74)
        path2.cubicTo(59.80, 102.36, 72.46, 102.18, 79.04, 108.46)
        path2.cubicTo(93.71, 122.48, 107.83, 135.56, 120.81, 150.92)
        path2.cubicTo(133.49, 165.91, 147.03, 179.29, 161.34, 192.68)
        path2.cubicTo(165.16, 196.26, 172.01, 194.09, 175.80, 192.54)
        path2.cubicTo(180.32, 190.70, 180.63, 184.50, 181.52, 178.11)
        path2.cubicTo(181.97, 174.91, 193.13, 174.16, 194.00, 177.67)
        path2.closeSubpath()
        painter.drawPath(path2)
        painter.restore()

    def _draw_polygon_tool(self, painter):
        import math
        painter.setPen(QPen(_icon_color(), 1.5))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        cx, cy, r = self.ICON_SIZE / 2, self.ICON_SIZE / 2, self.ICON_SIZE / 2 - 3
        n = 6
        path = QPainterPath()
        for i in range(n):
            angle = -math.pi / 2 + 2 * math.pi * i / n
            px = cx + r * math.cos(angle)
            py = cy + r * math.sin(angle)
            if i == 0:
                path.moveTo(px, py)
            else:
                path.lineTo(px, py)
        path.closeSubpath()
        painter.drawPath(path)

    def _draw_star_tool(self, painter):
        # Star icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        from PySide6.QtCore import QPointF
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        oy = (self.ICON_SIZE - self.ARTWORK_SIZE) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(_icon_color(), 8))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        pts = [
            (128, 50.18), (145.47, 103.95), (202.01, 103.95),
            (156.27, 137.18), (173.74, 190.95), (128, 157.72),
            (82.26, 190.95), (99.73, 137.18), (53.99, 103.95),
            (110.53, 103.95),
        ]
        painter.drawPolygon([QPointF(x, y) for x, y in pts])
        painter.restore()

    def _draw_lasso_tool(self, painter):
        """Lasso icon — freehand loop placeholder."""
        from PySide6.QtCore import QPointF
        pen = QPen(_icon_color(), 1.5)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        painter.setPen(pen)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        path = QPainterPath()
        path.moveTo(14, 5)
        path.cubicTo(6, 5, 3, 10, 3, 14)
        path.cubicTo(3, 20, 8, 24, 14, 22)
        path.cubicTo(20, 20, 22, 16, 20, 12)
        path.cubicTo(18, 8, 12, 9, 12, 13)
        path.cubicTo(12, 16, 16, 17, 17, 15)
        painter.drawPath(path)

    def _draw_alternate_triangle(self, painter):
        """Small filled triangle in the lower-right corner indicating alternates."""
        tri = QPainterPath()
        s = 5
        tri.moveTo(self.ICON_SIZE, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE - s, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE, self.ICON_SIZE - s)
        tri.closeSubpath()
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(_icon_color())
        painter.drawPath(tri)


# Tools that share the partial/interior selection slot
_ARROW_SLOT_TOOLS = {Tool.PARTIAL_SELECTION, Tool.INTERIOR_SELECTION}
# Tools that share the pen/add-anchor-point slot
_PEN_SLOT_TOOLS = {Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT, Tool.ANCHOR_POINT}
# Tools that share the pencil/path-eraser slot
_PENCIL_SLOT_TOOLS = {Tool.PENCIL, Tool.PAINTBRUSH, Tool.PATH_ERASER, Tool.SMOOTH}
# Tools that share the text/text-path slot
_TEXT_SLOT_TOOLS = {Tool.TYPE, Tool.TYPE_ON_PATH}
# Tools that share the rect/polygon slot
_SHAPE_SLOT_TOOLS = {Tool.RECT, Tool.ROUNDED_RECT, Tool.POLYGON, Tool.STAR}
_LONG_PRESS_MS = LONG_PRESS_MS


class FillStrokeWidget(QWidget):
    """Fill/stroke indicator with overlapping squares, swap, and default buttons.

    Signals:
        fill_clicked: emitted when the fill square is clicked.
        stroke_clicked: emitted when the stroke square is clicked.
        fill_double_clicked: emitted when the fill square is double-clicked.
        stroke_double_clicked: emitted when the stroke square is double-clicked.
        swap_clicked: emitted when the swap arrow is clicked.
        default_clicked: emitted when the default reset button is clicked.
        fill_none_clicked: emitted when fill-none mode is chosen.
        stroke_none_clicked: emitted when stroke-none mode is chosen.
    """

    fill_clicked = Signal()
    stroke_clicked = Signal()
    fill_double_clicked = Signal()
    stroke_double_clicked = Signal()
    swap_clicked = Signal()
    default_clicked = Signal()
    fill_none_clicked = Signal()
    stroke_none_clicked = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._fill_color: QColor | None = QColor(255, 255, 255)
        self._stroke_color: QColor | None = QColor(0, 0, 0)
        self._fill_on_top = True
        self.setFixedSize(64, 80)

    def set_fill_color(self, color: QColor | None):
        self._fill_color = color
        self.update()

    def set_stroke_color(self, color: QColor | None):
        self._stroke_color = color
        self.update()

    def set_fill_on_top(self, on_top: bool):
        self._fill_on_top = on_top
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Layout: two overlapping 28x28 squares
        # Fill is always top-left, stroke is always offset to bottom-right
        sq_size = 28
        fill_x, fill_y = 0, 0
        stroke_x, stroke_y = 10, 10

        # Draw back square first (behind), then front square (on top)
        if self._fill_on_top:
            self._draw_stroke_square(painter, stroke_x, stroke_y, sq_size)
            self._draw_fill_square(painter, fill_x, fill_y, sq_size)
        else:
            self._draw_fill_square(painter, fill_x, fill_y, sq_size)
            self._draw_stroke_square(painter, stroke_x, stroke_y, sq_size)

        # Swap arrow (top-right)
        painter.setPen(QPen(_icon_color(), 1))
        ax, ay = 44, 4
        # Curved arrow hint
        painter.drawLine(ax, ay, ax + 8, ay)
        painter.drawLine(ax + 8, ay, ax + 8, ay + 8)
        painter.drawLine(ax + 8, ay + 8, ax + 5, ay + 5)
        painter.drawLine(ax + 8, ay + 8, ax + 8 + 3, ay + 5)

        # Default reset (bottom-left, small icon)
        dx, dy = 0, 44
        # Small fill square (white)
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(dx + 3, dy + 3, 8, 8)
        # Small stroke square (black border)
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(QColor(0, 0, 0), 2))
        painter.drawRect(dx, dy, 8, 8)

        # Mode buttons row: Color, None
        btn_y = 62
        # Color button
        painter.setPen(QPen(QColor("#999"), 1))
        painter.setBrush(QColor("#666"))
        painter.drawRect(2, btn_y, 14, 14)
        # Gradient button (disabled)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#444"))
        painter.drawRect(20, btn_y, 14, 14)
        # None button (red line)
        painter.setPen(QPen(QColor("#555"), 1))
        painter.setBrush(QColor("#fff"))
        painter.drawRect(38, btn_y, 14, 14)
        painter.setPen(QPen(QColor(255, 0, 0), 1.5))
        painter.drawLine(39, btn_y + 13, 51, btn_y + 1)

    def _draw_fill_square(self, painter, x, y, size):
        """Draw the fill square (solid fill)."""
        if self._fill_color is not None:
            painter.setPen(QPen(QColor("#666"), 1))
            painter.setBrush(self._fill_color)
        else:
            painter.setPen(QPen(QColor("#666"), 1))
            painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(x, y, size, size)
        if self._fill_color is None:
            # Draw red slash for "none"
            painter.setPen(QPen(QColor(255, 0, 0), 1.5))
            painter.drawLine(x + 1, y + size - 1, x + size - 1, y + 1)

    def _draw_stroke_square(self, painter, x, y, size):
        """Draw the stroke square (hollow with thick border, transparent center)."""
        if self._stroke_color is None:
            # None: white square with red diagonal
            painter.setPen(QPen(QColor(128, 128, 128), 1))
            painter.setBrush(QColor(255, 255, 255))
            painter.drawRect(x, y, size, size)
            painter.setPen(QPen(QColor(255, 0, 0), 1.5))
            painter.drawLine(x + 1, y + size - 1, x + size - 1, y + 1)
        else:
            # Hollow square: thick colored border, white center, thin outline
            bw = 6  # border width
            # Outer outline
            painter.setPen(QPen(QColor(128, 128, 128), 1))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRect(x, y, size, size)
            # Thick colored border
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(self._stroke_color)
            painter.drawRect(x + 1, y + 1, size - 1, bw)
            painter.drawRect(x + 1, y + size - bw, size - 1, bw)
            painter.drawRect(x + 1, y + bw, bw, size - 2 * bw)
            painter.drawRect(x + size - bw, y + bw, bw, size - 2 * bw)
            # White center
            painter.setBrush(QColor(255, 255, 255))
            painter.drawRect(x + bw + 1, y + bw + 1,
                             size - 2 * bw - 1, size - 2 * bw - 1)

    def _hit_square(self, x, y):
        """Return 'fill', 'stroke', or None based on click position.
        Check front square first (higher z-order), then back."""
        sq = 28
        fill_hit = 0 <= x <= sq and 0 <= y <= sq
        stroke_hit = 10 <= x <= 10 + sq and 10 <= y <= 10 + sq
        if self._fill_on_top:
            if fill_hit:
                return 'fill'
            if stroke_hit:
                return 'stroke'
        else:
            if stroke_hit:
                return 'stroke'
            if fill_hit:
                return 'fill'
        return None

    def mousePressEvent(self, event):
        x, y = event.position().x(), event.position().y()
        # Check swap arrow region (top-right)
        if 44 <= x <= 56 and 0 <= y <= 14:
            self.swap_clicked.emit()
            return
        # Check default reset region (bottom-left)
        if 0 <= x <= 14 and 42 <= y <= 56:
            self.default_clicked.emit()
            return
        # Check mode buttons
        if 62 <= y <= 76:
            if 38 <= x <= 52:
                if self._fill_on_top:
                    self.fill_none_clicked.emit()
                else:
                    self.stroke_none_clicked.emit()
                return
        # Check fill/stroke squares — click brings to front
        hit = self._hit_square(x, y)
        if hit == 'fill':
            self._fill_on_top = True
            self.fill_clicked.emit()
            self.update()
        elif hit == 'stroke':
            self._fill_on_top = False
            self.stroke_clicked.emit()
            self.update()

    def mouseDoubleClickEvent(self, event):
        x, y = event.position().x(), event.position().y()
        hit = self._hit_square(x, y)
        if hit == 'fill':
            self._fill_on_top = True
            self.update()
            self.fill_double_clicked.emit()
        elif hit == 'stroke':
            self._fill_on_top = False
            self.update()
            self.stroke_double_clicked.emit()


class Toolbar(QWidget):
    """Vertical toolbar with tool icons in a 2-column grid."""

    tool_changed = Signal(Tool)
    # Bubbled from ToolButton.tool_options_requested; jas_app dispatches
    # open_dialog using the tool's workspace.json tool_options_dialog
    # field (PAINTBRUSH_TOOL.md §Tool options).
    tool_options_requested = Signal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION
        # Which tool is visible in the shared arrow slot
        self._arrow_slot_tool = Tool.PARTIAL_SELECTION
        # Which tool is visible in the shared pen slot
        self._pen_slot_tool = Tool.PEN
        # Which tool is visible in the shared text slot
        self._text_slot_tool = Tool.TYPE
        # Which tool is visible in the shared pencil slot
        self._pencil_slot_tool = Tool.PENCIL
        # Which tool is visible in the shared shape slot
        self._shape_slot_tool = Tool.RECT

        layout = QVBoxLayout(self)
        layout.setContentsMargins(2, 4, 2, 4)
        layout.setSpacing(0)

        grid = QGridLayout()
        grid.setSpacing(2)
        layout.addLayout(grid)

        # Fill/stroke indicator
        self.fill_stroke_widget = FillStrokeWidget()
        layout.addSpacing(8)
        layout.addWidget(self.fill_stroke_widget, alignment=Qt.AlignmentFlag.AlignHCenter)

        layout.addStretch()

        self.button_group = QButtonGroup(self)
        self.button_group.setExclusive(True)

        self.buttons = {}
        # The arrow slot button starts as partial selection
        # The shape slot button starts as rect
        tools = [
            (Tool.SELECTION, 0, 0),
            (Tool.PARTIAL_SELECTION, 0, 1),
            (Tool.PEN, 1, 0),
            (Tool.PENCIL, 1, 1),
            (Tool.TYPE, 2, 0),
            (Tool.LINE, 2, 1),
            (Tool.RECT, 3, 0),
            (Tool.LASSO, 3, 1),
        ]
        for tool, row, col in tools:
            has_alt = tool in _ARROW_SLOT_TOOLS or tool in _PEN_SLOT_TOOLS or tool in _PENCIL_SLOT_TOOLS or tool in _TEXT_SLOT_TOOLS or tool in _SHAPE_SLOT_TOOLS
            btn = ToolButton(tool, has_alternates=has_alt)
            self.buttons[tool] = btn
            self.button_group.addButton(btn)
            grid.addWidget(btn, row, col)

        # Create hidden alternate buttons (not in grid, share slots)
        self.buttons[Tool.INTERIOR_SELECTION] = ToolButton(Tool.INTERIOR_SELECTION, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.INTERIOR_SELECTION])
        self.buttons[Tool.ADD_ANCHOR_POINT] = ToolButton(Tool.ADD_ANCHOR_POINT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.ADD_ANCHOR_POINT])
        self.buttons[Tool.DELETE_ANCHOR_POINT] = ToolButton(Tool.DELETE_ANCHOR_POINT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.DELETE_ANCHOR_POINT])
        self.buttons[Tool.ANCHOR_POINT] = ToolButton(Tool.ANCHOR_POINT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.ANCHOR_POINT])
        self.buttons[Tool.TYPE_ON_PATH] = ToolButton(Tool.TYPE_ON_PATH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.TYPE_ON_PATH])
        self.buttons[Tool.POLYGON] = ToolButton(Tool.POLYGON, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.POLYGON])
        self.buttons[Tool.ROUNDED_RECT] = ToolButton(Tool.ROUNDED_RECT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.ROUNDED_RECT])
        self.buttons[Tool.STAR] = ToolButton(Tool.STAR, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.STAR])
        self.buttons[Tool.PAINTBRUSH] = ToolButton(Tool.PAINTBRUSH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.PAINTBRUSH])
        self.buttons[Tool.PATH_ERASER] = ToolButton(Tool.PATH_ERASER, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.PATH_ERASER])
        self.buttons[Tool.SMOOTH] = ToolButton(Tool.SMOOTH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.SMOOTH])

        self.buttons[Tool.SELECTION].setChecked(True)
        self.button_group.buttonClicked.connect(self._on_button_clicked)

        # Bubble each button's double-click options-request up.
        for btn in self.buttons.values():
            btn.tool_options_requested.connect(self.tool_options_requested.emit)

        # Long-press timer for the arrow slot
        self._long_press_timer = QTimer(self)
        self._long_press_timer.setSingleShot(True)
        self._long_press_timer.setInterval(_LONG_PRESS_MS)
        self._long_press_timer.timeout.connect(self._show_arrow_slot_menu)

        # Long-press timer for the pen slot
        self._pen_long_press_timer = QTimer(self)
        self._pen_long_press_timer.setSingleShot(True)
        self._pen_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._pen_long_press_timer.timeout.connect(self._show_pen_slot_menu)

        # Long-press timer for the text slot
        self._text_long_press_timer = QTimer(self)
        self._text_long_press_timer.setSingleShot(True)
        self._text_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._text_long_press_timer.timeout.connect(self._show_text_slot_menu)

        # Long-press timer for the shape slot
        self._shape_long_press_timer = QTimer(self)
        self._shape_long_press_timer.setSingleShot(True)
        self._shape_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._shape_long_press_timer.timeout.connect(self._show_shape_slot_menu)

        # Install press/release handling on the arrow slot button
        arrow_btn = self.buttons[Tool.PARTIAL_SELECTION]
        arrow_btn.pressed.connect(self._on_arrow_slot_pressed)
        arrow_btn.released.connect(self._on_arrow_slot_released)

        # Install press/release handling on the pen slot button
        pen_btn = self.buttons[Tool.PEN]
        pen_btn.pressed.connect(self._on_pen_slot_pressed)
        pen_btn.released.connect(self._on_pen_slot_released)

        # Long-press timer for the pencil slot
        self._pencil_long_press_timer = QTimer(self)
        self._pencil_long_press_timer.setSingleShot(True)
        self._pencil_long_press_timer.setInterval(_LONG_PRESS_MS)
        self._pencil_long_press_timer.timeout.connect(self._show_pencil_slot_menu)

        # Install press/release handling on the pencil slot button
        pencil_btn = self.buttons[Tool.PENCIL]
        pencil_btn.pressed.connect(self._on_pencil_slot_pressed)
        pencil_btn.released.connect(self._on_pencil_slot_released)

        # Install press/release handling on the text slot button
        text_btn = self.buttons[Tool.TYPE]
        text_btn.pressed.connect(self._on_text_slot_pressed)
        text_btn.released.connect(self._on_text_slot_released)

        # Install press/release handling on the shape slot button
        shape_btn = self.buttons[Tool.RECT]
        shape_btn.pressed.connect(self._on_shape_slot_pressed)
        shape_btn.released.connect(self._on_shape_slot_released)

    def _on_button_clicked(self, btn):
        self.current_tool = btn.tool
        self.tool_changed.emit(btn.tool)

    def _on_arrow_slot_pressed(self):
        self._long_press_timer.start()

    def _on_arrow_slot_released(self):
        if self._long_press_timer.isActive():
            self._long_press_timer.stop()

    def _on_pen_slot_pressed(self):
        self._pen_long_press_timer.start()

    def _on_pen_slot_released(self):
        if self._pen_long_press_timer.isActive():
            self._pen_long_press_timer.stop()

    def _on_pencil_slot_pressed(self):
        self._pencil_long_press_timer.start()

    def _on_pencil_slot_released(self):
        if self._pencil_long_press_timer.isActive():
            self._pencil_long_press_timer.stop()

    def _on_text_slot_pressed(self):
        self._text_long_press_timer.start()

    def _on_text_slot_released(self):
        if self._text_long_press_timer.isActive():
            self._text_long_press_timer.stop()

    def _on_shape_slot_pressed(self):
        self._shape_long_press_timer.start()

    def _on_shape_slot_released(self):
        if self._shape_long_press_timer.isActive():
            self._shape_long_press_timer.stop()

    def _show_arrow_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.PARTIAL_SELECTION, Tool.INTERIOR_SELECTION):
            label = "Partial Selection" if tool == Tool.PARTIAL_SELECTION else "Interior Selection"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._arrow_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_arrow_slot(t))
        btn = self.buttons[self._arrow_slot_tool]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_pen_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT, Tool.ANCHOR_POINT):
            label = {Tool.PEN: "Pen", Tool.ADD_ANCHOR_POINT: "Add Anchor Point",
                     Tool.DELETE_ANCHOR_POINT: "Delete Anchor Point",
                     Tool.ANCHOR_POINT: "Anchor Point"}[tool]
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._pen_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_pen_slot(t))
        btn = self.buttons[Tool.PEN]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_pencil_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.PENCIL, Tool.PATH_ERASER, Tool.SMOOTH):
            label = {Tool.PENCIL: "Pencil", Tool.PATH_ERASER: "Path Eraser",
                     Tool.SMOOTH: "Smooth"}[tool]
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._pencil_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_pencil_slot(t))
        btn = self.buttons[Tool.PENCIL]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_text_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.TYPE, Tool.TYPE_ON_PATH):
            label = "Type" if tool == Tool.TYPE else "Type on a Path"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._text_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_text_slot(t))
        btn = self.buttons[Tool.TYPE]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_shape_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.RECT, Tool.ROUNDED_RECT, Tool.POLYGON, Tool.STAR):
            label = {Tool.RECT: "Rectangle",
                     Tool.ROUNDED_RECT: "Rounded Rectangle",
                     Tool.POLYGON: "Polygon",
                     Tool.STAR: "Star"}[tool]
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._shape_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_shape_slot(t))
        btn = self.buttons[Tool.RECT]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _switch_arrow_slot(self, tool: Tool):
        """Switch the arrow slot to show a different tool."""
        if tool == self._arrow_slot_tool:
            return
        self._arrow_slot_tool = tool
        arrow_btn = self.buttons[Tool.PARTIAL_SELECTION]
        arrow_btn.tool = tool
        arrow_btn.update()
        self.select_tool(tool)

    def _switch_pen_slot(self, tool: Tool):
        """Switch the pen slot to show a different tool."""
        if tool == self._pen_slot_tool:
            return
        self._pen_slot_tool = tool
        pen_btn = self.buttons[Tool.PEN]
        pen_btn.tool = tool
        pen_btn.update()
        self.select_tool(tool)

    def _switch_pencil_slot(self, tool: Tool):
        """Switch the pencil slot to show a different tool."""
        if tool == self._pencil_slot_tool:
            return
        self._pencil_slot_tool = tool
        pencil_btn = self.buttons[Tool.PENCIL]
        pencil_btn.tool = tool
        pencil_btn.update()
        self.select_tool(tool)

    def _switch_text_slot(self, tool: Tool):
        """Switch the text slot to show a different tool."""
        if tool == self._text_slot_tool:
            return
        self._text_slot_tool = tool
        text_btn = self.buttons[Tool.TYPE]
        text_btn.tool = tool
        text_btn.update()
        self.select_tool(tool)

    def _switch_shape_slot(self, tool: Tool):
        """Switch the shape slot to show a different tool."""
        if tool == self._shape_slot_tool:
            return
        self._shape_slot_tool = tool
        shape_btn = self.buttons[Tool.RECT]
        shape_btn.tool = tool
        shape_btn.update()
        self.select_tool(tool)

    def select_tool(self, tool):
        if tool in _ARROW_SLOT_TOOLS:
            arrow_btn = self.buttons[Tool.PARTIAL_SELECTION]
            arrow_btn.tool = tool
            arrow_btn.setChecked(True)
            arrow_btn.update()
            self._arrow_slot_tool = tool
        elif tool in _PEN_SLOT_TOOLS:
            pen_btn = self.buttons[Tool.PEN]
            pen_btn.tool = tool
            pen_btn.setChecked(True)
            pen_btn.update()
            self._pen_slot_tool = tool
        elif tool in _PENCIL_SLOT_TOOLS:
            pencil_btn = self.buttons[Tool.PENCIL]
            pencil_btn.tool = tool
            pencil_btn.setChecked(True)
            pencil_btn.update()
            self._pencil_slot_tool = tool
        elif tool in _TEXT_SLOT_TOOLS:
            text_btn = self.buttons[Tool.TYPE]
            text_btn.tool = tool
            text_btn.setChecked(True)
            text_btn.update()
            self._text_slot_tool = tool
        elif tool in _SHAPE_SLOT_TOOLS:
            shape_btn = self.buttons[Tool.RECT]
            shape_btn.tool = tool
            shape_btn.setChecked(True)
            shape_btn.update()
            self._shape_slot_tool = tool
        elif tool in self.buttons:
            self.buttons[tool].setChecked(True)
        self.current_tool = tool
        self.tool_changed.emit(tool)
