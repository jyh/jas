"""Color picker dialog and state.

Provides a ColorPickerState class for managing the current working color
and a ColorPickerDialog (QDialog) with a 2D gradient, vertical colorbar,
radio buttons for H/S/B/R/G/Blue, text inputs for HSB/RGB/CMYK/hex,
color swatch preview, eyedropper, and web-safe snap.
"""

from enum import Enum, auto

from geometry.element import Color, RgbColor, HsbColor, CmykColor


# ---------------------------------------------------------------------------
# Radio channel
# ---------------------------------------------------------------------------

class RadioChannel(Enum):
    H = auto()
    S = auto()
    B = auto()
    R = auto()
    G = auto()
    BLUE = auto()


# ---------------------------------------------------------------------------
# Web-safe snap
# ---------------------------------------------------------------------------

def snap_web(v: float) -> float:
    """Snap a 0..1 component to the nearest web-safe value."""
    steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
    best = steps[0]
    for s in steps:
        if abs(v - s) < abs(v - best):
            best = s
    return best


# ---------------------------------------------------------------------------
# Color picker state
# ---------------------------------------------------------------------------

class ColorPickerState:
    """Mutable state for the color picker dialog.

    Stores the current working color as internal RGB (0..1) with preserved
    hue and saturation so they survive when brightness or saturation is zero.
    """

    def __init__(self, color: Color, for_fill: bool = True):
        r, g, b, _ = color.to_rgba()
        h, s, _, _ = color.to_hsba()
        self._r = r
        self._g = g
        self._b = b
        self._hue = h
        self._sat = s
        self.for_fill = for_fill
        self.radio: RadioChannel = RadioChannel.H
        self.web_only: bool = False
        self.eyedropper_active: bool = False

    # -- Internal helpers --

    def _sync_hue_sat(self) -> None:
        """Update preserved hue/sat from current RGB when meaningful."""
        h, s, br, _ = RgbColor(self._r, self._g, self._b).to_hsba()
        if br > 0.001 and s > 0.001:
            self._hue = h
        if br > 0.001:
            self._sat = s

    def _snap_to_web(self) -> None:
        self._r = snap_web(self._r)
        self._g = snap_web(self._g)
        self._b = snap_web(self._b)

    # -- Setters --

    def set_rgb(self, r: int, g: int, b: int) -> None:
        """Set from RGB 0-255 integer values."""
        self._r = r / 255.0
        self._g = g / 255.0
        self._b = b / 255.0
        if self.web_only:
            self._snap_to_web()
        self._sync_hue_sat()

    def set_hsb(self, h: float, s: float, b: float) -> None:
        """Set from HSB (h: 0-360, s: 0-100, b: 0-100)."""
        self._hue = h
        self._sat = s / 100.0
        c = HsbColor(h, s / 100.0, b / 100.0)
        r, g, bl, _ = c.to_rgba()
        self._r = r
        self._g = g
        self._b = bl
        if self.web_only:
            self._snap_to_web()

    def set_cmyk(self, c: float, m: float, y: float, k: float) -> None:
        """Set from CMYK (all 0-100)."""
        color = CmykColor(c / 100.0, m / 100.0, y / 100.0, k / 100.0)
        r, g, b, _ = color.to_rgba()
        self._r = r
        self._g = g
        self._b = b
        if self.web_only:
            self._snap_to_web()
        self._sync_hue_sat()

    def set_hex(self, hex_str: str) -> None:
        """Set from 6-char hex string (optional # prefix)."""
        c = Color.from_hex(hex_str)
        if c is not None:
            r, g, b, _ = c.to_rgba()
            self._r = r
            self._g = g
            self._b = b
            if self.web_only:
                self._snap_to_web()
            self._sync_hue_sat()

    # -- Getters --

    def color(self) -> Color:
        """Get the current color as an RgbColor."""
        return RgbColor(self._r, self._g, self._b)

    def rgb_u8(self) -> tuple[int, int, int]:
        """Get RGB values as 0-255 integers."""
        return (
            round(self._r * 255.0),
            round(self._g * 255.0),
            round(self._b * 255.0),
        )

    def hsb_vals(self) -> tuple[float, float, float]:
        """Get HSB values (h: 0-360, s: 0-100, b: 0-100).

        Uses preserved hue/sat when the derived values would be lost.
        """
        dh, ds, db, _ = RgbColor(self._r, self._g, self._b).to_hsba()
        h = self._hue if db < 0.001 or ds < 0.001 else dh
        s = self._sat if db < 0.001 else ds
        return (h, s * 100.0, db * 100.0)

    def cmyk_vals(self) -> tuple[float, float, float, float]:
        """Get CMYK values (all 0-100)."""
        c, m, y, k, _ = RgbColor(self._r, self._g, self._b).to_cmyka()
        return (c * 100.0, m * 100.0, y * 100.0, k * 100.0)

    def hex_str(self) -> str:
        """Get hex string (no # prefix)."""
        return RgbColor(self._r, self._g, self._b).to_hex()

    # -- Gradient / colorbar --

    def set_from_gradient(self, x: float, y: float) -> None:
        """Set color from gradient position (x, y normalized 0..1)."""
        x = max(0.0, min(1.0, x))
        y = max(0.0, min(1.0, y))
        if self.radio == RadioChannel.H:
            self._sat = x
            c = HsbColor(self._hue, x, 1.0 - y)
            r, g, b, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, b
        elif self.radio == RadioChannel.S:
            self._hue = x * 360.0
            c = HsbColor(x * 360.0, self._sat, 1.0 - y)
            r, g, b, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, b
        elif self.radio == RadioChannel.B:
            self._hue = x * 360.0
            self._sat = 1.0 - y
            _, _, br, _ = RgbColor(self._r, self._g, self._b).to_hsba()
            c = HsbColor(x * 360.0, 1.0 - y, br)
            r, g, b, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, b
        elif self.radio == RadioChannel.R:
            self._b = x
            self._g = 1.0 - y
            self._sync_hue_sat()
        elif self.radio == RadioChannel.G:
            self._b = x
            self._r = 1.0 - y
            self._sync_hue_sat()
        elif self.radio == RadioChannel.BLUE:
            self._r = x
            self._g = 1.0 - y
            self._sync_hue_sat()
        if self.web_only:
            self._snap_to_web()

    def set_from_colorbar(self, t: float) -> None:
        """Set color from colorbar position (t: 0..1, 0=top, 1=bottom)."""
        t = max(0.0, min(1.0, t))
        if self.radio == RadioChannel.H:
            self._hue = t * 360.0
            _, _, br, _ = RgbColor(self._r, self._g, self._b).to_hsba()
            c = HsbColor(t * 360.0, self._sat, br)
            r, g, bl, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, bl
        elif self.radio == RadioChannel.S:
            self._sat = 1.0 - t
            _, _, br, _ = RgbColor(self._r, self._g, self._b).to_hsba()
            c = HsbColor(self._hue, 1.0 - t, br)
            r, g, bl, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, bl
        elif self.radio == RadioChannel.B:
            c = HsbColor(self._hue, self._sat, 1.0 - t)
            r, g, bl, _ = c.to_rgba()
            self._r, self._g, self._b = r, g, bl
        elif self.radio == RadioChannel.R:
            self._r = 1.0 - t
            self._sync_hue_sat()
        elif self.radio == RadioChannel.G:
            self._g = 1.0 - t
            self._sync_hue_sat()
        elif self.radio == RadioChannel.BLUE:
            self._b = 1.0 - t
            self._sync_hue_sat()
        if self.web_only:
            self._snap_to_web()

    def colorbar_pos(self) -> float:
        """Get colorbar position (0..1, 0=top) for current color."""
        if self.radio == RadioChannel.H:
            return self._hue / 360.0
        elif self.radio == RadioChannel.S:
            return 1.0 - self._sat
        elif self.radio == RadioChannel.B:
            _, _, b, _ = RgbColor(self._r, self._g, self._b).to_hsba()
            return 1.0 - b
        elif self.radio == RadioChannel.R:
            return 1.0 - self._r
        elif self.radio == RadioChannel.G:
            return 1.0 - self._g
        elif self.radio == RadioChannel.BLUE:
            return 1.0 - self._b
        return 0.0

    def gradient_pos(self) -> tuple[float, float]:
        """Get gradient position (x, y: 0..1) for current color."""
        _, _, db, _ = RgbColor(self._r, self._g, self._b).to_hsba()
        if self.radio == RadioChannel.H:
            return (self._sat, 1.0 - db)
        elif self.radio == RadioChannel.S:
            return (self._hue / 360.0, 1.0 - db)
        elif self.radio == RadioChannel.B:
            return (self._hue / 360.0, 1.0 - self._sat)
        elif self.radio == RadioChannel.R:
            return (self._b, 1.0 - self._g)
        elif self.radio == RadioChannel.G:
            return (self._b, 1.0 - self._r)
        elif self.radio == RadioChannel.BLUE:
            return (self._r, 1.0 - self._g)
        return (0.0, 0.0)


