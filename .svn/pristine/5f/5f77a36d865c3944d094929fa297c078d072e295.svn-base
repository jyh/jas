import numpy as np
import pytest

from mandelbrot_app import compute_mandelbrot, apply_colormap


def test_compute_mandelbrot_shape_and_bounds():
    width = 80
    height = 60
    max_iter = 120

    output = compute_mandelbrot(-2.0, 1.0, -1.5, 1.5, width, height, max_iter)

    assert output.shape == (height, width)
    assert np.all(output >= 0.0)
    assert np.max(output) <= max_iter + 1.0


def test_compute_mandelbrot_known_point():
    # Known interior point: 0 + 0i should never escape in bounded max_iter
    out = compute_mandelbrot(-0.5, 0.5, -0.5, 0.5, 3, 3, 50)
    center_value = out[1, 1]
    assert center_value >= 50.0


def test_apply_colormap_output_shape_and_range():
    frac = np.linspace(0.0, 1.0, 8, dtype=np.float32).reshape((2, 4))
    rgb = apply_colormap(frac, max_iter=500)

    assert rgb.shape == (2, 4, 3)
    assert rgb.dtype == np.uint8
    assert np.all(rgb >= 0)
    assert np.all(rgb <= 255)


def test_apply_colormap_inside_set_black():
    frac = np.array([[1.0, 1.0], [1.0, 1.0]], dtype=np.float32)
    rgb = apply_colormap(frac, max_iter=1000)
    assert np.array_equal(rgb, np.zeros((2, 2, 3), dtype=np.uint8))
