from enum import Enum, auto

from tools.tool import LONG_PRESS_MS

from PySide6.QtCore import Qt, Signal, QTimer, QPoint
from PySide6.QtGui import QPainter, QColor, QPen, QPainterPath, QFont
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QGridLayout, QToolButton, QButtonGroup, QMenu,
)


class Tool(Enum):
    SELECTION = auto()
    DIRECT_SELECTION = auto()
    GROUP_SELECTION = auto()
    PEN = auto()
    ADD_ANCHOR_POINT = auto()
    DELETE_ANCHOR_POINT = auto()
    PENCIL = auto()
    PATH_ERASER = auto()
    SMOOTH = auto()
    TEXT = auto()
    TEXT_PATH = auto()
    LINE = auto()
    RECT = auto()
    ROUNDED_RECT = auto()
    POLYGON = auto()
    STAR = auto()


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
    BUTTON_SIZE = 32

    def __init__(self, tool, parent=None, has_alternates=False):
        super().__init__(parent)
        self.tool = tool
        self.has_alternates = has_alternates
        self.setCheckable(True)
        self.setFixedSize(self.BUTTON_SIZE, self.BUTTON_SIZE)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        # Background on checked
        if self.isChecked():
            painter.fillRect(self.rect(), QColor("#505050"))

        # Center the icon
        ox = (self.width() - self.ICON_SIZE) / 2.0
        oy = (self.height() - self.ICON_SIZE) / 2.0
        painter.translate(ox, oy)

        pen = QPen(QColor("#cccccc"), 1.5)
        painter.setPen(pen)

        if self.tool == Tool.SELECTION:
            self._draw_selection_arrow(painter)
        elif self.tool == Tool.DIRECT_SELECTION:
            self._draw_direct_selection_arrow(painter)
        elif self.tool == Tool.GROUP_SELECTION:
            self._draw_group_selection_arrow(painter)
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
        elif self.tool == Tool.PENCIL:
            self._draw_pencil_tool(painter)
        elif self.tool == Tool.PATH_ERASER:
            self._draw_path_eraser_tool(painter)
        elif self.tool == Tool.SMOOTH:
            self._draw_smooth_tool(painter)
        elif self.tool == Tool.TEXT:
            self._draw_text_tool(painter)
        elif self.tool == Tool.TEXT_PATH:
            self._draw_text_path_tool(painter)
        elif self.tool == Tool.POLYGON:
            self._draw_polygon_tool(painter)
        elif self.tool == Tool.STAR:
            self._draw_star_tool(painter)

        if self.has_alternates:
            self._draw_alternate_triangle(painter)

    def _draw_selection_arrow(self, painter):
        """Black arrow with white border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#ffffff"), 1.0))
        painter.setBrush(QColor("#000000"))
        painter.drawPath(path)

    def _draw_direct_selection_arrow(self, painter):
        """White arrow with black border."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)

    def _draw_group_selection_arrow(self, painter):
        """White arrow with black border and '+' badge."""
        path = _draw_arrow_path()
        painter.setPen(QPen(QColor("#000000"), 1.0))
        painter.setBrush(QColor("#ffffff"))
        painter.drawPath(path)
        # Draw '+' in the lower-right
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.drawLine(20, 20, 27, 20)
        painter.drawLine(23.5, 16.5, 23.5, 23.5)

    def _draw_line_tool(self, painter):
        # Line icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(QColor("#cccccc"), 8))
        painter.drawLine(30.79, 232.04, 231.78, 31.05)
        painter.restore()

    def _draw_rect_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        painter.drawRect(4, 4, self.ICON_SIZE - 8, self.ICON_SIZE - 8)

    def _draw_rounded_rect_tool(self, painter):
        # Rounded Rectangle icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        from PySide6.QtCore import QRectF
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(QColor("#cccccc"), 8))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawRoundedRect(QRectF(23.33, 58.26, 212.06, 139.47), 30.0, 30.0)
        painter.restore()

    def _draw_pen_tool(self, painter):
        # Pen icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0  # 0.109375
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        painter.restore()

    def _draw_add_anchor_point_tool(self, painter):
        # Add Anchor Point icon from SVG (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
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
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        # Minus sign (rotated rectangle from SVG)
        painter.save()
        painter.translate(-31.37, 110.38)
        painter.rotate(-28)
        painter.drawRect(158.95, 110.41, 93.43, 15.36)
        painter.restore()
        painter.restore()

    def _draw_pencil_tool(self, painter):
        # Pencil icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(QColor("#3c3c3c"))
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

    def _draw_path_eraser_tool(self, painter):
        # Path eraser icon from SVG paths (viewBox 0 0 256 256), scaled to 28x28.
        s = 28.0 / 256.0
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(QColor("#3c3c3c"))
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
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
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
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(outer)
        # Gray facets
        painter.setBrush(QColor("#3c3c3c"))
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
        painter.setBrush(QColor("#cccccc"))
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

    def _draw_text_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        font = QFont("sans-serif", 18, QFont.Weight.Bold)
        painter.setFont(font)
        painter.drawText(4, 22, "T")

    def _draw_text_path_tool(self, painter):
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
        font = QFont("sans-serif", 14, QFont.Weight.Bold)
        painter.setFont(font)
        painter.drawText(2, 18, "T")
        # Draw a small wavy path
        path = QPainterPath()
        path.moveTo(12, 20)
        path.cubicTo(16, 8, 22, 24, 26, 12)
        painter.setPen(QPen(QColor("#cccccc"), 1.0))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.drawPath(path)

    def _draw_polygon_tool(self, painter):
        import math
        painter.setPen(QPen(QColor("#cccccc"), 1.5))
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
        ox = (self.ICON_SIZE - 28) / 2.0
        oy = (self.ICON_SIZE - 28) / 2.0
        painter.save()
        painter.translate(ox, oy)
        painter.scale(s, s)
        painter.setPen(QPen(QColor("#cccccc"), 8))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        pts = [
            (128, 50.18), (145.47, 103.95), (202.01, 103.95),
            (156.27, 137.18), (173.74, 190.95), (128, 157.72),
            (82.26, 190.95), (99.73, 137.18), (53.99, 103.95),
            (110.53, 103.95),
        ]
        painter.drawPolygon([QPointF(x, y) for x, y in pts])
        painter.restore()

    def _draw_alternate_triangle(self, painter):
        """Small filled triangle in the lower-right corner indicating alternates."""
        tri = QPainterPath()
        s = 5
        tri.moveTo(self.ICON_SIZE, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE - s, self.ICON_SIZE)
        tri.lineTo(self.ICON_SIZE, self.ICON_SIZE - s)
        tri.closeSubpath()
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor("#cccccc"))
        painter.drawPath(tri)


