"""Shared mutable state for the Layers panel.

Lives in its own module so panel_menu (YAML dispatch) and yaml_renderer
(tree rendering) can both observe the same isolation stack without a
tighter coupling. The tuple-of-ints form matches the __path__ marker
shape used across the workspace interpreter.
"""

from typing import List, Tuple

_isolation_stack: List[Tuple[int, ...]] = []


def push_isolation_level(path: Tuple[int, ...]) -> None:
    """Push a top-level isolation target onto the stack."""
    _isolation_stack.append(tuple(path))


def pop_isolation_level() -> None:
    """Pop the innermost isolation level. No-op when the stack is empty."""
    if _isolation_stack:
        _isolation_stack.pop()


def get_isolation_stack() -> List[Tuple[int, ...]]:
    """The current stack, innermost level last (append/pop semantics)."""
    return list(_isolation_stack)


def set_isolation_stack(stack: List[Tuple[int, ...]]) -> None:
    """Replace the full stack (used by breadcrumb navigation)."""
    _isolation_stack[:] = [tuple(p) for p in stack]


def clear_isolation_stack() -> None:
    """Clear all isolation levels."""
    _isolation_stack.clear()
