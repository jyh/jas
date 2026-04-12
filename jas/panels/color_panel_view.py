"""Color panel body widget: swatches, sliders, hex input, color bar."""

from __future__ import annotations

from PySide6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QLabel,
                                QSlider, QLineEdit, QPushButton)
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QPainter, QImage, QMouseEvent

from geometry.element import Color, Fill, Stroke
from panels.panel_menu import (set_active_color, set_active_color_live,
                                push_recent_color, COLOR_MODE_COMMANDS)
from workspace.dock_panel import (THEME_TEXT, THEME_TEXT_DIM, THEME_TEXT_BODY,
                                   THEME_BG_DARK, THEME_BORDER)


# ---------------------------------------------------------------------------
# Panel color state
# ---------------------------------------------------------------------------

class PanelColorState:
    def __init__(self):
        self.h = 0.0; self.s = 0.0; self.b = 100.0
        self.r = 255.0; self.g = 255.0; self.bl = 255.0
        self.c = 0.0; self.m = 0.0; self.y = 0.0; self.k = 0.0
        self.hex = "ffffff"

    def sync_from_color(self, color: Color):
        r, g, b, _ = color.to_rgba()
        self.r = round(r * 255); self.g = round(g * 255); self.bl = round(b * 255)
        h, s, br, _ = color.to_hsba()
        self.h = round(h); self.s = round(s * 100); self.b = round(br * 100)
        c, m, y, k, _ = color.to_cmyka()
        self.c = round(c * 100); self.m = round(m * 100)
        self.y = round(y * 100); self.k = round(k * 100)
        self.hex = color.to_hex()

    def to_color(self, mode: str) -> Color:
        if mode == "hsb":
            return Color.hsb(self.h, self.s / 100, self.b / 100)
        elif mode in ("rgb", "web_safe_rgb"):
            return Color.rgb(self.r / 255, self.g / 255, self.bl / 255)
        elif mode == "cmyk":
            return Color.cmyk(self.c / 100, self.m / 100, self.y / 100, self.k / 100)
        else:  # grayscale
            v = 1.0 - self.k / 100
            return Color.rgb(v, v, v)

    def get(self, field: str) -> float:
        return getattr(self, field, 0.0)

    def set(self, field: str, val: float):
        setattr(self, field, val)


# ---------------------------------------------------------------------------
# Color bar widget
# ---------------------------------------------------------------------------

class ColorBarWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFixedHeight(64)
        self.setMinimumWidth(50)
        self._on_click = None
        self._on_drag = None
        self._on_release = None
        self._dragging = False

    def set_callbacks(self, on_click, on_drag, on_release):
        self._on_click = on_click
        self._on_drag = on_drag
        self._on_release = on_release

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
                sat, br = t, 1.0 - t * 0.2
            else:
                t = (yf - mid_y) / (h - mid_y) if h > mid_y else 0
                sat, br = 1.0, 0.8 * (1.0 - t)
            for x in range(w):
                hue = 360.0 * x / w
                c = Color.hsb(hue, sat, br)
                rv, gv, bv, _ = c.to_rgba()
                img.setPixelColor(x, y, QColor(int(rv * 255), int(gv * 255), int(bv * 255)))
        painter.drawImage(0, 0, img)

    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            self._dragging = True
            if self._on_click:
                self._on_click(event.position().x(), event.position().y())

    def mouseMoveEvent(self, event: QMouseEvent):
        if self._dragging and self._on_drag:
            self._on_drag(event.position().x(), event.position().y())

    def mouseReleaseEvent(self, event: QMouseEvent):
        if self._dragging:
            self._dragging = False
            if self._on_release:
                self._on_release(event.position().x(), event.position().y())


# ---------------------------------------------------------------------------
# Color panel view
# ---------------------------------------------------------------------------

