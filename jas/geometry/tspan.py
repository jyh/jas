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
from enum import Enum
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
    # Marks a tspan as a paragraph wrapper when set to "paragraph".
    # Wrapper tspans implicitly group subsequent content tspans (until
    # the next wrapper) into one paragraph for the Paragraph panel.
    jas_role: Optional[str] = None
    # ── Paragraph attributes (Phase 3b panel-surface subset) ────
    # Per PARAGRAPH.md §SVG attribute mapping these live on the
    # paragraph wrapper tspan (jas_role == "paragraph"). Phase 3b
    # adds the five panel-surface attrs that the Paragraph panel
    # reads when populating its controls; the dialog attrs and the
    # remaining panel-surface space-before / space-after /
    # first-line-indent (CSS text-indent) land later.
    jas_left_indent: Optional[float] = None
    jas_right_indent: Optional[float] = None
    jas_hyphenate: Optional[bool] = None
    jas_hanging_punctuation: Optional[bool] = None
    # Single backing attr for both BULLETS_DROPDOWN and
    # NUMBERED_LIST_DROPDOWN. Values: bullet-disc / bullet-open-circle /
    # bullet-square / bullet-open-square / bullet-dash / bullet-check /
    # num-decimal / num-lower-alpha / num-upper-alpha / num-lower-roman /
    # num-upper-roman; absent = no marker.
    jas_list_style: Optional[str] = None
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
                and self.jas_role is None
                and self.jas_left_indent is None
                and self.jas_right_indent is None
                and self.jas_hyphenate is None
                and self.jas_hanging_punctuation is None
                and self.jas_list_style is None
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


def tspans_to_json_clipboard(tspans: list[Tspan]) -> str:
    """Serialize ``tspans`` as the rich-clipboard JSON payload per
    TSPAN.md — ``{"tspans": [...]}`` with each tspan's override
    fields in snake_case. Ids are stripped; ``None`` overrides are
    omitted for compactness.
    """
    import json as _json

    def tspan_obj(t: Tspan) -> dict:
        obj: dict = {"content": t.content}
        if t.baseline_shift is not None: obj["baseline_shift"] = t.baseline_shift
        if t.dx is not None: obj["dx"] = t.dx
        if t.font_family is not None: obj["font_family"] = t.font_family
        if t.font_size is not None: obj["font_size"] = t.font_size
        if t.font_style is not None: obj["font_style"] = t.font_style
        if t.font_variant is not None: obj["font_variant"] = t.font_variant
        if t.font_weight is not None: obj["font_weight"] = t.font_weight
        if t.jas_aa_mode is not None: obj["jas_aa_mode"] = t.jas_aa_mode
        if t.jas_fractional_widths is not None: obj["jas_fractional_widths"] = t.jas_fractional_widths
        if t.jas_kerning_mode is not None: obj["jas_kerning_mode"] = t.jas_kerning_mode
        if t.jas_no_break is not None: obj["jas_no_break"] = t.jas_no_break
        if t.jas_role is not None: obj["jas_role"] = t.jas_role
        if t.jas_left_indent is not None: obj["jas_left_indent"] = t.jas_left_indent
        if t.jas_right_indent is not None: obj["jas_right_indent"] = t.jas_right_indent
        if t.jas_hyphenate is not None: obj["jas_hyphenate"] = t.jas_hyphenate
        if t.jas_hanging_punctuation is not None: obj["jas_hanging_punctuation"] = t.jas_hanging_punctuation
        if t.jas_list_style is not None: obj["jas_list_style"] = t.jas_list_style
        if t.letter_spacing is not None: obj["letter_spacing"] = t.letter_spacing
        if t.line_height is not None: obj["line_height"] = t.line_height
        if t.rotate is not None: obj["rotate"] = t.rotate
        if t.style_name is not None: obj["style_name"] = t.style_name
        if t.text_decoration is not None: obj["text_decoration"] = list(t.text_decoration)
        if t.text_rendering is not None: obj["text_rendering"] = t.text_rendering
        if t.text_transform is not None: obj["text_transform"] = t.text_transform
        if t.xml_lang is not None: obj["xml_lang"] = t.xml_lang
        return obj

    return _json.dumps({"tspans": [tspan_obj(t) for t in tspans]})


