"""Anchor buffers for the Pen tool.

Each anchor carries (x, y), in/out handle positions, and a
smooth/corner flag. On ``push`` the anchor is appended as a
corner (handles coincident with the anchor). ``set_last_out_handle``
converts the latest anchor into a smooth one by setting its
out-handle explicitly and mirroring the in-handle through the
anchor position.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Anchor:
    x: float
    y: float
    hx_in: float
    hy_in: float
    hx_out: float
    hy_out: float
    smooth: bool


_buffers: dict[str, list[Anchor]] = {}


def clear(name: str) -> None:
    _buffers[name] = []


def push(name: str, x: float, y: float) -> None:
    """Append a corner anchor (handles coincident with the anchor)."""
    corner = Anchor(
        x=x, y=y,
        hx_in=x, hy_in=y,
        hx_out=x, hy_out=y,
        smooth=False,
    )
    _buffers.setdefault(name, []).append(corner)


def pop(name: str) -> None:
    """Drop the last anchor, if any."""
    lst = _buffers.get(name)
    if lst:
        lst.pop()


def set_last_out_handle(name: str, hx: float, hy: float) -> None:
    """Set the out-handle of the last anchor, mirroring the
    in-handle through the anchor; marks the anchor smooth."""
    lst = _buffers.get(name)
    if not lst:
        return
    a = lst[-1]
    a.hx_out = hx
    a.hy_out = hy
    a.hx_in = 2.0 * a.x - hx
    a.hy_in = 2.0 * a.y - hy
    a.smooth = True


def length(name: str) -> int:
    return len(_buffers.get(name, []))


def first(name: str) -> Anchor | None:
    lst = _buffers.get(name)
    return lst[0] if lst else None


def anchors(name: str) -> list[Anchor]:
    """Return a shallow copy of the buffer's anchors."""
    return list(_buffers.get(name, []))


def close_hit(name: str, x: float, y: float, radius: float) -> bool:
    """True when (x, y) is within ``radius`` of the first anchor
    AND the buffer has >= 2 anchors (so closing makes sense)."""
    lst = _buffers.get(name)
    if not lst or len(lst) < 2:
        return False
    first_a = lst[0]
    dx = x - first_a.x
    dy = y - first_a.y
    return (dx * dx + dy * dy) ** 0.5 <= radius
