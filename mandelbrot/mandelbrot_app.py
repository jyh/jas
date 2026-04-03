import sys
import math
import numpy as np
from concurrent.futures import ThreadPoolExecutor

from PySide6.QtCore import Qt, QTimer, QSize, QPointF, Signal, QThread
from PySide6.QtGui import QImage, QPainter, QColor
from PySide6.QtWidgets import (
    QApplication, QLabel, QMainWindow, QVBoxLayout, QWidget,
    QHBoxLayout, QPushButton, QSlider, QLineEdit,
)

import numba


INITIAL_SCALE = 3.5
LUT_SIZE = 4096

VIRIDIS = np.array([
    [0.267004, 0.004874, 0.329415],
    [0.282327, 0.040461, 0.380014],
    [0.282884, 0.085159, 0.419549],
    [0.271895, 0.128898, 0.449241],
    [0.253935, 0.170689, 0.470894],
    [0.233603, 0.210636, 0.485966],
    [0.213939, 0.248543, 0.495647],
    [0.196141, 0.284286, 0.501135],
    [0.179996, 0.318290, 0.503586],
    [0.165101, 0.350925, 0.503582],
    [0.151918, 0.382340, 0.501464],
    [0.140956, 0.412543, 0.497403],
    [0.133217, 0.441702, 0.491354],
    [0.129151, 0.469888, 0.483397],
    [0.130021, 0.497064, 0.473322],
    [0.136866, 0.523159, 0.461040],
    [0.152519, 0.548157, 0.446523],
    [0.178606, 0.571949, 0.429869],
    [0.214298, 0.594296, 0.411374],
    [0.258780, 0.614882, 0.391129],
    [0.310382, 0.633498, 0.369330],
    [0.366529, 0.649870, 0.346353],
    [0.424505, 0.663891, 0.322654],
    [0.483397, 0.675568, 0.298455],
    [0.543049, 0.684934, 0.273780],
    [0.603264, 0.692064, 0.248564],
    [0.663569, 0.697045, 0.222878],
    [0.723457, 0.700050, 0.196640],
    [0.782349, 0.701379, 0.169525],
    [0.839489, 0.701554, 0.141590],
    [0.894305, 0.701355, 0.112529],
    [0.993248, 0.906157, 0.143936],
], dtype=np.float32)


def viridis_color(t):
    """Interpolate VIRIDIS control points at scalar t in [0, 1]."""
    n = len(VIRIDIS)
    pos = t * (n - 1)
    i = int(min(pos, n - 2))
    f = pos - i
    return VIRIDIS[i] * (1.0 - f) + VIRIDIS[i + 1] * f


def build_viridis_lut(smoothed_cdf):
    """Build a uint8 RGB LUT of shape (LUT_SIZE, 3) from the smoothed CDF."""
    # smoothed_cdf[i] is in [0, 1]; map to viridis color
    # Vectorized: for each bin, interpolate viridis
    n = len(VIRIDIS)
    t = smoothed_cdf  # shape (LUT_SIZE,)
    pos = t * (n - 1)
    i = np.clip(pos.astype(np.int32), 0, n - 2)
    f = (pos - i).astype(np.float32)[:, np.newaxis]
    colors = VIRIDIS[i] * (1.0 - f) + VIRIDIS[i + 1] * f  # (LUT_SIZE, 3)
    return np.clip(colors * 255.0, 0, 255).astype(np.uint8)


@numba.njit(parallel=True, fastmath=True)
def compute_mandelbrot(xmin, xmax, ymin, ymax, width, height, max_iter):
    out = np.empty((height, width), dtype=np.float32)
    dx = (xmax - xmin) / width
    dy = (ymax - ymin) / height

    for j in numba.prange(height):
        cy = ymin + j * dy
        for i in range(width):
            cx = xmin + i * dx
            x = 0.0
            y = 0.0
            iter_count = 0
            while x * x + y * y <= 4.0 and iter_count < max_iter:
                xt = x * x - y * y + cx
                y = 2 * x * y + cy
                x = xt
                iter_count += 1

            if iter_count == max_iter:
                out[j, i] = float(max_iter)
            else:
                magnitude = x * x + y * y
                if magnitude <= 0.0:
                    out[j, i] = float(iter_count)
                else:
                    # Smooth iteration (continuous coloring)
                    mu = math.log(math.log(math.sqrt(magnitude)) / math.log(2.0)) / math.log(2.0)
                    out[j, i] = float(iter_count) + 1.0 - mu

    return out