def tspans_from_json_clipboard(json_str: str) -> Optional[tuple[Tspan, ...]]:
    """Parse a rich-clipboard JSON payload back into a tspan tuple
    with fresh ids. Returns ``None`` if the payload is malformed."""
    import json as _json
    try:
        root = _json.loads(json_str)
    except Exception:
        return None
    if not isinstance(root, dict):
        return None
    arr = root.get("tspans")
    if not isinstance(arr, list):
        return None
    out: list[Tspan] = []
    for i, obj in enumerate(arr):
        if not isinstance(obj, dict):
            return None
        td = obj.get("text_decoration")
        if td is not None and not isinstance(td, list):
            td = None
        out.append(Tspan(
            id=i,
            content=obj.get("content") or "",
            baseline_shift=obj.get("baseline_shift"),
            dx=obj.get("dx"),
            font_family=obj.get("font_family"),
            font_size=obj.get("font_size"),
            font_style=obj.get("font_style"),
            font_variant=obj.get("font_variant"),
            font_weight=obj.get("font_weight"),
            jas_aa_mode=obj.get("jas_aa_mode"),
            jas_fractional_widths=obj.get("jas_fractional_widths"),
            jas_kerning_mode=obj.get("jas_kerning_mode"),
            jas_no_break=obj.get("jas_no_break"),
            jas_role=obj.get("jas_role"),
            jas_left_indent=obj.get("jas_left_indent"),
            jas_right_indent=obj.get("jas_right_indent"),
            jas_hyphenate=obj.get("jas_hyphenate"),
            jas_hanging_punctuation=obj.get("jas_hanging_punctuation"),
            jas_list_style=obj.get("jas_list_style"),
            letter_spacing=obj.get("letter_spacing"),
            line_height=obj.get("line_height"),
            rotate=obj.get("rotate"),
            style_name=obj.get("style_name"),
            text_decoration=tuple(td) if td is not None else None,
            text_rendering=obj.get("text_rendering"),
            text_transform=obj.get("text_transform"),
            transform=None,
            xml_lang=obj.get("xml_lang"),
        ))
    return tuple(out)


def _fmt_float_clipboard(v: float) -> str:
    return str(int(v)) if v == int(v) else str(v)


def _xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def _xml_unescape(s: str) -> str:
    return (s.replace("&quot;", '"').replace("&gt;", ">")
             .replace("&lt;", "<").replace("&amp;", "&"))


def tspans_to_svg_fragment(tspans: list[Tspan]) -> str:
    """Serialize ``tspans`` as an SVG fragment suitable for the
    ``image/svg+xml`` clipboard format — one ``<text>`` element
    wrapping tspan children with CSS-style attribute names,
    alphabetically sorted.
    """
    out = ['<text xmlns="http://www.w3.org/2000/svg">']
    for t in tspans:
        out.append("<tspan")
        attrs: list[tuple[str, str]] = []
        if t.baseline_shift is not None: attrs.append(("baseline-shift", _fmt_float_clipboard(t.baseline_shift)))
        if t.dx is not None: attrs.append(("dx", _fmt_float_clipboard(t.dx)))
        if t.font_family is not None: attrs.append(("font-family", t.font_family))
        if t.font_size is not None: attrs.append(("font-size", _fmt_float_clipboard(t.font_size)))
        if t.font_style is not None: attrs.append(("font-style", t.font_style))
        if t.font_variant is not None: attrs.append(("font-variant", t.font_variant))
        if t.font_weight is not None: attrs.append(("font-weight", t.font_weight))
        if t.jas_aa_mode is not None: attrs.append(("jas:aa-mode", t.jas_aa_mode))
        if t.jas_fractional_widths is not None:
            attrs.append(("jas:fractional-widths", "true" if t.jas_fractional_widths else "false"))
        if t.jas_kerning_mode is not None: attrs.append(("jas:kerning-mode", t.jas_kerning_mode))
        if t.jas_no_break is not None:
            attrs.append(("jas:no-break", "true" if t.jas_no_break else "false"))
        if t.jas_role is not None: attrs.append(("jas:role", t.jas_role))
        if t.jas_left_indent is not None:
            attrs.append(("jas:left-indent", _fmt_float_clipboard(t.jas_left_indent)))
        if t.jas_right_indent is not None:
            attrs.append(("jas:right-indent", _fmt_float_clipboard(t.jas_right_indent)))
        if t.jas_hyphenate is not None:
            attrs.append(("jas:hyphenate", "true" if t.jas_hyphenate else "false"))
        if t.jas_hanging_punctuation is not None:
            attrs.append(("jas:hanging-punctuation", "true" if t.jas_hanging_punctuation else "false"))
        if t.jas_list_style is not None:
            attrs.append(("jas:list-style", t.jas_list_style))
        if t.letter_spacing is not None: attrs.append(("letter-spacing", _fmt_float_clipboard(t.letter_spacing)))
        if t.line_height is not None: attrs.append(("line-height", _fmt_float_clipboard(t.line_height)))
        if t.rotate is not None: attrs.append(("rotate", _fmt_float_clipboard(t.rotate)))
        if t.style_name is not None: attrs.append(("jas:style-name", t.style_name))
        if t.text_decoration is not None and len(t.text_decoration) > 0:
            attrs.append(("text-decoration", " ".join(t.text_decoration)))
        if t.text_rendering is not None: attrs.append(("text-rendering", t.text_rendering))
        if t.text_transform is not None: attrs.append(("text-transform", t.text_transform))
        if t.xml_lang is not None: attrs.append(("xml:lang", t.xml_lang))
        attrs.sort(key=lambda kv: kv[0])
        for k, v in attrs:
            out.append(f' {k}="{_xml_escape(v)}"')
        out.append(">")
        out.append(_xml_escape(t.content))
        out.append("</tspan>")
    out.append("</text>")
    return "".join(out)


