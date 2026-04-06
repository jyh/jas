"""Tool protocol and context for the canvas tool system.

Each tool implements the CanvasTool interface and receives events
from the canvas widget. Tools own their interaction state and
draw their overlays. The ToolContext provides access to the model,
controller, and canvas services without coupling tools to the widget.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter
    from document.controller import Controller
    from document.document import Document
    from geometry.element import Element, Text, TextPath
    from document.model import Model


# Shared tool constants
HIT_RADIUS = 8.0          # pixels to detect a click on a control point or handle
HANDLE_DRAW_SIZE = 10.0   # diameter of control-point handles in pixels
DRAG_THRESHOLD = 4.0      # pixels of movement before a click becomes a drag
PASTE_OFFSET = 24.0       # translation in pt applied when pasting
LONG_PRESS_MS = 500       # milliseconds before a press becomes a long-press
POLYGON_SIDES = 5         # default number of sides for the polygon tool


class ToolContext:
    """Facade passed to tools giving access to model, controller, and canvas services."""

    def __init__(
        self,
        model: "Model",
        controller: "Controller",
        hit_test_selection: "Callable[[float, float], bool]",
        hit_test_handle: "Callable[[float, float], tuple[tuple[int, ...], int, str] | None]",
        hit_test_text: "Callable[[float, float], tuple[tuple[int, ...], Text] | None]",
        hit_test_path_curve: "Callable[[float, float], tuple[tuple[int, ...], Element] | None]",
        request_update: "Callable[[], None]",
        start_text_edit: "Callable[[tuple[int, ...], Text | TextPath], None]",
        commit_text_edit: "Callable[[], None]",
    ):
        self.model = model
        self.controller = controller
        self.hit_test_selection = hit_test_selection
        self.hit_test_handle = hit_test_handle
        self.hit_test_text = hit_test_text
        self.hit_test_path_curve = hit_test_path_curve
        self.request_update = request_update
        self.start_text_edit = start_text_edit
        self.commit_text_edit = commit_text_edit

    @property
    def document(self) -> Document:
        return self.model.document

    def snapshot(self) -> None:
        """Save the current document state for undo."""
        self.model.snapshot()


class CanvasTool(ABC):
    """Interface for canvas interaction tools."""

    @abstractmethod
    def on_press(self, ctx: ToolContext, x: float, y: float,
                 shift: bool = False, alt: bool = False) -> None:
        ...

    @abstractmethod
    def on_move(self, ctx: ToolContext, x: float, y: float,
                shift: bool = False, dragging: bool = False) -> None:
        ...

    @abstractmethod
    def on_release(self, ctx: ToolContext, x: float, y: float,
                   shift: bool = False, alt: bool = False) -> None:
        ...

    def on_double_click(self, ctx: ToolContext, x: float, y: float) -> None:
        pass

    def on_key(self, ctx: ToolContext, key: int) -> bool:
        return False

    def on_key_release(self, ctx: ToolContext, key: int) -> bool:
        return False

    @abstractmethod
    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        ...

    def activate(self, ctx: ToolContext) -> None:
        pass

    def deactivate(self, ctx: ToolContext) -> None:
        pass
