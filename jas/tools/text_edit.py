"""In-place text editor state shared by TypeTool and TypeOnPathTool.

See `jas_dioxus/src/tools/text_edit.rs` for the full design notes; this is
the Python port. The session owns the editing content, the insertion and
anchor cursor positions, the per-session undo/redo stacks, and a
`blink_epoch_ms` for caret animation. It exposes pure operations and a
single `apply_to_document` that materializes a new Document.
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional

from geometry.element import Color, Fill, Text, TextPath
from geometry.text_layout import ordered_range


class EditTarget(Enum):
    TEXT = "text"
    TEXT_PATH = "text_path"


@dataclass
class _Snapshot:
    content: str
    insertion: int
    anchor: int


@dataclass
class TextEditSession:
    path: tuple
    target: EditTarget
    content: str
    insertion: int
    anchor: int = 0
    drag_active: bool = False
    blink_epoch_ms: float = 0.0
    _undo: List[_Snapshot] = field(default_factory=list)
    _redo: List[_Snapshot] = field(default_factory=list)

    def __post_init__(self):
        n = len(self.content)
        self.insertion = min(self.insertion, n)
        self.anchor = self.insertion

    def has_selection(self) -> bool:
        return self.insertion != self.anchor

    def selection_range(self) -> tuple[int, int]:
        return ordered_range(self.insertion, self.anchor)

    def _snapshot(self) -> None:
        self._undo.append(_Snapshot(self.content, self.insertion, self.anchor))
        self._redo.clear()
        if len(self._undo) > 200:
            self._undo.pop(0)

    def undo(self) -> None:
        if not self._undo:
            return
        prev = self._undo.pop()
        self._redo.append(_Snapshot(self.content, self.insertion, self.anchor))
        self.content = prev.content
        self.insertion = prev.insertion
        self.anchor = prev.anchor

    def redo(self) -> None:
        if not self._redo:
            return
        nxt = self._redo.pop()
        self._undo.append(_Snapshot(self.content, self.insertion, self.anchor))
        self.content = nxt.content
        self.insertion = nxt.insertion
        self.anchor = nxt.anchor

    def insert(self, text: str) -> None:
        self._snapshot()
        if self.has_selection():
            self._delete_selection_inner()
        self.content = self.content[:self.insertion] + text + self.content[self.insertion:]
        self.insertion += len(text)
        self.anchor = self.insertion

    def backspace(self) -> None:
        if self.has_selection():
            self._snapshot()
            self._delete_selection_inner()
            return
        if self.insertion == 0:
            return
        self._snapshot()
        self.content = self.content[:self.insertion - 1] + self.content[self.insertion:]
        self.insertion -= 1
        self.anchor = self.insertion

    def delete_forward(self) -> None:
        if self.has_selection():
            self._snapshot()
            self._delete_selection_inner()
            return
        if self.insertion >= len(self.content):
            return
        self._snapshot()
        self.content = self.content[:self.insertion] + self.content[self.insertion + 1:]
        self.anchor = self.insertion

    def _delete_selection_inner(self) -> None:
        lo, hi = self.selection_range()
        self.content = self.content[:lo] + self.content[hi:]
        self.insertion = lo
        self.anchor = lo

    def set_insertion(self, pos: int, extend: bool) -> None:
        n = len(self.content)
        self.insertion = max(0, min(pos, n))
        if not extend:
            self.anchor = self.insertion

    def select_all(self) -> None:
        self.anchor = 0
        self.insertion = len(self.content)

    def copy_selection(self) -> Optional[str]:
        if not self.has_selection():
            return None
        lo, hi = self.selection_range()
        return self.content[lo:hi]

    def apply_to_document(self, doc):
        elem = doc.get_element(self.path)
        if self.target == EditTarget.TEXT and isinstance(elem, Text):
            new_elem = dataclasses.replace(elem, content=self.content)
        elif self.target == EditTarget.TEXT_PATH and isinstance(elem, TextPath):
            new_elem = dataclasses.replace(elem, content=self.content)
        else:
            return None
        return doc.replace_element(self.path, new_elem)


def empty_text_elem(x: float, y: float, width: float = 0.0, height: float = 0.0) -> Text:
    return Text(
        x=x, y=y, content="",
        width=width, height=height,
        fill=Fill(color=Color(0, 0, 0)),
    )


def empty_text_path_elem(d: tuple) -> TextPath:
    return TextPath(d=d, content="", fill=Fill(color=Color(0, 0, 0)))
