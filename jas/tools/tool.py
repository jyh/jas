"""Tool protocol and context for the canvas tool system.

Each tool implements the CanvasTool interface and receives events
from the canvas widget. Tools own their interaction state and
draw their overlays. The ToolContext provides access to the model,
controller, and canvas services without coupling tools to the widget.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from PySide6.QtGui import QPainter
    from document.controller import Controller
    from document.document import Document
    from geometry.element import Text
    from document.model import Model


class ToolContext:
    """Facade passed to tools giving access to model, controller, and canvas services."""

    def __init__(self, model: Model, controller: Controller,
                 hit_test_selection, hit_test_handle, hit_test_text,
                 hit_test_path_curve,
                 request_update, start_text_edit, commit_text_edit):
        self.model = model
        self.controller = controller
        self.hit_test_selection = hit_test_selection  # (x, y) -> bool
        self.hit_test_handle = hit_test_handle        # (x, y) -> tuple | None
        self.hit_test_text = hit_test_text            # (x, y) -> tuple | None
        self.hit_test_path_curve = hit_test_path_curve  # (x, y) -> tuple | None
        self.request_update = request_update           # () -> None
        self.start_text_edit = start_text_edit         # (path, text_elem) -> None
        self.commit_text_edit = commit_text_edit       # () -> None

    @property
    def document(self) -> Document:
        return self.model.document


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

    @abstractmethod
    def draw_overlay(self, ctx: ToolContext, painter: QPainter) -> None:
        ...

    def activate(self, ctx: ToolContext) -> None:
        pass

    def deactivate(self, ctx: ToolContext) -> None:
        pass
