"""Eyedropper extract / apply helpers.

Pure functions plus an ``Appearance`` data container:

  - ``extract_appearance(element)`` snapshots the source element's
    relevant attrs into a serializable blob suitable for
    ``state.eyedropper_cache``.

  - ``apply_appearance(target, appearance, config)`` returns a copy
    of ``target`` with attrs from ``appearance`` written onto it,
    gated by the master / sub toggles in ``config``.

See ``transcripts/EYEDROPPER_TOOL.md`` for the full spec.
Cross-language parity is mechanical — the Rust / Swift / OCaml
ports of this module follow the same shape.

Phase 1 limitations:

  - Character / Paragraph extraction / apply is stubbed; the
    ``Appearance`` carries ``character`` / ``paragraph`` as opaque
    JSON so the cache can round-trip without losing data, but
    Phase 1 writes don't yet thread through Text element internals.

  - Stroke profile copies ``width_points`` on Path / Line; other
    element types have no profile and the call is a no-op.

  - Gradient / pattern fills are not sampled in Phase 1 — only solid
    fills round-trip. A non-solid source fill is treated as "no fill
    data sampled" (cached as ``None``).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from typing import Any

from geometry.element import (
    ArrowAlign,
    Arrowhead,
    BlendMode,
    Color,
    Element,
    Fill,
    Group,
    Layer,
    Line,
    LineCap,
    LineJoin,
    Path,
    Stroke,
    StrokeAlign,
    StrokeWidthPoint,
    Visibility,
    with_fill,
    with_stroke,
    with_stroke_brush,
    with_width_points,
)


# -----------------------------------------------------------------------
# Data
# -----------------------------------------------------------------------


@dataclass(frozen=True)
class Appearance:
    """Snapshot of a source element's attrs.

    Round-trips through JSON via ``state.eyedropper_cache``. Fields
    are wrapped in ``Optional`` (or empty tuple) so the cache can
    encode "not sampled" distinctly from "sampled as default".
    """

    fill: Fill | None = None
    stroke: Stroke | None = None
    opacity: float | None = None
    blend_mode: BlendMode | None = None
    stroke_brush: str | None = None
    width_points: tuple[StrokeWidthPoint, ...] = ()
    # Phase 1 stub: character / paragraph data is round-tripped as
    # opaque JSON. A follow-up phase replaces these with concrete
    # fields and full Text-element extract / apply.
    character: dict[str, Any] | None = None
    paragraph: dict[str, Any] | None = None


@dataclass(frozen=True)
class EyedropperConfig:
    """Toggle configuration mirroring the 25 ``state.eyedropper_*``
    boolean keys.

    Master toggles gate entire groups; sub-toggles gate individual
    attrs within a group. Both must be true for an attribute to be
    applied. All toggles default to True per
    ``EYEDROPPER_TOOL.md`` §State persistence.
    """

    fill: bool = True

    stroke: bool = True
    stroke_color: bool = True
    stroke_weight: bool = True
    stroke_cap_join: bool = True
    stroke_align: bool = True
    stroke_dash: bool = True
    stroke_arrowheads: bool = True
    stroke_profile: bool = True
    stroke_brush: bool = True

    opacity: bool = True
    opacity_alpha: bool = True
    opacity_blend: bool = True

    character: bool = True
    character_font: bool = True
    character_size: bool = True
    character_leading: bool = True
    character_kerning: bool = True
    character_tracking: bool = True
    character_color: bool = True

    paragraph: bool = True
    paragraph_align: bool = True
    paragraph_indent: bool = True
    paragraph_space: bool = True
    paragraph_hyphenate: bool = True


# -----------------------------------------------------------------------
# Eligibility
# -----------------------------------------------------------------------


def is_source_eligible(element: Element) -> bool:
    """Source-side eligibility per EYEDROPPER_TOOL.md §Eligibility.

    Locked is OK (we read, don't write); Hidden is not (no
    hit-test). Group / Layer are never sources — the caller is
    responsible for descending to the innermost element under the
    cursor.
    """
    if getattr(element, "visibility", None) == Visibility.INVISIBLE:
        return False
    return not isinstance(element, (Group, Layer))


def is_target_eligible(element: Element) -> bool:
    """Target-side eligibility per EYEDROPPER_TOOL.md §Eligibility.

    Locked is not OK (writes need permission); Hidden is OK
    (writes persist). Group / Layer are never targets — the caller
    recurses into them and applies to leaves.
    """
    if getattr(element, "locked", False):
        return False
    return not isinstance(element, (Group, Layer))


# -----------------------------------------------------------------------
# Extract
# -----------------------------------------------------------------------


def extract_appearance(element: Element) -> Appearance:
    """Snapshot the source element's attrs into an ``Appearance``.

    The caller is responsible for source-eligibility; this function
    does not filter.
    """
    return Appearance(
        fill=getattr(element, "fill", None),
        stroke=getattr(element, "stroke", None),
        opacity=getattr(element, "opacity", 1.0),
        blend_mode=getattr(element, "blend_mode", BlendMode.NORMAL),
        stroke_brush=_extract_stroke_brush(element),
        width_points=_extract_width_points(element),
        character=None,  # Phase 1 stub
        paragraph=None,  # Phase 1 stub
    )


def _extract_stroke_brush(element: Element) -> str | None:
    if isinstance(element, Path):
        return element.stroke_brush
    return None


def _extract_width_points(
    element: Element,
) -> tuple[StrokeWidthPoint, ...]:
    if isinstance(element, (Line, Path)):
        return element.width_points
    return ()


# -----------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------


def apply_appearance(
    target: Element, appearance: Appearance, config: EyedropperConfig
) -> Element:
    """Return a copy of ``target`` with attrs from ``appearance``
    applied per ``config``.

    Master OFF skips the entire group; master ON + sub OFF skips
    that sub-attribute. The caller is responsible for target-
    eligibility (locked / container check); this function applies
    to whatever it is given.
    """
    result = target

    # Fill
    if config.fill:
        result = with_fill(result, appearance.fill)

    # Stroke (master + sub-toggles, then brush + profile separately)
    if config.stroke:
        result = _apply_stroke_with_subs(result, appearance.stroke, config)
        if config.stroke_brush:
            result = with_stroke_brush(result, appearance.stroke_brush)
        if config.stroke_profile:
            # Profile lives in width_points (Line / Path only); other
            # variants pass through unchanged.
            result = with_width_points(result, appearance.width_points)

    # Opacity (master + 2 sub-toggles)
    if config.opacity:
        if config.opacity_alpha and appearance.opacity is not None:
            result = _with_opacity(result, appearance.opacity)
        if config.opacity_blend and appearance.blend_mode is not None:
            result = _with_blend_mode(result, appearance.blend_mode)

    # Character / Paragraph: Phase 1 stub — no-op.
    return result


def _apply_stroke_with_subs(
    target: Element,
    src: Stroke | None,
    config: EyedropperConfig,
) -> Element:
    """Helper for the Stroke group's per-sub-toggle apply. Mirrors
    the Rust apply_stroke_with_subs.

    When the source has no stroke, propagate "no stroke" (master
    is on, the caller already gated). When all sub-toggles are
    off, leave the target's stroke alone.
    """
    if src is None:
        return with_stroke(target, None)

    any_sub = (
        config.stroke_color
        or config.stroke_weight
        or config.stroke_cap_join
        or config.stroke_align
        or config.stroke_dash
        or config.stroke_arrowheads
    )
    if not any_sub:
        return target

    # Start from the target's existing stroke; synthesize a base
    # using the source's color and width when target had none.
    existing = getattr(target, "stroke", None)
    if existing is None:
        existing = Stroke(color=src.color, width=src.width)

    new_stroke = Stroke(
        color=src.color if config.stroke_color else existing.color,
        width=src.width if config.stroke_weight else existing.width,
        linecap=src.linecap if config.stroke_cap_join else existing.linecap,
        linejoin=src.linejoin if config.stroke_cap_join else existing.linejoin,
        miter_limit=(
            src.miter_limit if config.stroke_cap_join else existing.miter_limit
        ),
        align=src.align if config.stroke_align else existing.align,
        dash_pattern=(
            src.dash_pattern if config.stroke_dash else existing.dash_pattern
        ),
        start_arrow=(
            src.start_arrow if config.stroke_arrowheads else existing.start_arrow
        ),
        end_arrow=(
            src.end_arrow if config.stroke_arrowheads else existing.end_arrow
        ),
        start_arrow_scale=(
            src.start_arrow_scale
            if config.stroke_arrowheads
            else existing.start_arrow_scale
        ),
        end_arrow_scale=(
            src.end_arrow_scale
            if config.stroke_arrowheads
            else existing.end_arrow_scale
        ),
        arrow_align=(
            src.arrow_align if config.stroke_arrowheads else existing.arrow_align
        ),
        opacity=src.opacity if config.stroke_color else existing.opacity,
    )
    return with_stroke(target, new_stroke)


def _with_opacity(element: Element, opacity: float) -> Element:
    """Replace opacity on any element variant.

    Element.py has no public with_opacity helper; every concrete
    element subclass exposes opacity directly via dataclass
    field, so dataclasses.replace handles it uniformly.
    """
    if hasattr(element, "opacity"):
        return dataclasses.replace(element, opacity=opacity)
    return element


def _with_blend_mode(element: Element, blend_mode: BlendMode) -> Element:
    """Replace blend_mode on any element variant. Same rationale
    as ``_with_opacity`` — every concrete subclass has the field."""
    if hasattr(element, "blend_mode"):
        return dataclasses.replace(element, blend_mode=blend_mode)
    return element


# -----------------------------------------------------------------------
# JSON serialization
# -----------------------------------------------------------------------
#
# The cache lives in state.eyedropper_cache as a JSON object. We
# round-trip Appearance through a dict whose keys match the Rust
# serde-derived form (and the Swift / OCaml ports):
# `fill` / `stroke` / `opacity` / `blend_mode` / `stroke_brush` /
# `width_points` / `character` / `paragraph`. Empty fields are
# omitted.


def appearance_to_dict(app: Appearance) -> dict[str, Any]:
    """Serialize ``app`` to a JSON-compatible dictionary."""
    out: dict[str, Any] = {}
    if app.fill is not None:
        out["fill"] = _fill_to_dict(app.fill)
    if app.stroke is not None:
        out["stroke"] = _stroke_to_dict(app.stroke)
    if app.opacity is not None:
        out["opacity"] = app.opacity
    if app.blend_mode is not None:
        out["blend_mode"] = _blend_mode_to_string(app.blend_mode)
    if app.stroke_brush is not None:
        out["stroke_brush"] = app.stroke_brush
    if app.width_points:
        out["width_points"] = [
            {"t": wp.t, "width_left": wp.width_left, "width_right": wp.width_right}
            for wp in app.width_points
        ]
    if app.character is not None:
        out["character"] = app.character
    if app.paragraph is not None:
        out["paragraph"] = app.paragraph
    return out


def appearance_from_dict(d: dict[str, Any]) -> Appearance:
    """Parse a JSON-compatible dict back into an ``Appearance``.

    Missing fields decode as ``None`` / empty. Returns an empty
    ``Appearance()`` when ``d`` is not a dict-like object.
    """
    if not isinstance(d, dict):
        return Appearance()
    fill = _fill_from_dict(d.get("fill")) if d.get("fill") else None
    stroke = _stroke_from_dict(d.get("stroke")) if d.get("stroke") else None
    opacity = d.get("opacity") if isinstance(d.get("opacity"), (int, float)) else None
    blend_mode_str = d.get("blend_mode")
    blend_mode = (
        _blend_mode_from_string(blend_mode_str)
        if isinstance(blend_mode_str, str)
        else None
    )
    stroke_brush = d.get("stroke_brush") if isinstance(d.get("stroke_brush"), str) else None
    raw_wps = d.get("width_points") or []
    width_points: tuple[StrokeWidthPoint, ...] = tuple(
        StrokeWidthPoint(
            t=float(wp.get("t", 0.0)),
            width_left=float(wp.get("width_left", 0.0)),
            width_right=float(wp.get("width_right", 0.0)),
        )
        for wp in raw_wps
        if isinstance(wp, dict)
    )
    character = d.get("character") if isinstance(d.get("character"), dict) else None
    paragraph = d.get("paragraph") if isinstance(d.get("paragraph"), dict) else None
    return Appearance(
        fill=fill,
        stroke=stroke,
        opacity=float(opacity) if opacity is not None else None,
        blend_mode=blend_mode,
        stroke_brush=stroke_brush,
        width_points=width_points,
        character=character,
        paragraph=paragraph,
    )


def _fill_to_dict(f: Fill) -> dict[str, Any]:
    return {"color": _color_to_string(f.color), "opacity": f.opacity}


def _fill_from_dict(d: Any) -> Fill | None:
    if not isinstance(d, dict):
        return None
    color = _color_from_any(d.get("color"))
    if color is None:
        return None
    opacity = d.get("opacity", 1.0)
    return Fill(color=color, opacity=float(opacity))


def _stroke_to_dict(s: Stroke) -> dict[str, Any]:
    return {
        "color": _color_to_string(s.color),
        "width": s.width,
        "linecap": _linecap_to_string(s.linecap),
        "linejoin": _linejoin_to_string(s.linejoin),
        "miter_limit": s.miter_limit,
        "align": _stroke_align_to_string(s.align),
        "dash_pattern": list(s.dash_pattern),
        "start_arrow": _arrowhead_to_string(s.start_arrow),
        "end_arrow": _arrowhead_to_string(s.end_arrow),
        "start_arrow_scale": s.start_arrow_scale,
        "end_arrow_scale": s.end_arrow_scale,
        "arrow_align": _arrow_align_to_string(s.arrow_align),
        "opacity": s.opacity,
    }


def _stroke_from_dict(d: Any) -> Stroke | None:
    if not isinstance(d, dict):
        return None
    color = _color_from_any(d.get("color"))
    if color is None:
        return None
    return Stroke(
        color=color,
        width=float(d.get("width", 1.0)),
        linecap=_linecap_from_string(d.get("linecap", "butt")),
        linejoin=_linejoin_from_string(d.get("linejoin", "miter")),
        miter_limit=float(d.get("miter_limit", 10.0)),
        align=_stroke_align_from_string(d.get("align", "center")),
        dash_pattern=tuple(d.get("dash_pattern") or ()),
        start_arrow=_arrowhead_from_string(d.get("start_arrow", "none")),
        end_arrow=_arrowhead_from_string(d.get("end_arrow", "none")),
        start_arrow_scale=float(d.get("start_arrow_scale", 100.0)),
        end_arrow_scale=float(d.get("end_arrow_scale", 100.0)),
        arrow_align=_arrow_align_from_string(d.get("arrow_align", "tip_at_end")),
        opacity=float(d.get("opacity", 1.0)),
    )


def _color_to_string(c: Color) -> str:
    return c.to_hex()


def _color_from_any(v: Any) -> Color | None:
    if isinstance(v, str):
        return Color.from_hex(v)
    if isinstance(v, (list, tuple)) and len(v) >= 3:
        a = float(v[3]) if len(v) >= 4 else 1.0
        return Color.rgb(float(v[0]), float(v[1]), float(v[2]), a)
    if isinstance(v, dict) and "r" in v and "g" in v and "b" in v:
        return Color.rgb(
            float(v["r"]), float(v["g"]), float(v["b"]), float(v.get("a", 1.0))
        )
    return None


def _linecap_to_string(v: LineCap) -> str:
    return {LineCap.BUTT: "butt", LineCap.ROUND: "round", LineCap.SQUARE: "square"}[v]


def _linecap_from_string(s: str) -> LineCap:
    return {"round": LineCap.ROUND, "square": LineCap.SQUARE}.get(s, LineCap.BUTT)


def _linejoin_to_string(v: LineJoin) -> str:
    return {
        LineJoin.MITER: "miter",
        LineJoin.ROUND: "round",
        LineJoin.BEVEL: "bevel",
    }[v]


def _linejoin_from_string(s: str) -> LineJoin:
    return {"round": LineJoin.ROUND, "bevel": LineJoin.BEVEL}.get(s, LineJoin.MITER)


def _stroke_align_to_string(v: StrokeAlign) -> str:
    return {
        StrokeAlign.CENTER: "center",
        StrokeAlign.INSIDE: "inside",
        StrokeAlign.OUTSIDE: "outside",
    }[v]


def _stroke_align_from_string(s: str) -> StrokeAlign:
    return {"inside": StrokeAlign.INSIDE, "outside": StrokeAlign.OUTSIDE}.get(
        s, StrokeAlign.CENTER
    )


def _arrowhead_to_string(v: Arrowhead) -> str:
    return v.value if hasattr(v, "value") else str(v)


def _arrowhead_from_string(s: str) -> Arrowhead:
    try:
        return Arrowhead(s)
    except ValueError:
        return Arrowhead.NONE


def _arrow_align_to_string(v: ArrowAlign) -> str:
    return {
        ArrowAlign.TIP_AT_END: "tip_at_end",
        ArrowAlign.CENTER_AT_END: "center_at_end",
    }[v]


def _arrow_align_from_string(s: str) -> ArrowAlign:
    return {"center_at_end": ArrowAlign.CENTER_AT_END}.get(s, ArrowAlign.TIP_AT_END)


def _blend_mode_to_string(v: BlendMode) -> str:
    return v.value if hasattr(v, "value") else str(v)


def _blend_mode_from_string(s: str) -> BlendMode | None:
    try:
        return BlendMode(s)
    except ValueError:
        return None


# Suppress unused-import linter warning for `field`; reserved for
# future structural fields on Appearance.
_ = field