class ColorPanelView(QWidget):
    def __init__(self, layout, get_model, rebuild_fn, parent=None):
        super().__init__(parent)
        self._layout = layout
        self._get_model = get_model
        self._rebuild_fn = rebuild_fn
        self._ps = PanelColorState()
        self._last_synced_hex = ""
        self._slider_widgets = []

        vbox = QVBoxLayout(self)
        vbox.setContentsMargins(4, 4, 4, 4)
        vbox.setSpacing(6)

        self._build_swatches(vbox)
        self._sliders_container = QWidget()
        self._sliders_layout = QVBoxLayout(self._sliders_container)
        self._sliders_layout.setContentsMargins(0, 0, 0, 0)
        self._sliders_layout.setSpacing(2)
        vbox.addWidget(self._sliders_container)
        self._build_sliders()
        self._build_hex_row(vbox)
        self._build_color_bar(vbox)

        self._sync()

    @property
    def _mode(self): return self._layout.color_panel_mode

    @property
    def _model(self): return self._get_model()

    @property
    def _fill_on_top(self):
        m = self._model
        return m.fill_on_top if m else True

    @property
    def _active_color(self):
        m = self._model
        if m is None:
            return None
        if m.fill_on_top:
            return m.default_fill.color if m.default_fill else None
        else:
            return m.default_stroke.color if m.default_stroke else None

    def _sync(self):
        color = self._active_color
        hex_val = color.to_hex() if color else ""
        if hex_val != self._last_synced_hex:
            if color:
                self._ps.sync_from_color(color)
            self._last_synced_hex = hex_val
            self._update_ui()

    def _update_ui(self):
        if hasattr(self, '_hex_entry'):
            self._hex_entry.setText(self._ps.hex)
        self._update_recent_swatches()

    # -- Swatches row --

    def _build_swatches(self, parent_layout):
        row = QHBoxLayout()
        row.setSpacing(2)

        # None
        none_btn = QPushButton("\u2205")
        none_btn.setFixedSize(16, 16)
        none_btn.setStyleSheet(f"font-size:12px; color:red; background:{THEME_BG_DARK}; border:1px solid {THEME_BORDER}; padding:0;")
        none_btn.clicked.connect(self._on_none)
        row.addWidget(none_btn)

        # Black
        black_btn = QPushButton()
        black_btn.setFixedSize(16, 16)
        black_btn.setStyleSheet("background:#000; border:1px solid #888; padding:0;")
        black_btn.clicked.connect(lambda: self._set_color(Color.BLACK))
        row.addWidget(black_btn)

        # White
        white_btn = QPushButton()
        white_btn.setFixedSize(16, 16)
        white_btn.setStyleSheet("background:#fff; border:1px solid #888; padding:0;")
        white_btn.clicked.connect(lambda: self._set_color(Color.WHITE))
        row.addWidget(white_btn)

        # Separator
        sep = QWidget()
        sep.setFixedSize(1, 16)
        sep.setStyleSheet(f"background:{THEME_BORDER};")
        row.addWidget(sep)

        # Recent swatches
        self._recent_btns = []
        for i in range(10):
            btn = QPushButton()
            btn.setFixedSize(16, 16)
            btn.setStyleSheet(f"background:transparent; border:1px solid {THEME_BORDER}; padding:0;")
            idx = i
            btn.clicked.connect(lambda checked=False, ii=idx: self._on_recent(ii))
            row.addWidget(btn)
            self._recent_btns.append(btn)

        row.addStretch()
        parent_layout.addLayout(row)

    def _update_recent_swatches(self):
        rc = self._model.recent_colors
        for i, btn in enumerate(self._recent_btns):
            if i < len(rc):
                btn.setStyleSheet(f"background:#{rc[i]}; border:1px solid #888; padding:0;")
            else:
                btn.setStyleSheet(f"background:transparent; border:1px solid {THEME_BORDER}; padding:0;")

    def _on_none(self):
        m = self._model
        if m is None:
            return
        if m.fill_on_top:
            m.default_fill = None
        else:
            m.default_stroke = None
        self._rebuild_fn()

    def _on_recent(self, idx):
        rc = self._model.recent_colors
        if idx < len(rc):
            color = Color.from_hex(rc[idx])
            if color:
                self._set_color(color)

    def _set_color(self, color):
        m = self._model
        if m is None:
            return
        set_active_color(color, m)
        self._rebuild_fn()

    # -- Sliders --

    def _build_sliders(self):
        # Clear
        while self._sliders_layout.count():
            item = self._sliders_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._slider_widgets = []

        mode = self._mode
        if mode == "grayscale":
            self._add_slider("K", "k", 0, 100, 1, "%")
        elif mode == "hsb":
            self._add_slider("H", "h", 0, 360, 1, "\u00B0")
            self._add_slider("S", "s", 0, 100, 1, "%")
            self._add_slider("B", "b", 0, 100, 1, "%")
        elif mode == "rgb":
            self._add_slider("R", "r", 0, 255, 1, "")
            self._add_slider("G", "g", 0, 255, 1, "")
            self._add_slider("B", "bl", 0, 255, 1, "")
        elif mode == "cmyk":
            self._add_slider("C", "c", 0, 100, 1, "%")
            self._add_slider("M", "m", 0, 100, 1, "%")
            self._add_slider("Y", "y", 0, 100, 1, "%")
            self._add_slider("K", "k", 0, 100, 1, "%")
        elif mode == "web_safe_rgb":
            self._add_slider("R", "r", 0, 255, 51, "")
            self._add_slider("G", "g", 0, 255, 51, "")
            self._add_slider("B", "bl", 0, 255, 51, "")

    def _add_slider(self, label, field, min_val, max_val, step, suffix):
        row = QWidget()
        hbox = QHBoxLayout(row)
        hbox.setContentsMargins(0, 0, 0, 0)
        hbox.setSpacing(4)

        lbl = QLabel(label)
        lbl.setFixedWidth(10)
        lbl.setStyleSheet(f"color:{THEME_TEXT}; font-size:10px;")
        lbl.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        hbox.addWidget(lbl)

        slider = QSlider(Qt.Horizontal)
        slider.setMinimum(min_val)
        slider.setMaximum(max_val)
        slider.setSingleStep(step)
        slider.setValue(int(self._ps.get(field)))
        hbox.addWidget(slider, 1)

        val_lbl = QLabel(str(int(self._ps.get(field))))
        val_lbl.setFixedWidth(30)
        val_lbl.setStyleSheet(f"color:{THEME_TEXT}; font-size:10px;")
        val_lbl.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        hbox.addWidget(val_lbl)

        if suffix:
            sfx_lbl = QLabel(suffix)
            sfx_lbl.setStyleSheet(f"color:{THEME_TEXT_DIM}; font-size:10px;")
            hbox.addWidget(sfx_lbl)

        slider.valueChanged.connect(
            lambda v, f=field, vl=val_lbl: self._on_slider(f, v, vl))

        self._sliders_layout.addWidget(row)
        self._slider_widgets.append((field, slider, val_lbl))

    def _on_slider(self, field, value, val_label):
        self._ps.set(field, float(value))
        color = self._ps.to_color(self._mode)
        self._ps.sync_from_color(color)
        self._ps.set(field, float(value))
        self._last_synced_hex = color.to_hex()
        val_label.setText(str(value))
        set_active_color_live(color, self._model)

    # -- Hex row --

    def _build_hex_row(self, parent_layout):
        row = QHBoxLayout()
        row.setSpacing(2)
        hash_lbl = QLabel("#")
        hash_lbl.setStyleSheet(f"color:{THEME_TEXT}; font-size:10px;")
        row.addWidget(hash_lbl)

        self._hex_entry = QLineEdit(self._ps.hex)
        self._hex_entry.setMaxLength(6)
        self._hex_entry.setFixedWidth(52)
        self._hex_entry.setStyleSheet(
            f"background:{THEME_BG_DARK}; color:{THEME_TEXT}; "
            f"border:1px solid {THEME_BORDER}; font-size:10px; font-family:monospace; padding:2px 4px;")
        self._hex_entry.returnPressed.connect(self._on_hex_commit)
        row.addWidget(self._hex_entry)
        row.addStretch()
        parent_layout.addLayout(row)

    def _on_hex_commit(self):
        raw = self._hex_entry.text().strip().lstrip("#")
        if len(raw) == 6 and all(c in "0123456789abcdefABCDEF" for c in raw):
            color = Color.from_hex(raw)
            if color:
                self._ps.sync_from_color(color)
                self._last_synced_hex = color.to_hex()
                set_active_color(color, self._model)
                self._rebuild_fn()

    # -- Color bar --

    def _build_color_bar(self, parent_layout):
        self._color_bar = ColorBarWidget()
        self._color_bar.set_callbacks(
            on_click=lambda x, y: self._bar_point(x, y, False),
            on_drag=lambda x, y: self._bar_point(x, y, False),
            on_release=lambda x, y: self._bar_point(x, y, True),
        )
        parent_layout.addWidget(self._color_bar)

    def _bar_point(self, x, y, commit):
        w = max(self._color_bar.width(), 1)
        h = max(self._color_bar.height(), 1)
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

        color = Color.hsb(hue, sat / 100, br / 100)
        self._ps.sync_from_color(color)
        self._ps.h = round(hue)
        self._ps.s = round(sat)
        self._ps.b = round(br)
        self._last_synced_hex = color.to_hex()

        if commit:
            set_active_color(color, self._model)
            self._rebuild_fn()
        else:
            set_active_color_live(color, self._model)
