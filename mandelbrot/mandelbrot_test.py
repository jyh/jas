import numpy as np
from absl.testing import absltest

from mandelbrot_app import compute_mandelbrot, apply_colormap


class MandelbrotTest(absltest.TestCase):

    def test_compute_mandelbrot_shape_and_bounds(self):
        width = 80
        height = 60
        max_iter = 120

        output = compute_mandelbrot(-2.0, 1.0, -1.5, 1.5, width, height, max_iter)

        self.assertEqual(output.shape, (height, width))
        self.assertTrue(np.all(output >= 0.0))
        self.assertLessEqual(np.max(output), max_iter + 1.0)

    def test_compute_mandelbrot_known_point(self):
        # Known interior point: 0 + 0i should never escape in bounded max_iter
        out = compute_mandelbrot(-0.5, 0.5, -0.5, 0.5, 3, 3, 50)
        center_value = out[1, 1]
        self.assertGreaterEqual(center_value, 50.0)

    def test_apply_colormap_output_shape_and_range(self):
        frac = np.linspace(0.0, 1.0, 8, dtype=np.float32).reshape((2, 4))
        rgb = apply_colormap(frac, max_iter=500)

        self.assertEqual(rgb.shape, (2, 4, 3))
        self.assertEqual(rgb.dtype, np.uint8)
        self.assertTrue(np.all(rgb >= 0))
        self.assertTrue(np.all(rgb <= 255))

    def test_apply_colormap_inside_set_black(self):
        frac = np.array([[1.0, 1.0], [1.0, 1.0]], dtype=np.float32)
        rgb = apply_colormap(frac, max_iter=1000)
        self.assertTrue(np.array_equal(rgb, np.zeros((2, 2, 3), dtype=np.uint8)))

    def test_mandelbrot_image_not_all_black(self):
        width = 80
        height = 60
        max_iter = 200
        fractal = compute_mandelbrot(-2.0, 1.0, -1.5, 1.5, width, height, max_iter)
        rgb = apply_colormap(fractal / max_iter, max_iter=max_iter)

        self.assertEqual(rgb.shape, (height, width, 3))
        # require at least one pixel is not pure black
        self.assertTrue(np.any(np.any(rgb != 0, axis=2)))


if __name__ == '__main__':
    absltest.main()
