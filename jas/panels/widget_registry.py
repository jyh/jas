"""Native widget registry for platform-specific YAML element types.

Widgets that can't be rendered generically (e.g., color_bar with its
pixel-by-pixel gradient painting) register here. The YAML renderer
checks this registry before its built-in type table.
"""

from __future__ import annotations
from typing import Callable, Any

from PySide6.QtWidgets import QWidget


# Factory type: (element_spec, state_store, eval_context) → QWidget
WidgetFactory = Callable[[dict, Any, dict], QWidget]

_registry: dict[str, WidgetFactory] = {}


def register(type_name: str, factory: WidgetFactory):
    """Register a native widget factory for an element type."""
    _registry[type_name] = factory


def lookup(type_name: str) -> WidgetFactory | None:
    """Look up a registered native widget factory. Returns None if not found."""
    return _registry.get(type_name)


def create(type_name: str, el: dict, store, ctx: dict) -> QWidget | None:
    """Create a native widget if registered, else return None."""
    factory = _registry.get(type_name)
    if factory:
        return factory(el, store, ctx)
    return None
