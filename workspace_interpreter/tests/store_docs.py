"""Store documents for the reference tests, in the store's one form.

STATUS-jas item 34: the reference store holds the op bridge's test JSON
(``type``, common props at an element's top level), which ``apply_op`` writes
back after any op. A test document is built from the op layer's own
dataclasses and written by its own codec (``geometry.test_json``), never typed
by hand, so a test cannot drift into a third form.
"""

from __future__ import annotations

import json
import os
import sys

# The op layer lives beside the frozen Python app, the import root
# ``effects.py`` and ``state_store.py`` already use.
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

from document.document import Document, ElementSelection  # noqa: E402
from geometry.element import (  # noqa: E402
    Color, Fill, Group, Layer, Line, LineTo, MoveTo, Path, Polyline, Rect, Stroke, Visibility)
from geometry.test_json import document_to_test_json  # noqa: E402


def store_doc(*layers, selected=(), **fields) -> dict:
    """A store document holding ``layers`` (dataclass Layers), the elements at
    the paths in ``selected`` selected whole, and any other ``Document`` field
    given by keyword. The codec writes the selection sorted by path."""
    if selected:
        fields["selection"] = frozenset(ElementSelection.all(tuple(p)) for p in selected)
    return json.loads(document_to_test_json(Document(layers=tuple(layers), **fields)))


__all__ = ["Color", "Fill", "Group", "Layer", "Line", "LineTo", "MoveTo", "Path", "Polyline", "Rect", "Stroke",
           "Visibility", "store_doc"]