def apply_viridis_histogram(iters, max_iter, smoothed_cdf):
    """
    Apply viridis colormap with histogram equalization.

    iters: float32 array shape (H, W); interior pixels have value == max_iter.
    max_iter: int
    smoothed_cdf: float32 array of shape (LUT_SIZE,), or None if first call.

    Returns (rgb_uint8 shape HxWx3, new_smoothed_cdf shape LUT_SIZE).
    """
    height, width = iters.shape

    interior_mask = (iters >= max_iter)
    escaped = iters[~interior_mask]

    # Build histogram over escaped pixels
    bins = np.clip((escaped / max_iter * LUT_SIZE).astype(np.int32), 0, LUT_SIZE - 1)
    histogram = np.bincount(bins, minlength=LUT_SIZE).astype(np.float64)

    escaped_count = len(escaped)

    # Compute CDF
    cdf = np.cumsum(histogram)
    if escaped_count > 0:
        cdf = (cdf / escaped_count).astype(np.float32)
    else:
        cdf = (np.arange(LUT_SIZE, dtype=np.float32) / (LUT_SIZE - 1))

    # Temporal smoothing
    if smoothed_cdf is None:
        new_smoothed_cdf = cdf.copy()
    else:
        alpha = np.float32(0.25)
        new_smoothed_cdf = alpha * cdf + (1.0 - alpha) * smoothed_cdf

    # Build viridis LUT
    lut = build_viridis_lut(new_smoothed_cdf)  # (LUT_SIZE, 3) uint8

    # Map pixels to colors
    pixel_bins = np.clip((iters / max_iter * LUT_SIZE).astype(np.int32), 0, LUT_SIZE - 1)
    rgb = lut[pixel_bins]  # (H, W, 3)

    # Interior pixels → black
    rgb[interior_mask] = 0

    return rgb, new_smoothed_cdf


