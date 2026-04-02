import sys
import math
import numpy as np
from concurrent.futures import ThreadPoolExecutor

from PySide6.QtCore import Qt, QTimer, QSize, QPointF, Signal, QThread
from PySide6.QtGui import QImage, QPainter, QColor
from PySide6.QtWidgets import QApplication, QLabel, QMainWindow, QVBoxLayout, QWidget, QHBoxLayout, QPushButton, QSlider

import numba


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


def apply_colormap(frac, max_iter):
    # fraction in [0,1] where 1 means inside set
    # dynamic contrast: as max_iter grows, keep edges sharp
    gamma = 0.7 + math.log10(max_iter + 1) / 2.5
    data = np.clip(frac, 0.0, 1.0)
    intensity = np.power(data, gamma)
    edges = np.clip(1.0 - np.sqrt(intensity), 0.0, 1.0)

    hue = np.mod(0.66 + 0.34 * intensity, 1.0)
    v = 0.25 + 0.75 * edges

    hi = (hue * 6.0).astype(np.int32) % 6
    f = hue * 6.0 - (hue * 6.0).astype(np.int32)
    p = np.zeros_like(v)   # s=1, so p = v*(1-s) = 0
    q = v * (1.0 - f)
    t = v * f

    r = np.select([hi == 0, hi == 1, hi == 2, hi == 3, hi == 4, hi == 5], [v, q, p, p, t, v])
    g = np.select([hi == 0, hi == 1, hi == 2, hi == 3, hi == 4, hi == 5], [t, v, v, q, p, p])
    b = np.select([hi == 0, hi == 1, hi == 2, hi == 3, hi == 4, hi == 5], [p, p, t, v, v, q])

    inside = frac >= 1.0
    r = np.where(inside, 0.0, r)
    g = np.where(inside, 0.0, g)
    b = np.where(inside, 0.0, b)

    rgb = np.stack([r, g, b], axis=-1)
    return np.clip(rgb * 255, 0, 255).astype(np.uint8)


def iterations_to_qimage(iterations, max_iter):
    height, width = iterations.shape
    norm = iterations / float(max_iter)
    rgb = apply_colormap(norm, max_iter)

    # Ensure memory is contiguous
    rgb = np.ascontiguousarray(rgb)
    bytes_per_line = width * 3
    
    # Create QImage directly from the memory buffer
    image = QImage(rgb.data, width, height, bytes_per_line, QImage.Format_RGB888)
    
    # Use .copy() to ensure the image data persists after the numpy array is garbage collected
    return image.copy()


class MandelbrotWidget(QWidget):
    # Define a signal to safely pass the rendered image back to the main thread
    new_image_ready = Signal(QImage)

    def __init__(self):
        super().__init__()
        self.center_x = -0.75
        self.center_y = 0.0
        self.scale = 3.5
        self.max_iter = 500

        self.dragging = False
        self.last_pos = None

        self.image = None
        self.requested_compute = False

        self.executor = ThreadPoolExecutor(max_workers=1)
        self.future = None

        self.render_timer = QTimer(self)
        self.render_timer.setSingleShot(True)
        self.render_timer.timeout.connect(self._compute_fractal)
        
        # Connect the signal to the GUI update method
        self.new_image_ready.connect(self._apply_new_image)

        self.setMinimumSize(640, 480)

    def sizeHint(self):
        return QSize(1024, 768)

    def schedule_redraw(self):
        if self.render_timer.isActive():
            self.render_timer.stop()
        self.render_timer.start(20)

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

        def job():
            iters = compute_mandelbrot(xmin, xmax, ymin, ymax, w, h, max_iter)
            return iters, max_iter

        self.future = self.executor.submit(job)
        self.future.add_done_callback(self._on_render_done)

    def _on_render_done(self, future):
        try:
            iters, max_iter = future.result()
            img = iterations_to_qimage(iters, max_iter)
            # Emit the signal instead of directly modifying self.image and calling self.update()
            self.new_image_ready.emit(img)
        except Exception as e:
            # Print the exception so you can see if something else breaks in the future
            print(f"Render failed: {e}")

    def _apply_new_image(self, img):
        self.image = img
        self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.dragging = True
            self.last_pos = event.position()

    def mouseMoveEvent(self, event):
        if self.dragging and self.last_pos is not None:
            delta = event.position() - self.last_pos
            self.last_pos = event.position()

            w = self.width()
            h = self.height()
            self.center_x -= float(delta.x()) / w * self.scale
            self.center_y += float(delta.y()) / h * (self.scale * (h / w))
            self.schedule_redraw()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.dragging = False

    def wheelEvent(self, event):
        angle = event.angleDelta().y() / 120.0
        factor = 0.85 ** angle
        # Zoom in/out around mouse position
        pos = event.position()
        w = self.width()
        h = self.height()

        mx = (pos.x() / w - 0.5) * self.scale + self.center_x
        my = (0.5 - pos.y() / h) * self.scale * (h / w) + self.center_y

        self.scale *= factor
        self.center_x = mx + (self.center_x - mx) * factor
        self.center_y = my + (self.center_y - my) * factor

        self.max_iter = max(100, min(4000, int(self.max_iter * (1.0 + abs(angle) * 0.12))))

        self.schedule_redraw()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Mandelbrot Explorer')

        self.mandel = MandelbrotWidget()

        btn_reset = QPushButton('Reset')
        btn_reset.clicked.connect(self._reset_view)

        self.iter_label = QLabel(f'Max iterations: {self.mandel.max_iter}')

        slider = QSlider(Qt.Horizontal)
        slider.setMinimum(100)
        slider.setMaximum(4000)
        slider.setValue(self.mandel.max_iter)
        slider.valueChanged.connect(self._set_iterations)

        controls_layout = QHBoxLayout()
        controls_layout.addWidget(btn_reset)
        controls_layout.addWidget(self.iter_label)
        controls_layout.addWidget(slider)

        layout = QVBoxLayout()
        layout.addWidget(self.mandel)
        layout.addLayout(controls_layout)

        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)

        self.mandel.schedule_redraw()

    def _reset_view(self):
        self.mandel.center_x = -0.75
        self.mandel.center_y = 0.0
        self.mandel.scale = 3.5
        self.mandel.max_iter = 500
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
