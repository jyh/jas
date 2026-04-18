"""Per-character-range formatting substructure of Text and TextPath.

See ``TSPAN.md`` at the repository root for the full language-agnostic
design. This module covers the Python side of steps B.3.1 (data model)
and B.3.2 (pure-function primitives). Integration with ``Text`` /
``TextPath`` (making ``tspans`` a field on each) lives in a separate
step; this module is standalone so the primitives can be tested
against the shared algorithm vectors before that integration.

Mirrors ``jas_dioxus/src/geometry/tspan.rs``,
``JasSwift/Sources/Geometry/TspanPrimitives.swift`` and
``jas_ocaml/lib/geometry/tspan.ml``.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Optional

from geometry.element import Transform


# Stable in-memory tspan identifier.
#
# Unique within a single Text / TextPath element. Monotonic; a fresh
# id is always strictly greater than every existing id in the element.
# Not serialised — on SVG load, fresh ids are assigned per tspan
# starting from 0.
TspanId = int


@dataclass(frozen=True)
class Tspan:
    """A tspan: one contiguous character range inside a ``Text`` or
    ``TextPath``, carrying per-range attribute overrides.

    Every override field is ``None`` to mean "inherit the parent
    element's effective value". See TSPAN.md Attribute Inheritance.
    """
    id: TspanId = 0
    content: str = ""
    baseline_shift: Optional[float] = None
    dx: Optional[float] = None
    font_family: Optional[str] = None
    font_size: Optional[float] = None
    font_style: Optional[str] = None
    font_variant: Optional[str] = None
    font_weight: Optional[str] = None
    jas_aa_mode: Optional[str] = None
    jas_fractional_widths: Optional[bool] = None
    jas_kerning_mode: Optional[str] = None
    jas_no_break: Optional[bool] = None
    letter_spacing: Optional[float] = None
    line_height: Optional[float] = None
    rotate: Optional[float] = None
    style_name: Optional[str] = None
    # Sorted-set of decoration members (``"underline"``, ``"line-through"``).
    # ``None`` inherits the parent; ``()`` is an explicit no-decoration
    # override; writers sort members alphabetically. Stored as a tuple
    # so the dataclass remains hashable / frozen.
    text_decoration: Optional[tuple[str, ...]] = None
    text_rendering: Optional[str] = None
    text_transform: Optional[str] = None
    transform: Optional[Transform] = None
    xml_lang: Optional[str] = None

    def has_no_overrides(self) -> bool:
        """``True`` when every override slot is ``None``. A tspan with
        no overrides is purely content — it inherits everything from
        its parent element."""
        return (self.baseline_shift is None
                and self.dx is None
                and self.font_family is None
                and self.font_size is None
                and self.font_style is None
                and self.font_variant is None
                and self.font_weight is None
                and self.jas_aa_mode is None
                and self.jas_fractional_widths is None
                and self.jas_kerning_mode is None
                and self.jas_no_break is None
                and self.letter_spacing is None
                and self.line_height is None
                and self.rotate is None
                and self.style_name is None
                and self.text_decoration is None
                and self.text_rendering is None
                and self.text_transform is None
                and self.transform is None
                and self.xml_lang is None)


def default_tspan() -> Tspan:
    """Tspan with empty content, id ``0``, and every override ``None``.
    Mirrors the ``tspan_default`` algorithm vector."""
    return Tspan()


def tspans_from_content(content: str) -> tuple[Tspan, ...]:
    """One-element tspan tuple mirroring ``content`` with no overrides.
    Used by ``Text`` / ``TextPath`` constructors to seed the ``tspans``
    field. Mirrors the Rust / Swift / OCaml helpers."""
    return (Tspan(id=0, content=content),)


def concat_content(tspans: list[Tspan]) -> str:
    """Concatenation of every tspan's content in reading order.
    This is the derived ``Text.content`` value; see TSPAN.md Primitives.
    """
    return "".join(t.content for t in tspans)


def resolve_id(tspans: list[Tspan], tspan_id: TspanId) -> Optional[int]:
    """Return the current index of the tspan with ``tspan_id``, or
    ``None`` when no such tspan exists (e.g. dropped by ``merge``). O(n).
    """
    for i, t in enumerate(tspans):
        if t.id == tspan_id:
            return i
    return None


def split(
    tspans: list[Tspan],
    tspan_idx: int,
    offset: int,
) -> tuple[list[Tspan], Optional[int], Optional[int]]:
    """Split ``tspans[tspan_idx]`` at character ``offset``.

    Returns ``(new_tspans, left_idx, right_idx)``. ``left_idx`` /
    ``right_idx`` are ``None`` when the side of the split falls
    outside the list:

    - ``offset == 0``: no split; ``left_idx = tspan_idx - 1`` (or
      ``None`` at 0), ``right_idx = tspan_idx``.
    - ``offset == len(content)``: no split; ``left_idx = tspan_idx``,
      ``right_idx = tspan_idx + 1`` (or ``None`` at end).
    - Otherwise: the tspan at ``tspan_idx`` is replaced by two
      fragments sharing the original's attribute overrides. The left
      fragment keeps the original's id; the right gets
      ``max(existing ids) + 1``.

    Raises ``IndexError`` if ``tspan_idx`` is out of range; ``ValueError``
    if ``offset`` exceeds the tspan's content length.
    """
    if tspan_idx < 0 or tspan_idx >= len(tspans):
        raise IndexError(
            f"split: tspan_idx {tspan_idx} out of range ({len(tspans)} tspans)")
    t = tspans[tspan_idx]
    n = len(t.content)
    if offset < 0 or offset > n:
        raise ValueError(
            f"split: offset {offset} exceeds tspan content length {n}")

    if offset == 0:
        left = tspan_idx - 1 if tspan_idx > 0 else None
        return (list(tspans), left, tspan_idx)
    if offset == n:
        right = tspan_idx + 1 if tspan_idx + 1 < len(tspans) else None
        return (list(tspans), tspan_idx, right)

    right_id = max((s.id for s in tspans), default=0) + 1
    left = replace(t, content=t.content[:offset])
    right = replace(t, id=right_id, content=t.content[offset:])

    result = list(tspans[:tspan_idx]) + [left, right] + list(tspans[tspan_idx + 1:])
    return (result, tspan_idx, tspan_idx + 1)


def split_range(
    tspans: list[Tspan],
    char_start: int,
    char_end: int,
) -> tuple[list[Tspan], Optional[int], Optional[int]]:
    """Split tspans so ``[char_start, char_end)`` of the concatenated
    content is covered exactly by a contiguous run. Returns
    ``(new_tspans, first_idx, last_idx)`` with inclusive bounds; both
    ``None`` when the range is empty.

    Raises ``ValueError`` if ``char_start > char_end`` or ``char_end``
    exceeds the total content length.
    """
    if char_start > char_end:
        raise ValueError(
            f"split_range: char_start {char_start} > char_end {char_end}")
    total = sum(len(t.content) for t in tspans)
    if char_end > total:
        raise ValueError(
            f"split_range: char_end {char_end} exceeds content length {total}")

    if char_start == char_end:
        return (list(tspans), None, None)

    next_id = max((s.id for s in tspans), default=-1) + 1
    result: list[Tspan] = []
    first_idx: Optional[int] = None
    last_idx: Optional[int] = None
    cursor = 0

    for t in tspans:
        n = len(t.content)
        span_start = cursor
        span_end = span_start + n
        overlap_start = max(char_start, span_start)
        overlap_end = min(char_end, span_end)

        if overlap_start >= overlap_end:
            result.append(t)
        else:
            local_start = overlap_start - span_start
            local_end = overlap_end - span_start

            if local_start > 0:
                # prefix keeps the original id
                result.append(replace(t, content=t.content[:local_start]))

            middle_content = t.content[local_start:local_end]
            if local_start > 0:
                # middle is the right side of the char_start split → fresh id
                middle = replace(t, id=next_id, content=middle_content)
                next_id += 1
            else:
                middle = replace(t, content=middle_content)

            middle_idx = len(result)
            if first_idx is None:
                first_idx = middle_idx
            last_idx = middle_idx
            result.append(middle)

            if local_end < n:
                suffix = replace(t, id=next_id, content=t.content[local_end:])
                next_id += 1
                result.append(suffix)

        cursor = span_end

    return (result, first_idx, last_idx)


_ATTR_SLOTS = (
    "baseline_shift", "dx", "font_family", "font_size", "font_style",
    "font_variant", "font_weight", "jas_aa_mode", "jas_fractional_widths",
    "jas_kerning_mode", "jas_no_break", "letter_spacing", "line_height",
    "rotate", "style_name", "text_decoration", "text_rendering",
    "text_transform", "transform", "xml_lang",
)


def _attrs_equal(a: Tspan, b: Tspan) -> bool:
    """``True`` when every override slot agrees. Content and id ignored."""
    return all(getattr(a, s) == getattr(b, s) for s in _ATTR_SLOTS)


def _is_utf8_boundary(s: str, byte_offset: int) -> bool:
    """True when ``byte_offset`` is a valid UTF-8 scalar boundary.
    Continuation bytes start with bit pattern 10xxxxxx."""
    data = s.encode("utf-8")
    if byte_offset <= 0 or byte_offset >= len(data):
        return True
    return (data[byte_offset] & 0xC0) != 0x80


def reconcile_content(original: list[Tspan], new_content: str) -> list[Tspan]:
    """Reconcile a new flat content string back onto the original
    tspan structure, preserving per-range overrides where possible.

    Common prefix and suffix (byte-level, snapped to UTF-8 scalar
    boundaries) keep their original tspan assignments. The changed
    middle region is absorbed into the first overlapping tspan, with
    adjacent-equal tspans collapsed by a final ``merge`` pass.

    Mirrors the Rust / Swift / OCaml ``reconcile_content``.
    """
    old_content = concat_content(original)
    if old_content == new_content:
        return list(original)
    if not original:
        return [Tspan(id=0, content=new_content)]

    old_bytes = old_content.encode("utf-8")
    new_bytes = new_content.encode("utf-8")

    max_prefix = min(len(old_bytes), len(new_bytes))
    prefix_len = 0
    while prefix_len < max_prefix and old_bytes[prefix_len] == new_bytes[prefix_len]:
        prefix_len += 1
    while prefix_len > 0 and not _is_utf8_boundary(old_content, prefix_len):
        prefix_len -= 1

    max_suffix = min(len(old_bytes) - prefix_len, len(new_bytes) - prefix_len)
    suffix_len = 0
    while (suffix_len < max_suffix
           and old_bytes[len(old_bytes) - 1 - suffix_len]
               == new_bytes[len(new_bytes) - 1 - suffix_len]):
        suffix_len += 1
    while suffix_len > 0 and not _is_utf8_boundary(old_content, len(old_bytes) - suffix_len):
        suffix_len -= 1

    old_mid_start = prefix_len
    old_mid_end = len(old_bytes) - suffix_len
    new_middle = new_bytes[prefix_len:len(new_bytes) - suffix_len].decode("utf-8")

    def _tspan_byte_len(t: Tspan) -> int:
        return len(t.content.encode("utf-8"))

    # Pure insertion at a boundary: splice new_middle into the tspan
    # containing old_mid_start. Every other tspan passes through.
    if old_mid_start == old_mid_end:
        result = list(original)
        pos = old_mid_start
        absorbed = False
        for i, t in enumerate(result):
            t_len = _tspan_byte_len(t)
            if pos <= t_len:
                t_bytes = t.content.encode("utf-8")
                before = t_bytes[:pos].decode("utf-8")
                after = t_bytes[pos:].decode("utf-8")
                result[i] = replace(t, content=before + new_middle + after)
                absorbed = True
                break
            pos -= t_len
        if not absorbed and result:
            last = result[-1]
            result[-1] = replace(last, content=last.content + new_middle)
        return merge(result)

    # Replacement (including pure deletion): walk tspans and absorb
    # new_middle into the first overlapping tspan.
    result: list[Tspan] = []
    cursor = 0
    middle_consumed = False
    for tspan in original:
        t_len = _tspan_byte_len(tspan)
        t_start = cursor
        t_end = cursor + t_len
        if t_end <= old_mid_start:
            result.append(tspan)
        elif t_start >= old_mid_end:
            result.append(tspan)
        else:
            before_len = max(0, old_mid_start - t_start)
            if t_end > old_mid_end:
                after_off = old_mid_end - t_start
            else:
                after_off = t_len
            t_bytes = tspan.content.encode("utf-8")
            before = t_bytes[:before_len].decode("utf-8")
            after = t_bytes[after_off:].decode("utf-8") if t_end > old_mid_end else ""
            mid = "" if middle_consumed else new_middle
            if not middle_consumed:
                middle_consumed = True
            new_content_str = before + mid + after
            if new_content_str:
                result.append(replace(tspan, content=new_content_str))
        cursor = t_end

    if not result:
        result.append(default_tspan())
    return merge(result)


def merge(tspans: list[Tspan]) -> list[Tspan]:
    """Merge adjacent tspans with identical resolved override sets,
    drop empty-content tspans unconditionally. The surviving (left)
    tspan keeps its id; the right tspan's id is dropped.

    Preserves the "at least one tspan" invariant: if every tspan would
    collapse to empty, returns ``[default_tspan()]``.
    """
    filtered = [t for t in tspans if t.content != ""]
    if not filtered:
        return [default_tspan()]

    result: list[Tspan] = []
    for t in filtered:
        if result and _attrs_equal(result[-1], t):
            prev = result[-1]
            result[-1] = replace(prev, content=prev.content + t.content)
        else:
            result.append(t)
    return result