class MandelbrotWidget(QWidget):
    new_image_ready = Signal(QImage)
    coords_changed = Signal(float, float, float)  # center_x, center_y, scale

    def __init__(self):
        super().__init__()
        self.center_x = -0.75
        self.center_y = 0.0
        self.scale = INITIAL_SCALE
        self.max_iter = 500

        self.dragging = False
        self.did_drag = False
        self.last_pos = None

        self.image = None

        self.smoothed_cdf = None

        self.executor = ThreadPoolExecutor(max_workers=1)
        self.future = None

        self.render_timer = QTimer(self)
        self.render_timer.setSingleShot(True)
        self.render_timer.timeout.connect(self._compute_fractal)

        self.new_image_ready.connect(self._apply_new_image)

        self.setMinimumSize(640, 480)

    def sizeHint(self):
        return QSize(1024, 768)

    def schedule_redraw(self):
        if self.render_timer.isActive():
            self.render_timer.stop()
        self.render_timer.start(20)

    def _emit_coords(self):
        self.coords_changed.emit(self.center_x, self.center_y, self.scale)

    def paintEvent(self, event):
        painter = QPainter(self)
        if self.image is not None:
            rect = self.rect()
            painter.drawImage(rect, self.image)
        else:
            painter.fillRect(self.rect(), QColor('black'))

    def _compute_fractal(self):
        if self.future is not None and not self.future.done():
            self.future.cancel()

        w = self.width()
        h = self.height()

        scale_x = self.scale
        scale_y = self.scale * (h / w)

        xmin = self.center_x - scale_x / 2
        xmax = self.center_x + scale_x / 2
        ymin = self.center_y - scale_y / 2
        ymax = self.center_y + scale_y / 2

        max_iter = self.max_iter
        smoothed_cdf = self.smoothed_cdf

        def job():
            iters = compute_mandelbrot(xmin, xmax, ymin, ymax, w, h, max_iter)
            iters = np.flipud(iters)
            rgb, new_cdf = apply_viridis_histogram(iters, max_iter, smoothed_cdf)
            rgb = np.ascontiguousarray(rgb)
            bytes_per_line = w * 3
            img = QImage(rgb.data, w, h, bytes_per_line, QImage.Format_RGB888).copy()
            return img, new_cdf

        self.future = self.executor.submit(job)
        self.future.add_done_callback(self._on_render_done)

    def _on_render_done(self, future):
        try:
            img, new_cdf = future.result()
            self.smoothed_cdf = new_cdf
            self.new_image_ready.emit(img)
        except Exception as e:
            print(f"Render failed: {e}")

    def _apply_new_image(self, img):
        self.image = img
        self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.dragging = True
            self.did_drag = False
            self.last_pos = event.position()

    def mouseMoveEvent(self, event):
        if self.dragging and self.last_pos is not None:
            self.did_drag = True
            delta = event.position() - self.last_pos
            self.last_pos = event.position()

            w = self.width()
            h = self.height()
            self.center_x -= float(delta.x()) / w * self.scale
            self.center_y += float(delta.y()) / h * (self.scale * (h / w))
            self._emit_coords()
            self.schedule_redraw()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.dragging = False
            if not self.did_drag:
                # Click-to-center: move clicked fractal coordinate to center
                pos = event.position()
                px = float(pos.x())
                py = float(pos.y())
                w = self.width()
                h = self.height()
                fx = (px / w - 0.5) * self.scale + self.center_x
                fy = (0.5 - py / h) * self.scale * (h / w) + self.center_y
                self.center_x = fx
                self.center_y = fy
                self._emit_coords()
                self.schedule_redraw()

    def wheelEvent(self, event):
        angle = event.angleDelta().y() / 120.0
        factor = 0.85 ** angle
        pos = event.position()
        w = self.width()
        h = self.height()

        mx = (pos.x() / w - 0.5) * self.scale + self.center_x
        my = (0.5 - pos.y() / h) * self.scale * (h / w) + self.center_y

        self.scale *= factor
        self.center_x = mx + (self.center_x - mx) * factor
        self.center_y = my + (self.center_y - my) * factor

        self._emit_coords()
        self.schedule_redraw()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Mandelbrot Explorer')

        self.mandel = MandelbrotWidget()

        # Coordinate bar at the top
        self.coord_edit = QLineEdit()
        self.coord_edit.setPlaceholderText("(-0.75, 0.0) 1X")
        self.coord_edit.setAlignment(Qt.AlignCenter)
        font = self.coord_edit.font()
        font.setFamily("Courier")
        self.coord_edit.setFont(font)
        self.coord_edit.returnPressed.connect(self._apply_coord_text)

        # Connect widget coords signal to update the text field
        self.mandel.coords_changed.connect(self._on_coords_changed)

        btn_reset = QPushButton('Reset')
        btn_reset.clicked.connect(self._reset_view)

        self.iter_label = QLabel(f'Max iterations: {self.mandel.max_iter}')

        self.slider = QSlider(Qt.Horizontal)
        self.slider.setMinimum(100)
        self.slider.setMaximum(4000)
        self.slider.setValue(self.mandel.max_iter)
        self.slider.valueChanged.connect(self._set_iterations)

        controls_layout = QHBoxLayout()
        controls_layout.addWidget(btn_reset)
        controls_layout.addWidget(self.iter_label)
        controls_layout.addWidget(self.slider)

        layout = QVBoxLayout()
        layout.addWidget(self.coord_edit)
        layout.addWidget(self.mandel)
        layout.addLayout(controls_layout)

        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)

        # Set initial coord text
        self._update_coord_text(self.mandel.center_x, self.mandel.center_y, self.mandel.scale)

        self.mandel.schedule_redraw()

    def _format_coord(self, cx, cy, scale):
        display_scale = INITIAL_SCALE / scale
        return f"({cx:.15g}, {cy:.15g}) {display_scale:.10g}X"

    def _update_coord_text(self, cx, cy, scale):
        self.coord_edit.setText(self._format_coord(cx, cy, scale))

    def _on_coords_changed(self, cx, cy, scale):
        self._update_coord_text(cx, cy, scale)

    def _apply_coord_text(self):
        text = self.coord_edit.text().strip()
        try:
            if not text.startswith("("):
                raise ValueError("missing open paren")
            close_idx = text.index(")")
            coord_part = text[1:close_idx]
            remainder = text[close_idx + 1:].strip()

            coords = coord_part.split(",")
            if len(coords) != 2:
                raise ValueError("expected two coords")

            new_x = float(coords[0].strip())
            new_y = float(coords[1].strip())

            scale_str = remainder.rstrip("X").strip()
            display_scale = float(scale_str)
            if display_scale <= 0:
                raise ValueError("scale must be positive")

            self.mandel.center_x = new_x
            self.mandel.center_y = new_y
            self.mandel.scale = INITIAL_SCALE / display_scale
            self.mandel._emit_coords()
            self.mandel.schedule_redraw()
        except Exception:
            # Revert to current coords
            self._update_coord_text(self.mandel.center_x, self.mandel.center_y, self.mandel.scale)

    def _reset_view(self):
        self.mandel.center_x = -0.75
        self.mandel.center_y = 0.0
        self.mandel.scale = INITIAL_SCALE
        self.mandel.max_iter = 500
        self.slider.setValue(500)
        self.mandel._emit_coords()
        self.mandel.schedule_redraw()

    def _set_iterations(self, value):
        self.mandel.max_iter = value
        self.iter_label.setText(f'Max iterations: {value}')
        self.mandel.schedule_redraw()


def main():
    app = QApplication([])
    window = MainWindow()
    window.resize(1200, 900)
    window.show()
    sys.exit(app.exec())


if __name__ == '__main__':
    main()