_TSPAN_ATTR_RE = None


def tspans_from_svg_fragment(svg_str: str) -> Optional[tuple[Tspan, ...]]:
    """Parse an SVG fragment of the shape emitted by
    ``tspans_to_svg_fragment`` into a tspan tuple with fresh ids.
    Returns ``None`` when the root is not ``<text>``."""
    import re
    s = svg_str.strip()
    text_pos = s.find("<text")
    if text_pos < 0:
        return None
    rest = s[text_pos:]
    # Find every <tspan ...>...</tspan> pair.
    pat = re.compile(r"<tspan([^>]*)>(.*?)</tspan>", re.DOTALL)
    results = []
    for i, m in enumerate(pat.finditer(rest)):
        attrs_str = m.group(1)
        content_raw = m.group(2)
        # Strip any nested tags.
        content = _xml_unescape(re.sub(r"<[^>]*>", "", content_raw))
        kw: dict = {"id": i, "content": content}
        # Parse attributes: name="value" or name='value'.
        attr_pat = re.compile(r"""\s*([A-Za-z:_][A-Za-z0-9:_\-]*)\s*=\s*(['"])([^'"]*)\2""")
        for am in attr_pat.finditer(attrs_str):
            k = am.group(1)
            v = _xml_unescape(am.group(3))
            if k == "baseline-shift":
                try: kw["baseline_shift"] = float(v)
                except ValueError: pass
            elif k == "dx":
                try: kw["dx"] = float(v)
                except ValueError: pass
            elif k == "font-family": kw["font_family"] = v
            elif k == "font-size":
                try: kw["font_size"] = float(v)
                except ValueError: pass
            elif k == "font-style": kw["font_style"] = v
            elif k == "font-variant": kw["font_variant"] = v
            elif k == "font-weight": kw["font_weight"] = v
            elif k == "jas:aa-mode": kw["jas_aa_mode"] = v
            elif k == "jas:fractional-widths": kw["jas_fractional_widths"] = (v == "true")
            elif k == "jas:kerning-mode": kw["jas_kerning_mode"] = v
            elif k == "jas:no-break": kw["jas_no_break"] = (v == "true")
            elif k == "jas:role": kw["jas_role"] = v
            elif k == "jas:left-indent":
                try: kw["jas_left_indent"] = float(v)
                except ValueError: pass
            elif k == "jas:right-indent":
                try: kw["jas_right_indent"] = float(v)
                except ValueError: pass
            elif k == "jas:hyphenate": kw["jas_hyphenate"] = (v == "true")
            elif k == "jas:hanging-punctuation": kw["jas_hanging_punctuation"] = (v == "true")
            elif k == "jas:list-style": kw["jas_list_style"] = v
            elif k == "letter-spacing":
                try: kw["letter_spacing"] = float(v)
                except ValueError: pass
            elif k == "line-height":
                try: kw["line_height"] = float(v)
                except ValueError: pass
            elif k == "rotate":
                try: kw["rotate"] = float(v)
                except ValueError: pass
            elif k == "jas:style-name": kw["style_name"] = v
            elif k == "text-decoration":
                parts = tuple(p for p in v.split() if p and p != "none")
                kw["text_decoration"] = parts
            elif k == "text-rendering": kw["text_rendering"] = v
            elif k == "text-transform": kw["text_transform"] = v
            elif k == "xml:lang": kw["xml_lang"] = v
        results.append(Tspan(**kw))
    return tuple(results) if results else None


