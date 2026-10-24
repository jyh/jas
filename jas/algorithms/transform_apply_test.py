"""ROTATE_TOOL.md and ROT-062 (P0): a positive angle turns the selection
COUNTER-clockwise as the artist sees it. The document is y-down, so a point at
3 o'clock moves toward 12 o'clock, which is toward SMALLER y. The same arm
lives in both active ports (transform_apply.rs, TransformApplyTests.swift).
Until 2026-10-24 every implementation turned a positive angle clockwise."""
import math

from algorithms.transform_apply import rotate_matrix


def test_a_positive_angle_turns_a_three_oclock_point_toward_twelve():
    x, y = rotate_matrix(30.0, 0.0, 0.0).apply_point(1.0, 0.0)
    assert abs(x - math.cos(30.0 * (math.pi / 180))) < 1e-12
    assert y < 0.0, f"a 3 o'clock point moves UP the screen (smaller y), got {y}"
    assert abs(y + 0.5) < 1e-12