# Tools that share the direct/group selection slot
_ARROW_SLOT_TOOLS = {Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION}
# Tools that share the pen/add-anchor-point slot
_PEN_SLOT_TOOLS = {Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT}
# Tools that share the pencil/path-eraser slot
_PENCIL_SLOT_TOOLS = {Tool.PENCIL, Tool.PATH_ERASER, Tool.SMOOTH}
# Tools that share the text/text-path slot
_TEXT_SLOT_TOOLS = {Tool.TEXT, Tool.TEXT_PATH}
# Tools that share the rect/polygon slot
_SHAPE_SLOT_TOOLS = {Tool.RECT, Tool.ROUNDED_RECT, Tool.POLYGON, Tool.STAR}
_LONG_PRESS_MS = LONG_PRESS_MS


class Toolbar(QWidget):
    """Vertical toolbar with tool icons in a 2-column grid."""

    tool_changed = Signal(Tool)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_tool = Tool.SELECTION
        # Which tool is visible in the shared arrow slot
        self._arrow_slot_tool = Tool.DIRECT_SELECTION
        # Which tool is visible in the shared pen slot
        self._pen_slot_tool = Tool.PEN
        # Which tool is visible in the shared text slot
        self._text_slot_tool = Tool.TEXT
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
        layout.addStretch()

        self.button_group = QButtonGroup(self)
        self.button_group.setExclusive(True)

        self.buttons = {}
        # The arrow slot button starts as direct selection
        # The shape slot button starts as rect
        tools = [
            (Tool.SELECTION, 0, 0),
            (Tool.DIRECT_SELECTION, 0, 1),
            (Tool.PEN, 1, 0),
            (Tool.PENCIL, 1, 1),
            (Tool.TEXT, 2, 0),
            (Tool.LINE, 2, 1),
            (Tool.RECT, 3, 0),
        ]
        for tool, row, col in tools:
            has_alt = tool in _ARROW_SLOT_TOOLS or tool in _PEN_SLOT_TOOLS or tool in _PENCIL_SLOT_TOOLS or tool in _TEXT_SLOT_TOOLS or tool in _SHAPE_SLOT_TOOLS
            btn = ToolButton(tool, has_alternates=has_alt)
            self.buttons[tool] = btn
            self.button_group.addButton(btn)
            grid.addWidget(btn, row, col)

        # Create hidden alternate buttons (not in grid, share slots)
        self.buttons[Tool.GROUP_SELECTION] = ToolButton(Tool.GROUP_SELECTION, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.GROUP_SELECTION])
        self.buttons[Tool.ADD_ANCHOR_POINT] = ToolButton(Tool.ADD_ANCHOR_POINT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.ADD_ANCHOR_POINT])
        self.buttons[Tool.DELETE_ANCHOR_POINT] = ToolButton(Tool.DELETE_ANCHOR_POINT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.DELETE_ANCHOR_POINT])
        self.buttons[Tool.TEXT_PATH] = ToolButton(Tool.TEXT_PATH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.TEXT_PATH])
        self.buttons[Tool.POLYGON] = ToolButton(Tool.POLYGON, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.POLYGON])
        self.buttons[Tool.ROUNDED_RECT] = ToolButton(Tool.ROUNDED_RECT, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.ROUNDED_RECT])
        self.buttons[Tool.STAR] = ToolButton(Tool.STAR, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.STAR])
        self.buttons[Tool.PATH_ERASER] = ToolButton(Tool.PATH_ERASER, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.PATH_ERASER])
        self.buttons[Tool.SMOOTH] = ToolButton(Tool.SMOOTH, has_alternates=True)
        self.button_group.addButton(self.buttons[Tool.SMOOTH])

        self.buttons[Tool.SELECTION].setChecked(True)
        self.button_group.buttonClicked.connect(self._on_button_clicked)

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
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
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
        text_btn = self.buttons[Tool.TEXT]
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
        for tool in (Tool.DIRECT_SELECTION, Tool.GROUP_SELECTION):
            label = "Direct Selection" if tool == Tool.DIRECT_SELECTION else "Group Selection"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._arrow_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_arrow_slot(t))
        btn = self.buttons[self._arrow_slot_tool]
        menu.exec(btn.mapToGlobal(QPoint(0, btn.height())))

    def _show_pen_slot_menu(self):
        menu = QMenu(self)
        for tool in (Tool.PEN, Tool.ADD_ANCHOR_POINT, Tool.DELETE_ANCHOR_POINT):
            label = {Tool.PEN: "Pen", Tool.ADD_ANCHOR_POINT: "Add Anchor Point",
                     Tool.DELETE_ANCHOR_POINT: "Delete Anchor Point"}[tool]
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
        for tool in (Tool.TEXT, Tool.TEXT_PATH):
            label = "Text" if tool == Tool.TEXT else "Text on Path"
            action = menu.addAction(label)
            action.setCheckable(True)
            action.setChecked(tool == self._text_slot_tool)
            action.triggered.connect(lambda checked, t=tool: self._switch_text_slot(t))
        btn = self.buttons[Tool.TEXT]
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
        arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
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
        text_btn = self.buttons[Tool.TEXT]
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
            arrow_btn = self.buttons[Tool.DIRECT_SELECTION]
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
            text_btn = self.buttons[Tool.TEXT]
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