def merge_tspan_overrides(target: Tspan, source: Tspan) -> Tspan:
    """Return a new ``Tspan`` carrying every non-``None`` override
    field from ``source`` on top of ``target``. Does not touch ``id``
    or ``content``. Used by the next-typed-character state (the
    "pending override" template) when applying captured overrides to
    newly-typed tspans.
    """
    return replace(
        target,
        baseline_shift=source.baseline_shift if source.baseline_shift is not None else target.baseline_shift,
        dx=source.dx if source.dx is not None else target.dx,
        font_family=source.font_family if source.font_family is not None else target.font_family,
        font_size=source.font_size if source.font_size is not None else target.font_size,
        font_style=source.font_style if source.font_style is not None else target.font_style,
        font_variant=source.font_variant if source.font_variant is not None else target.font_variant,
        font_weight=source.font_weight if source.font_weight is not None else target.font_weight,
        jas_aa_mode=source.jas_aa_mode if source.jas_aa_mode is not None else target.jas_aa_mode,
        jas_fractional_widths=source.jas_fractional_widths if source.jas_fractional_widths is not None else target.jas_fractional_widths,
        jas_kerning_mode=source.jas_kerning_mode if source.jas_kerning_mode is not None else target.jas_kerning_mode,
        jas_no_break=source.jas_no_break if source.jas_no_break is not None else target.jas_no_break,
        jas_role=source.jas_role if source.jas_role is not None else target.jas_role,
        jas_left_indent=source.jas_left_indent if source.jas_left_indent is not None else target.jas_left_indent,
        jas_right_indent=source.jas_right_indent if source.jas_right_indent is not None else target.jas_right_indent,
        jas_hyphenate=source.jas_hyphenate if source.jas_hyphenate is not None else target.jas_hyphenate,
        jas_hanging_punctuation=source.jas_hanging_punctuation if source.jas_hanging_punctuation is not None else target.jas_hanging_punctuation,
        jas_list_style=source.jas_list_style if source.jas_list_style is not None else target.jas_list_style,
        letter_spacing=source.letter_spacing if source.letter_spacing is not None else target.letter_spacing,
        line_height=source.line_height if source.line_height is not None else target.line_height,
        rotate=source.rotate if source.rotate is not None else target.rotate,
        style_name=source.style_name if source.style_name is not None else target.style_name,
        text_decoration=source.text_decoration if source.text_decoration is not None else target.text_decoration,
        text_rendering=source.text_rendering if source.text_rendering is not None else target.text_rendering,
        text_transform=source.text_transform if source.text_transform is not None else target.text_transform,
        transform=source.transform if source.transform is not None else target.transform,
        xml_lang=source.xml_lang if source.xml_lang is not None else target.xml_lang,
    )


class Affinity(Enum):
    """Caret side at a tspan boundary. See TSPAN.md Text-edit session
    integration — when a character index lands exactly on the join
    between two tspans, the affinity decides which side "wins".

    ``LEFT`` corresponds to the spec's default: "new text inherits the
    attributes of the previous character". ``RIGHT`` is used by callers
    that explicitly want the caret on the leading edge of the next
    tspan (e.g. the user just moved the caret rightward across a
    boundary).
    """
    LEFT = "left"
    RIGHT = "right"