# ---------------------------------------------------------------------------
# Color picker dialog (Qt)
# ---------------------------------------------------------------------------

from PySide6.QtCore import Qt, Signal, QPoint, QSize
from PySide6.QtGui import (
    QColor, QImage, QMouseEvent, QPainter, QPen, QBrush, QPainterPath,
)
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QGridLayout,
    QHBoxLayout, QLabel, QLineEdit, QPushButton, QRadioButton,
    QVBoxLayout, QWidget,
)


GRADIENT_SIZE = 256
COLORBAR_WIDTH = 20
COLORBAR_HEIGHT = GRADIENT_SIZE


class GradientWidget(QWidget):
    """2D color gradient rendered via QImage."""

    clicked = Signal(float, float)  # normalized x, y

    def __init__(self, state: ColorPickerState, parent=None):
        super().__init__(parent)
        self._state = state
        self.setFixedSize(GRADIENT_SIZE, GRADIENT_SIZE)
        self._dragging = False

    def paintEvent(self, event):
        img = QImage(GRADIENT_SIZE, GRADIENT_SIZE, QImage.Format.Format_RGB32)
        radio = self._state.radio
        for py in range(GRADIENT_SIZE):
            ny = py / (GRADIENT_SIZE - 1)
            for px in range(GRADIENT_SIZE):
                nx = px / (GRADIENT_SIZE - 1)
                r, g, b = self._pixel_color(nx, ny, radio)
                img.setPixelColor(px, py, QColor(
                    max(0, min(255, round(r * 255))),
                    max(0, min(255, round(g * 255))),
                    max(0, min(255, round(b * 255))),
                ))
        painter = QPainter(self)
        painter.drawImage(0, 0, img)
        # Draw crosshair at current position
        gx, gy = self._state.gradient_pos()
        cx = int(gx * (GRADIENT_SIZE - 1))
        cy = int(gy * (GRADIENT_SIZE - 1))
        painter.setPen(QPen(QColor(255, 255, 255), 1))
        painter.drawEllipse(QPoint(cx, cy), 5, 5)
        painter.setPen(QPen(QColor(0, 0, 0), 1))
        painter.drawEllipse(QPoint(cx, cy), 6, 6)

    def _pixel_color(self, nx: float, ny: float,
                     radio: RadioChannel) -> tuple[float, float, float]:
        if radio == RadioChannel.H:
            c = HsbColor(self._state._hue, nx, 1.0 - ny)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.S:
            c = HsbColor(nx * 360.0, self._state._sat, 1.0 - ny)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.B:
            _, _, br, _ = RgbColor(
                self._state._r, self._state._g, self._state._b).to_hsba()
            c = HsbColor(nx * 360.0, 1.0 - ny, br)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.R:
            return self._state._r, 1.0 - ny, nx
        elif radio == RadioChannel.G:
            return 1.0 - ny, self._state._g, nx
        elif radio == RadioChannel.BLUE:
            return nx, 1.0 - ny, self._state._b
        return 0, 0, 0

    def mousePressEvent(self, event: QMouseEvent):
        self._dragging = True
        self._emit_pos(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._dragging:
            self._emit_pos(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        self._dragging = False

    def _emit_pos(self, event: QMouseEvent):
        x = event.position().x() / (GRADIENT_SIZE - 1)
        y = event.position().y() / (GRADIENT_SIZE - 1)
        self.clicked.emit(max(0.0, min(1.0, x)), max(0.0, min(1.0, y)))


class ColorbarWidget(QWidget):
    """Vertical colorbar with draggable slider."""

    clicked = Signal(float)  # normalized t (0=top)

    def __init__(self, state: ColorPickerState, parent=None):
        super().__init__(parent)
        self._state = state
        self.setFixedSize(COLORBAR_WIDTH, COLORBAR_HEIGHT)
        self._dragging = False

    def paintEvent(self, event):
        img = QImage(1, COLORBAR_HEIGHT, QImage.Format.Format_RGB32)
        radio = self._state.radio
        for py in range(COLORBAR_HEIGHT):
            t = py / (COLORBAR_HEIGHT - 1)
            r, g, b = self._bar_color(t, radio)
            img.setPixelColor(0, py, QColor(
                max(0, min(255, round(r * 255))),
                max(0, min(255, round(g * 255))),
                max(0, min(255, round(b * 255))),
            ))
        painter = QPainter(self)
        painter.drawImage(0, 0, img.scaled(COLORBAR_WIDTH, COLORBAR_HEIGHT))
        # Draw slider arrow
        pos = self._state.colorbar_pos()
        cy = int(pos * (COLORBAR_HEIGHT - 1))
        painter.setPen(QPen(QColor(0, 0, 0), 1))
        # Left arrow
        path = QPainterPath()
        path.moveTo(0, cy - 4)
        path.lineTo(0, cy + 4)
        path.lineTo(4, cy)
        path.closeSubpath()
        painter.fillPath(path, QColor(0, 0, 0))
        # Right arrow
        path2 = QPainterPath()
        path2.moveTo(COLORBAR_WIDTH, cy - 4)
        path2.lineTo(COLORBAR_WIDTH, cy + 4)
        path2.lineTo(COLORBAR_WIDTH - 4, cy)
        path2.closeSubpath()
        painter.fillPath(path2, QColor(0, 0, 0))

    def _bar_color(self, t: float,
                   radio: RadioChannel) -> tuple[float, float, float]:
        if radio == RadioChannel.H:
            c = HsbColor(t * 360.0, 1.0, 1.0)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.S:
            c = HsbColor(self._state._hue, 1.0 - t, 1.0)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.B:
            c = HsbColor(self._state._hue, self._state._sat, 1.0 - t)
            r, g, b, _ = c.to_rgba()
            return r, g, b
        elif radio == RadioChannel.R:
            return 1.0 - t, self._state._g, self._state._b
        elif radio == RadioChannel.G:
            return self._state._r, 1.0 - t, self._state._b
        elif radio == RadioChannel.BLUE:
            return self._state._r, self._state._g, 1.0 - t
        return 0, 0, 0

    def mousePressEvent(self, event: QMouseEvent):
        self._dragging = True
        self._emit_pos(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._dragging:
            self._emit_pos(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        self._dragging = False

    def _emit_pos(self, event: QMouseEvent):
        t = event.position().y() / (COLORBAR_HEIGHT - 1)
        self.clicked.emit(max(0.0, min(1.0, t)))


class SwatchWidget(QWidget):
    """Color swatch showing old and new color."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedSize(60, 60)
        self._old_color = QColor(0, 0, 0)
        self._new_color = QColor(0, 0, 0)

    def set_old_color(self, color: QColor):
        self._old_color = color
        self.update()

    def set_new_color(self, color: QColor):
        self._new_color = color
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        w, h = self.width(), self.height()
        # Old color (bottom half)
        painter.fillRect(0, h // 2, w, h - h // 2, self._old_color)
        # New color (top half)
        painter.fillRect(0, 0, w, h // 2, self._new_color)
        painter.setPen(QPen(QColor(128, 128, 128), 1))
        painter.drawRect(0, 0, w - 1, h - 1)


class ColorPickerDialog(QDialog):
    """Full color picker dialog matching the standard vector illustration application layout."""

    def __init__(self, initial_color: Color, for_fill: bool = True,
                 parent=None):
        super().__init__(parent)
        self.setWindowTitle("Select Color")
        self._state = ColorPickerState(initial_color, for_fill=for_fill)
        self._initial_color = initial_color
        self._build_ui()
        self._connect_signals()
        self._sync_ui()

    def _build_ui(self):
        main_layout = QHBoxLayout(self)

        # Left column: title + gradient/colorbar + Only Web Colors
        left = QVBoxLayout()
        top_row = QHBoxLayout()
        lbl = QLabel("Select Color:")
        lbl.setStyleSheet("font-weight: bold;")
        top_row.addWidget(lbl)
        # Eyedropper button with pipette icon
        self._eyedropper_btn = QPushButton("\U0001f4a7")
        self._eyedropper_btn.setFixedSize(24, 24)
        self._eyedropper_btn.setToolTip("Sample a color from the screen")
        top_row.addWidget(self._eyedropper_btn)
        top_row.addStretch()
        left.addLayout(top_row)

        gradient_row = QHBoxLayout()
        self._gradient = GradientWidget(self._state)
        gradient_row.addWidget(self._gradient)
        gradient_row.addSpacing(4)
        self._colorbar = ColorbarWidget(self._state)
        gradient_row.addWidget(self._colorbar)
        left.addLayout(gradient_row)

        self._web_only_cb = QCheckBox("Only Web Colors")
        left.addWidget(self._web_only_cb)
        main_layout.addLayout(left)
        main_layout.addSpacing(12)

        # Right column: swatch + HSB/buttons + RGB/CMYK + hex
        right_col = QVBoxLayout()

        # Color swatch (above HSB)
        self._swatch = SwatchWidget()
        r, g, b, _ = self._initial_color.to_rgba()
        qc = QColor(round(r * 255), round(g * 255), round(b * 255))
        self._swatch.set_old_color(qc)
        self._swatch.set_new_color(qc)
        right_col.addWidget(self._swatch)
        right_col.addSpacing(4)

        # HSB on left, OK/Cancel on right
        hsb_buttons = QHBoxLayout()

        hsb_grid = QGridLayout()
        self._radios = {}
        self._inputs = {}
        for row, (ch, label) in enumerate([
            (RadioChannel.H, "H:"),
            (RadioChannel.S, "S:"),
            (RadioChannel.B, "B:"),
        ]):
            radio = QRadioButton(label)
            if ch == RadioChannel.H:
                radio.setChecked(True)
            self._radios[ch] = radio
            hsb_grid.addWidget(radio, row, 0)
            inp = QLineEdit()
            inp.setFixedWidth(50)
            self._inputs[ch] = inp
            hsb_grid.addWidget(inp, row, 1)
            suffix = QLabel("\u00b0" if ch == RadioChannel.H else "%")
            hsb_grid.addWidget(suffix, row, 2)
        hsb_buttons.addLayout(hsb_grid)
        hsb_buttons.addSpacing(12)

        # OK/Cancel/Swatches buttons
        btn_col = QVBoxLayout()
        ok_btn = QPushButton("OK")
        ok_btn.setFixedWidth(80)
        ok_btn.clicked.connect(self.accept)
        btn_col.addWidget(ok_btn)
        cancel_btn = QPushButton("Cancel")
        cancel_btn.setFixedWidth(80)
        cancel_btn.clicked.connect(self.reject)
        btn_col.addWidget(cancel_btn)
        swatches_btn = QPushButton("Color Swatches")
        swatches_btn.setFixedWidth(80)
        swatches_btn.setEnabled(False)
        btn_col.addWidget(swatches_btn)
        hsb_buttons.addLayout(btn_col)

        right_col.addLayout(hsb_buttons)

        # RGB + CMYK side by side
        rgb_cmyk = QHBoxLayout()
        rgb_grid = QGridLayout()
        for row, (ch, label) in enumerate([
            (RadioChannel.R, "R:"),
            (RadioChannel.G, "G:"),
            (RadioChannel.BLUE, "B:"),
        ]):
            radio = QRadioButton(label)
            self._radios[ch] = radio
            rgb_grid.addWidget(radio, row, 0)
            inp = QLineEdit()
            inp.setFixedWidth(50)
            self._inputs[ch] = inp
            rgb_grid.addWidget(inp, row, 1)
        rgb_cmyk.addLayout(rgb_grid)
        rgb_cmyk.addSpacing(8)

        cmyk_grid = QGridLayout()
        self._cmyk_inputs = {}
        for row, label in enumerate(["C:", "M:", "Y:", "K:"]):
            cmyk_grid.addWidget(QLabel(label), row, 0)
            inp = QLineEdit()
            inp.setFixedWidth(50)
            self._cmyk_inputs[label[0]] = inp
            cmyk_grid.addWidget(inp, row, 1)
            cmyk_grid.addWidget(QLabel("%"), row, 2)
        rgb_cmyk.addLayout(cmyk_grid)

        right_col.addLayout(rgb_cmyk)

        # Hex
        hex_row = QHBoxLayout()
        hex_row.addWidget(QLabel("#"))
        self._hex_input = QLineEdit()
        self._hex_input.setFixedWidth(70)
        hex_row.addWidget(self._hex_input)
        hex_row.addStretch()
        right_col.addLayout(hex_row)

        main_layout.addLayout(right_col)

    def _connect_signals(self):
        self._gradient.clicked.connect(self._on_gradient_click)
        self._colorbar.clicked.connect(self._on_colorbar_click)
        self._eyedropper_btn.clicked.connect(self._start_eyedropper)
        self._web_only_cb.toggled.connect(self._on_web_only_changed)

        for ch, radio in self._radios.items():
            radio.toggled.connect(lambda checked, c=ch: self._on_radio_changed(c, checked))

        # HSB inputs
        self._inputs[RadioChannel.H].editingFinished.connect(
            lambda: self._on_hsb_input())
        self._inputs[RadioChannel.S].editingFinished.connect(
            lambda: self._on_hsb_input())
        self._inputs[RadioChannel.B].editingFinished.connect(
            lambda: self._on_hsb_input())

        # RGB inputs
        self._inputs[RadioChannel.R].editingFinished.connect(
            lambda: self._on_rgb_input())
        self._inputs[RadioChannel.G].editingFinished.connect(
            lambda: self._on_rgb_input())
        self._inputs[RadioChannel.BLUE].editingFinished.connect(
            lambda: self._on_rgb_input())

        # CMYK inputs
        for key in "CMYK":
            self._cmyk_inputs[key].editingFinished.connect(
                lambda: self._on_cmyk_input())

        # Hex input
        self._hex_input.editingFinished.connect(self._on_hex_input)

    def _on_gradient_click(self, x: float, y: float):
        self._state.set_from_gradient(x, y)
        self._sync_ui()

    def _on_colorbar_click(self, t: float):
        self._state.set_from_colorbar(t)
        self._sync_ui()

    def _on_radio_changed(self, channel: RadioChannel, checked: bool):
        if checked:
            self._state.radio = channel
            self._sync_ui()

    def _on_web_only_changed(self, checked: bool):
        self._state.web_only = checked
        if checked:
            # Re-snap current color
            r, g, b = self._state.rgb_u8()
            self._state.set_rgb(r, g, b)
            self._sync_ui()

    def _on_hsb_input(self):
        try:
            h = float(self._inputs[RadioChannel.H].text())
            s = float(self._inputs[RadioChannel.S].text())
            b = float(self._inputs[RadioChannel.B].text())
            self._state.set_hsb(h, s, b)
            self._sync_ui()
        except ValueError:
            pass

    def _on_rgb_input(self):
        try:
            r = int(self._inputs[RadioChannel.R].text())
            g = int(self._inputs[RadioChannel.G].text())
            b = int(self._inputs[RadioChannel.BLUE].text())
            self._state.set_rgb(r, g, b)
            self._sync_ui()
        except ValueError:
            pass

    def _on_cmyk_input(self):
        try:
            c = float(self._cmyk_inputs["C"].text())
            m = float(self._cmyk_inputs["M"].text())
            y = float(self._cmyk_inputs["Y"].text())
            k = float(self._cmyk_inputs["K"].text())
            self._state.set_cmyk(c, m, y, k)
            self._sync_ui()
        except ValueError:
            pass

    def _on_hex_input(self):
        self._state.set_hex(self._hex_input.text())
        self._sync_ui()

    def _start_eyedropper(self):
        """Capture a screenshot and sample the pixel at the next click."""
        screen = QApplication.primaryScreen()
        if screen is None:
            return
        self._state.eyedropper_active = True
        pixmap = screen.grabWindow(0)
        self._eyedropper_pixmap = pixmap
        self._eyedropper_widget = _EyedropperOverlay(pixmap, self._on_eyedropper_pick)
        self._eyedropper_widget.showFullScreen()

    def _on_eyedropper_pick(self, color: QColor):
        self._state.set_rgb(color.red(), color.green(), color.blue())
        self._state.eyedropper_active = False
        self._sync_ui()

    def _sync_ui(self):
        """Synchronize all UI elements from the current state."""
        # HSB
        h, s, b = self._state.hsb_vals()
        self._inputs[RadioChannel.H].setText(str(round(h)))
        self._inputs[RadioChannel.S].setText(str(round(s)))
        self._inputs[RadioChannel.B].setText(str(round(b)))

        # RGB
        r, g, bl = self._state.rgb_u8()
        self._inputs[RadioChannel.R].setText(str(r))
        self._inputs[RadioChannel.G].setText(str(g))
        self._inputs[RadioChannel.BLUE].setText(str(bl))

        # CMYK
        c, m, y, k = self._state.cmyk_vals()
        self._cmyk_inputs["C"].setText(str(round(c)))
        self._cmyk_inputs["M"].setText(str(round(m)))
        self._cmyk_inputs["Y"].setText(str(round(y)))
        self._cmyk_inputs["K"].setText(str(round(k)))

        # Hex
        self._hex_input.setText(self._state.hex_str())

        # Swatch
        qc = QColor(r, g, bl)
        self._swatch.set_new_color(qc)

        # Repaint gradient and colorbar
        self._gradient.update()
        self._colorbar.update()

    def selected_color(self) -> Color:
        """Return the selected color after dialog acceptance."""
        return self._state.color()


class _EyedropperOverlay(QWidget):
    """Full-screen transparent overlay for eyedropper sampling."""

    def __init__(self, pixmap, on_pick, parent=None):
        super().__init__(parent)
        self._pixmap = pixmap
        self._on_pick = on_pick
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setCursor(Qt.CursorShape.CrossCursor)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.drawPixmap(0, 0, self._pixmap)

    def mousePressEvent(self, event: QMouseEvent):
        x = int(event.globalPosition().x())
        y = int(event.globalPosition().y())
        img = self._pixmap.toImage()
        if 0 <= x < img.width() and 0 <= y < img.height():
            color = QColor(img.pixel(x, y))
        else:
            color = QColor(0, 0, 0)
        self._on_pick(color)
        self.close()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.close()
