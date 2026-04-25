"""Affine transform builders for the Scale / Rotate / Shear tools.

Each function returns a 2x3 affine `Transform` (from
`jas.geometry.element`) that composes:

  1. `Transform.translate(-rx, -ry)` — move the reference point
     to the origin.
  2. The tool-specific base transform (scale / rotate / shear).
  3. `Transform.translate(rx, ry)` — move the reference point
     back.

The composition is delegated to `Transform.around_point` so every
tool's matrix pivots around the same reference point.

See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md §Apply behavior.
"""

from __future__ import annotations

import math

from jas.geometry.element import Transform


def scale_matrix(sx: float, sy: float, rx: float, ry: float) -> Transform:
    """Scale matrix: (sx, sy) factors applied around (rx, ry).

    Negative factors flip the selection on that axis. A factor of
    1.0 on both axes is the identity transform.
    """
    return Transform.scale(sx, sy).around_point(rx, ry)


def rotate_matrix(theta_deg: float, rx: float, ry: float) -> Transform:
    """Rotation matrix: theta_deg degrees CCW around (rx, ry)."""
    return Transform.rotate(theta_deg).around_point(rx, ry)


def shear_matrix(angle_deg: float, axis: str, axis_angle_deg: float,
                 rx: float, ry: float) -> Transform:
    """Shear matrix: angle_deg degrees of slant along `axis` around
    (rx, ry).

    Axis values:
      "horizontal" — points slide horizontally; y-axis fixed.
      "vertical"   — points slide vertically; x-axis fixed.
      "custom"     — axis_angle_deg degrees from horizontal.

    The shear factor is tan(angle_deg). Angles approaching ±90°
    become unstable; callers clamp to a reasonable range (the
    dialog uses ±89.9°).
    """
    k = math.tan(math.radians(angle_deg))
    if axis == "horizontal":
        base = Transform.shear(k, 0.0)
    elif axis == "vertical":
        base = Transform.shear(0.0, k)
    elif axis == "custom":
        # Custom-axis shear = R(-axis_angle) · shear(k, 0) · R(axis_angle).
        # Rotate the selection so the custom axis becomes horizontal,
        # shear horizontally, rotate back.
        r_back = Transform.rotate(axis_angle_deg)
        r_fwd = Transform.rotate(-axis_angle_deg)
        s = Transform.shear(k, 0.0)
        base = r_back.multiply(s).multiply(r_fwd)
    else:
        base = Transform()
    return base.around_point(rx, ry)


def stroke_width_factor(sx: float, sy: float) -> float:
    """Geometric mean of (sx, sy) for the stroke-width multiplier
    under non-uniform scaling. Always non-negative.

    See SCALE_TOOL.md §Apply behavior — "stroke width: when
    state.scale_strokes is true, multiply by the unsigned
    geometric mean √(|sx · sy|)."
    """
    return math.sqrt(abs(sx) * abs(sy))