def char_to_tspan_pos(
    tspans: list[Tspan], char_idx: int, affinity: Affinity
) -> tuple[int, int]:
    """Resolve a flat character index to a concrete ``(tspan_idx,
    offset)`` position given the tspan list and a caret affinity.

    - Mid-tspan: returns ``(i, char_idx - prefix_chars)``.
    - Boundary between tspans ``i`` and ``i+1``: ``LEFT`` returns the
      end of tspan ``i``; ``RIGHT`` returns the start of tspan ``i+1``.
      The very last boundary (end of the final tspan) always returns
      the end of that tspan regardless of affinity.
    - Beyond the last tspan: clamps to the end.
    - Empty tspan list: returns ``(0, 0)``.
    """
    if not tspans:
        return (0, 0)
    acc = 0
    for i, t in enumerate(tspans):
        n = len(t.content)
        if char_idx < acc + n:
            return (i, char_idx - acc)
        if char_idx == acc + n:
            if i + 1 == len(tspans):
                return (i, n)
            return (i, n) if affinity == Affinity.LEFT else (i + 1, 0)
        acc += n
    last = len(tspans) - 1
    return (last, len(tspans[last].content))


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
    "jas_kerning_mode", "jas_no_break", "jas_role",
    "jas_left_indent", "jas_right_indent", "jas_hyphenate",
    "jas_hanging_punctuation", "jas_list_style",
    "letter_spacing", "line_height", "rotate", "style_name",
    "text_decoration", "text_rendering", "text_transform",
    "transform", "xml_lang",
)


def _attrs_equal(a: Tspan, b: Tspan) -> bool:
    """``True`` when every override slot agrees. Content and id ignored."""
    return all(getattr(a, s) == getattr(b, s) for s in _ATTR_SLOTS)


def copy_range(original: list[Tspan], char_start: int, char_end: int) -> list[Tspan]:
    """Extract the covered slice ``[char_start, char_end)`` of
    ``original`` as a fresh tspan list. Each returned tspan carries
    its source tspan's overrides and id, with ``content`` truncated
    to the overlap. Empty / inverted range → ``[]``; out-of-range
    bounds saturate. Building block for tspan-aware clipboard.
    """
    if char_start >= char_end:
        return []
    total = sum(len(t.content) for t in original)
    s = min(char_start, total)
    e = min(char_end, total)
    if s >= e:
        return []
    result: list[Tspan] = []
    cursor = 0
    for t in original:
        t_len = len(t.content)
        t_start = cursor
        t_end = t_start + t_len
        overlap_start = max(s, t_start)
        overlap_end = min(e, t_end)
        if overlap_start < overlap_end:
            local_start = overlap_start - t_start
            local_end = overlap_end - t_start
            result.append(replace(t, content=t.content[local_start:local_end]))
        cursor = t_end
    return result


def insert_tspans_at(original: list[Tspan], char_pos: int,
                     to_insert: list[Tspan]) -> list[Tspan]:
    """Splice ``to_insert`` into ``original`` at character position
    ``char_pos``. Boundary insert slots between neighbours; mid-tspan
    insert splits that tspan around the insertion. Ids on
    ``to_insert`` are reassigned above ``original``'s max id to
    avoid collisions. Final ``merge`` pass collapses adjacent-equal
    tspans.
    """
    if not any(t.content for t in to_insert):
        return list(original)
    base_max = max((t.id for t in original), default=-1)
    next_id = base_max + 1
    reindexed: list[Tspan] = []
    for t in to_insert:
        reindexed.append(replace(t, id=next_id))
        next_id += 1
    total = sum(len(t.content) for t in original)
    pos = min(char_pos, total)
    before: list[Tspan] = []
    after: list[Tspan] = []
    cursor = 0
    for t in original:
        t_len = len(t.content)
        t_end = cursor + t_len
        if t_end <= pos:
            before.append(t)
        elif cursor >= pos:
            after.append(t)
        else:
            local = pos - cursor
            before.append(replace(t, content=t.content[:local]))
            # Right half gets a fresh id to avoid colliding with the
            # left half keeping the original id.
            after.append(replace(t, id=next_id, content=t.content[local:]))
            next_id += 1
        cursor = t_end
    return merge(before + reindexed + after)


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
