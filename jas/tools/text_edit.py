"""In-place text editor state shared by TypeTool and TypeOnPathTool.

See `jas_dioxus/src/tools/text_edit.rs` for the full design notes; this is
the Python port. The session owns the editing content, the insertion and
anchor cursor positions, the per-session undo/redo stacks, and a
`blink_epoch_ms` for caret animation. It exposes pure operations and a
single `apply_to_document` that materializes a new Document.
"""

from __future__ import annotations

import dataclasses
import time
from dataclasses import dataclass, field
from enum import Enum

from geometry.element import RgbColor, Fill, Text, TextPath
from algorithms.text_layout import ordered_range


# Cursor blink half-period in milliseconds (matches the macOS default).
# Shared by TypeTool and TypeOnPathTool.
BLINK_HALF_PERIOD_MS = 530.0


def now_ms() -> float:
    return time.monotonic() * 1000.0


def cursor_visible(epoch_ms: float) -> bool:
    elapsed = max(0.0, now_ms() - epoch_ms)
    phase = int(elapsed / BLINK_HALF_PERIOD_MS)
    return phase % 2 == 0


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
    _undo: list[_Snapshot] = field(default_factory=list)
    _redo: list[_Snapshot] = field(default_factory=list)
    # Session-scoped tspan clipboard. Captured on cut/copy from the
    # current element's tspan structure; consumed on paste when the
    # system-clipboard flat text matches. Preserves per-range overrides
    # across cut/paste within a single edit session. Shape is a
    # ``(flat_text, tspans_tuple)`` pair or ``None`` when empty.
    tspan_clipboard: tuple | None = None
    # Caret side at a tspan boundary. Defaults to ``LEFT`` per TSPAN.md
    # ("new text inherits attributes of the previous character");
    # ``RIGHT`` is set by callers that crossed a boundary rightward.
    # External char-index APIs keep working unchanged — the affinity
    # only matters at joins.
    caret_affinity: "Affinity" = None  # type: ignore[assignment]
    # Next-typed-character override: a ``Tspan`` template whose
    # non-``None`` fields are applied to characters inserted from
    # ``pending_char_start`` to the current ``insertion`` at commit
    # time. Primed by Character-panel writes when there is no
    # selection (bare caret); cleared by any caret move with no
    # selection extension and by undo/redo. Not persisted to the
    # document.
    pending_override: object | None = None  # Optional[Tspan]
    pending_char_start: int | None = None

    def __post_init__(self):
        from geometry.tspan import Affinity
        n = len(self.content)
        self.insertion = min(self.insertion, n)
        self.anchor = self.insertion
        if self.caret_affinity is None:
            self.caret_affinity = Affinity.LEFT

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
        self.clear_pending_override()

    def redo(self) -> None:
        if not self._redo:
            return
        nxt = self._redo.pop()
        self._undo.append(_Snapshot(self.content, self.insertion, self.anchor))
        self.content = nxt.content
        self.insertion = nxt.insertion
        self.anchor = nxt.anchor
        self.clear_pending_override()

    def set_pending_override(self, overrides) -> None:
        """Prime the next-typed-character state. Non-``None`` fields
        of ``overrides`` are merged into the existing pending template;
        the anchor position is captured on the first call.
        """
        from geometry.tspan import Tspan, merge_tspan_overrides
        if self.pending_override is None:
            self.pending_override = Tspan()
            self.pending_char_start = self.insertion
        self.pending_override = merge_tspan_overrides(
            self.pending_override, overrides)

    def clear_pending_override(self) -> None:
        self.pending_override = None
        self.pending_char_start = None

    def has_pending_override(self) -> bool:
        return self.pending_override is not None

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
        new_pos = max(0, min(pos, n))
        # Non-extending caret movement cancels any pending next-typed-
        # character override.
        if not extend and new_pos != self.insertion:
            self.clear_pending_override()
        self.insertion = new_pos
        if not extend:
            self.anchor = self.insertion

    def set_insertion_with_affinity(self, pos: int, affinity, extend: bool) -> None:
        """Move the caret with an explicit affinity. Use when crossing
        a tspan boundary — arrow-right lands with RIGHT, arrow-left
        with LEFT. The plain ``set_insertion`` keeps defaulting to
        LEFT per TSPAN.md.
        """
        n = len(self.content)
        new_pos = max(0, min(pos, n))
        if not extend and new_pos != self.insertion:
            self.clear_pending_override()
        self.insertion = new_pos
        self.caret_affinity = affinity
        if not extend:
            self.anchor = self.insertion

    def insertion_tspan_pos(self, element_tspans) -> tuple[int, int]:
        """Resolve the caret's ``(tspan_idx, offset)`` using
        ``caret_affinity``. Used by the next-typed-character path.
        """
        from geometry.tspan import char_to_tspan_pos
        return char_to_tspan_pos(list(element_tspans), self.insertion,
                                  self.caret_affinity)

    def anchor_tspan_pos(self, element_tspans) -> tuple[int, int]:
        """Resolve the selection anchor's ``(tspan_idx, offset)``.
        Anchors do not have an independent affinity; they track the
        caret's.
        """
        from geometry.tspan import char_to_tspan_pos
        return char_to_tspan_pos(list(element_tspans), self.anchor,
                                  self.caret_affinity)

    def select_all(self) -> None:
        self.anchor = 0
        self.insertion = len(self.content)

    def copy_selection(self) -> str | None:
        if not self.has_selection():
            return None
        lo, hi = self.selection_range()
        return self.content[lo:hi]

    def copy_selection_with_tspans(self, element_tspans) -> str | None:
        """Capture the selection's flat text and tspan structure (from
        ``element_tspans``) into the session clipboard. Returns the flat
        text for the system clipboard, or ``None`` if there is no
        selection. Mirrors Rust's ``copy_selection_with_tspans``.
        """
        if not self.has_selection():
            return None
        from geometry.tspan import copy_range
        lo, hi = self.selection_range()
        flat = self.content[lo:hi]
        payload = tuple(copy_range(list(element_tspans), lo, hi))
        self.tspan_clipboard = (flat, payload)
        return flat

    def try_paste_tspans(self, element_tspans, text: str):
        """When the session clipboard's flat text matches ``text``,
        splice the captured tspans into ``element_tspans`` at the caret
        and return the resulting tspan tuple. Otherwise ``None`` —
        caller falls back to :meth:`insert`.
        """
        if self.tspan_clipboard is None:
            return None
        flat, payload = self.tspan_clipboard
        if flat != text:
            return None
        from geometry.tspan import insert_tspans_at
        return tuple(insert_tspans_at(list(element_tspans), self.insertion, list(payload)))

    def set_content(self, new_content: str, insertion: int, anchor: int) -> None:
        """Atomic content / caret update after an external tspan-aware
        paste rewrote the underlying element.
        """
        self.content = new_content
        n = len(new_content)
        self.insertion = max(0, min(insertion, n))
        self.anchor = max(0, min(anchor, n))

    def apply_to_document(self, doc):
        """Tspan-aware commit: reconcile the session's flat content
        against the element's current tspan structure, then apply any
        pending next-typed-character override to the typed range.
        Unchanged prefix and suffix regions keep their original tspan
        assignments (and all per-range overrides); the changed middle
        is absorbed into the first overlapping tspan, with adjacent-
        equal tspans collapsed by the merge pass. Returns None if the
        path no longer points at a compatible element.
        """
        from geometry.tspan import reconcile_content
        elem = doc.get_element(self.path)
        if self.target == EditTarget.TEXT and isinstance(elem, Text):
            reconciled = reconcile_content(list(elem.tspans), self.content)
            new_tspans = tuple(self._apply_pending_to(reconciled, elem=elem))
            new_elem = dataclasses.replace(
                elem, content=self.content, tspans=new_tspans)
        elif self.target == EditTarget.TEXT_PATH and isinstance(elem, TextPath):
            reconciled = reconcile_content(list(elem.tspans), self.content)
            new_tspans = tuple(self._apply_pending_to(reconciled, elem=elem))
            new_elem = dataclasses.replace(
                elem, content=self.content, tspans=new_tspans)
        else:
            return None
        return doc.replace_element(self.path, new_elem)

    def _apply_pending_to(self, tspans, elem=None):
        """Apply the pending next-typed-character override to the
        range ``[pending_char_start, insertion)`` of ``tspans``, then
        merge. Passthrough when pending is unset or the range is
        empty. When ``elem`` is supplied, runs identity-omission
        (TSPAN.md step 3) between the override-merge and final merge
        steps so redundant overrides get cleared.
        """
        if (self.pending_override is None
                or self.pending_char_start is None
                or self.pending_char_start >= self.insertion):
            return list(tspans)
        from geometry.tspan import split_range, merge, merge_tspan_overrides
        split, first, last = split_range(
            list(tspans), self.pending_char_start, self.insertion)
        if first is None or last is None:
            return split
        out = list(split)
        for i in range(first, last + 1):
            merged = merge_tspan_overrides(out[i], self.pending_override)
            if elem is not None:
                # Imported lazily to avoid a cycle with character_panel_state.
                from panels.character_panel_state import identity_omit_tspan
                merged = identity_omit_tspan(merged, elem)
            out[i] = merged
        return merge(out)


def empty_text_elem(x: float, y: float, width: float = 0.0, height: float = 0.0) -> Text:
    return Text(
        x=x, y=y, content="",
        width=width, height=height,
        fill=Fill(color=RgbColor(0, 0, 0)),
    )


def empty_text_path_elem(d: tuple) -> TextPath:
    return TextPath(d=d, content="", fill=Fill(color=RgbColor(0, 0, 0)))
