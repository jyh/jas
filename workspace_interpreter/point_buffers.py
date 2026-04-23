"""Thread-local-equivalent point buffers for drag-accumulating tools.

Tools like Lasso and Pencil push (x, y) coordinates here during a
drag. Module-local dict plays the role of Rust's thread_local! and
Swift's module ref — Qt/GTK run single-threaded so a plain dict
suffices.
"""

from __future__ import annotations


_buffers: dict[str, list[tuple[float, float]]] = {}


def clear(name: str) -> None:
    """Reset the named buffer to empty."""
    _buffers[name] = []


def push(name: str, x: float, y: float) -> None:
    """Append (x, y) to the named buffer."""
    _buffers.setdefault(name, []).append((x, y))


def length(name: str) -> int:
    return len(_buffers.get(name, []))


def points(name: str) -> list[tuple[float, float]]:
    """Return a shallow copy of the buffer's points."""
    return list(_buffers.get(name, []))
