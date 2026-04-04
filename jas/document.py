"""Immutable document model.

A Document is an ordered list of Layers.
"""

from dataclasses import dataclass
from typing import Tuple

from element import Layer


@dataclass(frozen=True)
class Document:
    """A document consisting of a title and an ordered list of layers."""
    title: str = "Untitled"
    layers: tuple[Layer, ...] = (Layer(),)
    selected_layer: int = 0

    def bounds(self) -> Tuple[float, float, float, float]:
        """Return the bounding box of all layers combined."""
        if not self.layers:
            return (0, 0, 0, 0)
        all_bounds = [layer.bounds() for layer in self.layers]
        min_x = min(b[0] for b in all_bounds)
        min_y = min(b[1] for b in all_bounds)
        max_x = max(b[0] + b[2] for b in all_bounds)
        max_y = max(b[1] + b[3] for b in all_bounds)
        return (min_x, min_y, max_x - min_x, max_y - min_y)
