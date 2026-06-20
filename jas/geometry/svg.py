"""Convert between Document and SVG format.

Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
The conversion factor is 96/72 (CSS px per pt at 96 DPI).
"""

import dataclasses
import json
import re
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from document.document import Document
from geometry.normalize import dedupe_element_ids, normalize_document
from geometry.element import (
    APPROX_CHAR_WIDTH_FACTOR,
    ArcTo, Circle, ClosePath, Color, RgbColor, CompoundOperation,
    CompoundShape, CurveTo, Element,
    Ellipse, Fill, Group, Layer, Line, LineCap, LineJoin, LineTo, MoveTo, Path,
    PathCommand, Polygon, Polyline, QuadTo, Rect, RecordedElem, ReferenceElem,
    GeneratedElem,
    SmoothCurveTo,
    SmoothQuadTo, Stroke, Text, TextPath, Transform,
)

_PT_TO_PX = 96.0 / 72.0


def _px(v: float) -> float:
    """Convert a point value to px."""
    return v * _PT_TO_PX


def _fmt(v: float) -> str:
    """Format a float, stripping trailing zeros."""
    s = f"{v:.4f}"
    s = s.rstrip("0").rstrip(".")
    return s


def _color_str(c: Color) -> str:
    r_val, g_val, b_val, a_val = c.to_rgba()
    r = int(round(r_val * 255))
    g = int(round(g_val * 255))
    b = int(round(b_val * 255))
    if a_val < 1.0:
        return f"rgba({r},{g},{b},{_fmt(a_val)})"
    return f"rgb({r},{g},{b})"


def _fill_attrs(fill: Fill | None) -> str:
    if fill is None:
        return ' fill="none"'
    s = f' fill="{_color_str(fill.color)}"'
    if fill.opacity < 1.0:
        s += f' fill-opacity="{_fmt(fill.opacity)}"'
    return s


def _stroke_attrs(stroke: Stroke | None) -> str:
    if stroke is None:
        return ' stroke="none"'
    parts = [f' stroke="{_color_str(stroke.color)}"']
    parts.append(f' stroke-width="{_fmt(_px(stroke.width))}"')
    if stroke.linecap != LineCap.BUTT:
        parts.append(f' stroke-linecap="{stroke.linecap.value}"')
    if stroke.linejoin != LineJoin.MITER:
        parts.append(f' stroke-linejoin="{stroke.linejoin.value}"')
    if stroke.opacity < 1.0:
        parts.append(f' stroke-opacity="{_fmt(stroke.opacity)}"')
    # Workspace-private attribute — see DASH_ALIGN.md §Persistence.
    # Identity-omitted when False; round-trips through jas-authored
    # files; ignored on import from non-jas SVG.
    if stroke.dash_align_anchors:
        parts.append(' data-jas-dash-align-anchors="true"')
    return "".join(parts)


def _transform_attr(t: Transform | None) -> str:
    if t is None:
        return ""
    # Scale the translation components to px
    return (f' transform="matrix({_fmt(t.a)},{_fmt(t.b)},{_fmt(t.c)},'
            f'{_fmt(t.d)},{_fmt(_px(t.e))},{_fmt(_px(t.f))})"')


def _instance_transform_attr(t: Transform | None) -> str:
    """Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance transform rides
    ``data-jas-instance-transform`` (the render CTM rides the ``transform``
    attr). Same matrix format as ``_transform_attr``; emitted ONLY when set so
    existing <use> fixtures stay byte-identical."""
    if t is None:
        return ""
    return (f' data-jas-instance-transform="matrix({_fmt(t.a)},{_fmt(t.b)},'
            f'{_fmt(t.c)},{_fmt(t.d)},{_fmt(_px(t.e))},{_fmt(_px(t.f))})"')


def _opacity_attr(opacity: float) -> str:
    if opacity >= 1.0:
        return ""
    return f' opacity="{_fmt(opacity)}"'


def _name_attr(name: str | None) -> str:
    """User-visible element name → ``inkscape:label`` attribute. Reader
    accepts both this and a ``<title>`` child for cross-tool interop.
    """
    if not name:
        return ""
    return f' inkscape:label="{escape(name)}"'


def _id_attr(eid: str | None) -> str:
    """Stable element identity → standard SVG ``id`` attribute. Emitted
    only when set (Some/non-empty); id-less elements serialize
    byte-identically to before so existing fixtures stay stable.
    Mirrors :func:`_name_attr`.
    """
    if not eid:
        return ""
    return f' id="{escape(eid)}"'


def _tspan_svg(t) -> str:
    """Emit a single Tspan as an SVG ``<tspan ...>content</tspan>``.
    Only overridden attributes are emitted (inherited values are absent).
    Matches the Rust / Swift / OCaml ``tspan_svg`` — the 5 attributes
    that round-trip natively via SVG: font-family, font-size,
    font-weight, font-style, text-decoration.
    """
    attrs = ""
    if t.font_family is not None:
        attrs += f' font-family="{escape(t.font_family)}"'
    if t.font_size is not None:
        attrs += f' font-size="{_fmt(_px(t.font_size))}"'
    if t.font_weight is not None:
        attrs += f' font-weight="{escape(t.font_weight)}"'
    if t.font_style is not None:
        attrs += f' font-style="{escape(t.font_style)}"'
    if t.text_decoration is not None and t.text_decoration:
        joined = " ".join(t.text_decoration)
        attrs += f' text-decoration="{escape(joined)}"'
    # Per-tspan rotation. Our model stores a single float per tspan,
    # so per-glyph varying rotations require each glyph to live in
    # its own tspan (enforced by the Touch Type tool). SVG's
    # multi-value ``rotate="a1 a2 …"`` is handled on the parse side
    # by splitting the tspan into one per glyph.
    if t.rotate is not None:
        attrs += f' rotate="{_fmt(t.rotate)}"'
    if t.jas_role is not None:
        attrs += f' urn:jas:1:role="{escape(t.jas_role)}"'
    if t.jas_left_indent is not None:
        attrs += f' urn:jas:1:left-indent="{_fmt(t.jas_left_indent)}"'
    if t.jas_right_indent is not None:
        attrs += f' urn:jas:1:right-indent="{_fmt(t.jas_right_indent)}"'
    if t.jas_hyphenate is not None:
        attrs += f' urn:jas:1:hyphenate="{"true" if t.jas_hyphenate else "false"}"'
    if t.jas_hanging_punctuation is not None:
        attrs += f' urn:jas:1:hanging-punctuation="{"true" if t.jas_hanging_punctuation else "false"}"'
    if t.jas_list_style is not None:
        attrs += f' urn:jas:1:list-style="{escape(t.jas_list_style)}"'
    # Phase 1b1 panel-surface remainder. text-align / text-align-last /
    # text-indent serialise as bare CSS-style attribute names; the
    # spacing pair is jas-namespaced.
    if t.text_align is not None:
        attrs += f' text-align="{escape(t.text_align)}"'
    if t.text_align_last is not None:
        attrs += f' text-align-last="{escape(t.text_align_last)}"'
    if t.text_indent is not None:
        attrs += f' text-indent="{_fmt(t.text_indent)}"'
    if t.jas_space_before is not None:
        attrs += f' urn:jas:1:space-before="{_fmt(t.jas_space_before)}"'
    if t.jas_space_after is not None:
        attrs += f' urn:jas:1:space-after="{_fmt(t.jas_space_after)}"'
    # Phase 1b2 / Phase 8 Justification dialog attrs.
    if t.jas_word_spacing_min is not None:
        attrs += f' urn:jas:1:word-spacing-min="{_fmt(t.jas_word_spacing_min)}"'
    if t.jas_word_spacing_desired is not None:
        attrs += f' urn:jas:1:word-spacing-desired="{_fmt(t.jas_word_spacing_desired)}"'
    if t.jas_word_spacing_max is not None:
        attrs += f' urn:jas:1:word-spacing-max="{_fmt(t.jas_word_spacing_max)}"'
    if t.jas_letter_spacing_min is not None:
        attrs += f' urn:jas:1:letter-spacing-min="{_fmt(t.jas_letter_spacing_min)}"'
    if t.jas_letter_spacing_desired is not None:
        attrs += f' urn:jas:1:letter-spacing-desired="{_fmt(t.jas_letter_spacing_desired)}"'
    if t.jas_letter_spacing_max is not None:
        attrs += f' urn:jas:1:letter-spacing-max="{_fmt(t.jas_letter_spacing_max)}"'
    if t.jas_glyph_scaling_min is not None:
        attrs += f' urn:jas:1:glyph-scaling-min="{_fmt(t.jas_glyph_scaling_min)}"'
    if t.jas_glyph_scaling_desired is not None:
        attrs += f' urn:jas:1:glyph-scaling-desired="{_fmt(t.jas_glyph_scaling_desired)}"'
    if t.jas_glyph_scaling_max is not None:
        attrs += f' urn:jas:1:glyph-scaling-max="{_fmt(t.jas_glyph_scaling_max)}"'
    if t.jas_auto_leading is not None:
        attrs += f' urn:jas:1:auto-leading="{_fmt(t.jas_auto_leading)}"'
    if t.jas_single_word_justify is not None:
        attrs += f' urn:jas:1:single-word-justify="{escape(t.jas_single_word_justify)}"'
    if t.jas_hyphenate_min_word is not None:
        attrs += f' urn:jas:1:hyphenate-min-word="{_fmt(t.jas_hyphenate_min_word)}"'
    if t.jas_hyphenate_min_before is not None:
        attrs += f' urn:jas:1:hyphenate-min-before="{_fmt(t.jas_hyphenate_min_before)}"'
    if t.jas_hyphenate_min_after is not None:
        attrs += f' urn:jas:1:hyphenate-min-after="{_fmt(t.jas_hyphenate_min_after)}"'
    if t.jas_hyphenate_limit is not None:
        attrs += f' urn:jas:1:hyphenate-limit="{_fmt(t.jas_hyphenate_limit)}"'
    if t.jas_hyphenate_zone is not None:
        attrs += f' urn:jas:1:hyphenate-zone="{_fmt(t.jas_hyphenate_zone)}"'
    if t.jas_hyphenate_bias is not None:
        attrs += f' urn:jas:1:hyphenate-bias="{_fmt(t.jas_hyphenate_bias)}"'
    if t.jas_hyphenate_capitalized is not None:
        attrs += f' urn:jas:1:hyphenate-capitalized="{"true" if t.jas_hyphenate_capitalized else "false"}"'
    return f"<tspan{attrs}>{escape(t.content)}</tspan>"


def _text_extra_attrs(elem) -> str:
    """Build the attribute-string fragment for the 11 Character-panel
    attributes on a ``<text>`` element. Emits each attribute only
    when non-empty (per CHARACTER.md's identity-omission rule).
    """
    def attr(name: str, v: str) -> str:
        return f' {name}="{escape(v)}"' if v else ""
    return "".join([
        attr("text-transform", elem.text_transform),
        attr("font-variant", elem.font_variant),
        attr("baseline-shift", elem.baseline_shift),
        attr("line-height", elem.line_height),
        attr("letter-spacing", elem.letter_spacing),
        attr("xml:lang", elem.xml_lang),
        attr("urn:jas:1:aa-mode", elem.aa_mode),
        attr("rotate", elem.rotate),
        attr("horizontal-scale", elem.horizontal_scale),
        attr("vertical-scale", elem.vertical_scale),
        attr("urn:jas:1:kerning-mode", elem.kerning),
    ])


def _path_data(commands: tuple[PathCommand, ...]) -> str:
    parts: list[str] = []
    for cmd in commands:
        match cmd:
            case MoveTo(x, y):
                parts.append(f"M{_fmt(_px(x))},{_fmt(_px(y))}")
            case LineTo(x, y):
                parts.append(f"L{_fmt(_px(x))},{_fmt(_px(y))}")
            case CurveTo(x1, y1, x2, y2, x, y):
                parts.append(f"C{_fmt(_px(x1))},{_fmt(_px(y1))} "
                             f"{_fmt(_px(x2))},{_fmt(_px(y2))} "
                             f"{_fmt(_px(x, ))},{_fmt(_px(y))}")
            case SmoothCurveTo(x2, y2, x, y):
                parts.append(f"S{_fmt(_px(x2))},{_fmt(_px(y2))} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case QuadTo(x1, y1, x, y):
                parts.append(f"Q{_fmt(_px(x1))},{_fmt(_px(y1))} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case SmoothQuadTo(x, y):
                parts.append(f"T{_fmt(_px(x))},{_fmt(_px(y))}")
            case ArcTo(rx, ry, rotation, large_arc, sweep, x, y):
                la = 1 if large_arc else 0
                sw = 1 if sweep else 0
                parts.append(f"A{_fmt(_px(rx))},{_fmt(_px(ry))} "
                             f"{_fmt(rotation)} {la},{sw} "
                             f"{_fmt(_px(x))},{_fmt(_px(y))}")
            case ClosePath():
                parts.append("Z")
    return " ".join(parts)


def element_svg(elem: Element, indent: str = "") -> str:
    """Public: Render a single element as an SVG fragment (recursive for groups/layers)."""
    return _element_svg(elem, indent)


def _element_svg(elem: Element, indent: str) -> str:
    """Render an element as SVG XML."""
    match elem:
        case Line(x1=x1, y1=y1, x2=x2, y2=y2,
                  stroke=stroke, opacity=opacity, transform=transform,
                  name=name, id=eid):
            return (f'{indent}<line x1="{_fmt(_px(x1))}" y1="{_fmt(_px(y1))}"'
                    f' x2="{_fmt(_px(x2))}" y2="{_fmt(_px(y2))}"'
                    f'{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Rect(x=x, y=y, width=w, height=h, rx=rx, ry=ry,
                  fill=fill, stroke=stroke, opacity=opacity, transform=transform,
                  name=name, id=eid):
            rxy = ""
            if rx > 0:
                rxy += f' rx="{_fmt(_px(rx))}"'
            if ry > 0:
                rxy += f' ry="{_fmt(_px(ry))}"'
            return (f'{indent}<rect x="{_fmt(_px(x))}" y="{_fmt(_px(y))}"'
                    f' width="{_fmt(_px(w))}" height="{_fmt(_px(h))}"'
                    f'{rxy}'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Circle(cx=cx, cy=cy, r=r,
                    fill=fill, stroke=stroke, opacity=opacity, transform=transform,
                    name=name, id=eid):
            return (f'{indent}<circle cx="{_fmt(_px(cx))}" cy="{_fmt(_px(cy))}"'
                    f' r="{_fmt(_px(r))}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Ellipse(cx=cx, cy=cy, rx=rx, ry=ry,
                     fill=fill, stroke=stroke, opacity=opacity, transform=transform,
                     name=name, id=eid):
            return (f'{indent}<ellipse cx="{_fmt(_px(cx))}" cy="{_fmt(_px(cy))}"'
                    f' rx="{_fmt(_px(rx))}" ry="{_fmt(_px(ry))}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Polyline(points=pts, fill=fill, stroke=stroke,
                      opacity=opacity, transform=transform,
                      name=name, id=eid):
            ps = " ".join(f"{_fmt(_px(x))},{_fmt(_px(y))}" for x, y in pts)
            return (f'{indent}<polyline points="{ps}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Polygon(points=pts, fill=fill, stroke=stroke,
                     opacity=opacity, transform=transform,
                     name=name, id=eid):
            ps = " ".join(f"{_fmt(_px(x))},{_fmt(_px(y))}" for x, y in pts)
            return (f'{indent}<polygon points="{ps}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case Path(d=cmds, fill=fill, stroke=stroke,
                  opacity=opacity, transform=transform,
                  tool_origin=tool_origin,
                  name=name, id=eid):
            tool_origin_attr = (
                f' jas:tool-origin="{escape(tool_origin)}"'
                if tool_origin else ""
            )
            return (f'{indent}<path d="{_path_data(cmds)}"'
                    f'{_fill_attrs(fill)}{_stroke_attrs(stroke)}'
                    f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                    f'{tool_origin_attr}'
                    f'{_id_attr(eid)}{_name_attr(name)}/>')

        case TextPath():
            # Destructure via attribute access to avoid an even wider
            # match pattern now that Text/TextPath carry 11 extra
            # character-panel fields.
            elem_tp = elem
            offset_attr = (f' startOffset="{_fmt(elem_tp.start_offset * 100)}%"'
                           if elem_tp.start_offset > 0 else "")
            fw_attr = f' font-weight="{elem_tp.font_weight}"' if elem_tp.font_weight != "normal" else ""
            fst_attr = f' font-style="{elem_tp.font_style}"' if elem_tp.font_style != "normal" else ""
            td_attr = (f' text-decoration="{elem_tp.text_decoration}"'
                       if elem_tp.text_decoration not in ("none", "") else "")
            extra = _text_extra_attrs(elem_tp)
            # Pre-Tspan-compatible emission: a single no-override tspan
            # round-trips as a flat <textPath>content</textPath> (no
            # <tspan> wrapper). Multi-tspan or any override carries
            # xml:space="preserve" so inter-tspan whitespace is byte-
            # stable across round-trips (TSPAN.md SVG serialization).
            tp_is_flat = len(elem_tp.tspans) == 1 and elem_tp.tspans[0].has_no_overrides()
            if tp_is_flat:
                tp_body = escape(elem_tp.content)
                tp_space = ""
            else:
                tp_body = "".join(_tspan_svg(t) for t in elem_tp.tspans)
                tp_space = ' xml:space="preserve"'
            return (f'{indent}<text'
                    f'{_fill_attrs(elem_tp.fill)}{_stroke_attrs(elem_tp.stroke)}'
                    f' font-family="{escape(elem_tp.font_family)}"'
                    f' font-size="{_fmt(_px(elem_tp.font_size))}"'
                    f'{fw_attr}{fst_attr}{td_attr}{extra}'
                    f'{_opacity_attr(elem_tp.opacity)}{_transform_attr(elem_tp.transform)}'
                    f'{_id_attr(elem_tp.id)}>'
                    f'<textPath path="{_path_data(elem_tp.d)}"{offset_attr}{tp_space}>'
                    f'{tp_body}</textPath></text>')

        case Text():
            # See TextPath: attribute-access destructure.
            elem_t = elem
            area_attrs = ""
            if elem_t.width > 0 and elem_t.height > 0:
                area_attrs = (f' style="inline-size: {_fmt(_px(elem_t.width))}px;'
                              f' white-space: pre-wrap;"')
            fw_attr = f' font-weight="{elem_t.font_weight}"' if elem_t.font_weight != "normal" else ""
            fst_attr = f' font-style="{elem_t.font_style}"' if elem_t.font_style != "normal" else ""
            td_attr = (f' text-decoration="{elem_t.text_decoration}"'
                       if elem_t.text_decoration not in ("none", "") else "")
            extra = _text_extra_attrs(elem_t)
            # SVG `y` is the baseline of the first line; internally `y`
            # is the *top* of the layout box, so add the ascent (0.8 *
            # font_size, the same value `text_layout` uses).
            svg_y = elem_t.y + elem_t.font_size * 0.8
            is_flat = len(elem_t.tspans) == 1 and elem_t.tspans[0].has_no_overrides()
            if is_flat:
                body = escape(elem_t.content)
                space_attr = ""
            else:
                body = "".join(_tspan_svg(t) for t in elem_t.tspans)
                space_attr = ' xml:space="preserve"'
            return (f'{indent}<text x="{_fmt(_px(elem_t.x))}" y="{_fmt(_px(svg_y))}"'
                    f' font-family="{escape(elem_t.font_family)}"'
                    f' font-size="{_fmt(_px(elem_t.font_size))}"'
                    f'{fw_attr}{fst_attr}{td_attr}{extra}'
                    f'{area_attrs}'
                    f'{_fill_attrs(elem_t.fill)}{_stroke_attrs(elem_t.stroke)}'
                    f'{_opacity_attr(elem_t.opacity)}{_transform_attr(elem_t.transform)}'
                    f'{_id_attr(elem_t.id)}{space_attr}>'
                    f'{body}</text>')

        case Layer(children=children, name=name, opacity=opacity,
                   transform=transform, id=eid):
            label = f' inkscape:label="{escape(name)}"' if name else ""
            lines = [f'{indent}<g inkscape:groupmode="layer"{label}{_opacity_attr(opacity)}{_transform_attr(transform)}{_id_attr(eid)}>']
            for child in children:
                lines.append(_element_svg(child, indent + "  "))
            lines.append(f'{indent}</g>')
            return "\n".join(lines)

        case Group(children=children, opacity=opacity, transform=transform,
                   name=name, id=eid):
            lines = [f'{indent}<g{_id_attr(eid)}{_name_attr(name)}{_opacity_attr(opacity)}{_transform_attr(transform)}>']
            for child in children:
                lines.append(_element_svg(child, indent + "  "))
            lines.append(f'{indent}</g>')
            return "\n".join(lines)

        # Live elements (Phase 2, REFERENCE_GRAPH.md): a CompoundShape is
        # a <g data-jas-live="compound_shape" data-jas-operation=...>
        # wrapping its operands; a reference is native SVG
        # <use href="#target">. Both carry their own id/opacity/transform.
        # Mirrors the Rust ``element_svg`` Live arm.
        case CompoundShape(operation=operation, operands=operands,
                           opacity=opacity, transform=transform, id=eid):
            # Mirror Rust's common_attrs_no_name: opacity + transform + id,
            # but NOT name (live elements never emit inkscape:label).
            attrs = (f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                     f'{_id_attr(eid)}')
            lines = [f'{indent}<g data-jas-live="compound_shape"'
                     f' data-jas-operation="{operation.value}"{attrs}>']
            for child in operands:
                lines.append(_element_svg(child, indent + "  "))
            lines.append(f'{indent}</g>')
            return "\n".join(lines)

        case ReferenceElem(target=target, opacity=opacity,
                           transform=transform, id=eid,
                           instance_transform=instance_transform):
            # A reference is native SVG <use href="#id"> (Phase 2). Its own
            # id/opacity/transform ride the common attrs; the target is the
            # href. Any <use> imports back as a live reference (F-svg-use).
            #
            # Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance transform is
            # distinct from the render CTM (which rides the <use transform=...>
            # attr). It is emitted as data-jas-instance-transform in the same
            # matrix format, and ONLY when set so existing <use> fixtures stay
            # byte-identical.
            attrs = (f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                     f'{_id_attr(eid)}'
                     f'{_instance_transform_attr(instance_transform)}')
            return f'{indent}<use href="#{escape(target)}"{attrs}/>'

        case RecordedElem(inputs=inputs, opacity=opacity,
                          transform=transform, id=eid):
            # A recorded element exports as a data-jas-live group carrying the
            # recipe's input ids. Full SVG round-trip (the ops) is deferred
            # (RECORDED_ELEMENTS.md §8); no current fixture exercises it.
            # Mirror Rust common_attrs_no_name: opacity + transform + id, no
            # name (live elements never emit inkscape:label).
            attrs = (f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                     f'{_id_attr(eid)}')
            joined = ",".join(inputs)
            return (f'{indent}<g data-jas-live="recorded"'
                    f' data-jas-inputs="{escape(joined)}"{attrs}></g>')

        case GeneratedElem(concept_id=concept_id, params=params,
                           opacity=opacity, transform=transform, id=eid):
            # A generated element exports as a data-jas-live group carrying the
            # concept id + params. Full SVG round-trip is deferred (CONCEPTS.md);
            # no current fixture exercises it (data-jas-params is not compared).
            attrs = (f'{_opacity_attr(opacity)}{_transform_attr(transform)}'
                     f'{_id_attr(eid)}')
            params_str = json.dumps(params, sort_keys=True,
                                    separators=(",", ":"))
            return (f'{indent}<g data-jas-live="generated"'
                    f' data-jas-concept="{escape(concept_id)}"'
                    f' data-jas-params="{escape(params_str)}"{attrs}></g>')

    return ""


# Marks-and-Bleed + DocumentSetup SVG persistence (PRINT.md §Phase 2).
# Stored as <jas:document-setup> and <jas:print-preferences> children
# of <sodipodi:namedview>. Bleed values are written as raw point
# values (no px conversion) to keep the on-disk numbers intelligible
# and stable across viewports — they're print-domain quantities, not
# canvas geometry.

_SODIPODI_NS = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.0.dtd"
_JAS_NS = "urn:jas:1"


def _bool_str(b: bool) -> str:
    return "true" if b else "false"


def _color_management_to_xml(c, indent: str) -> str:
    return (
        f'{indent}<jas:color-management'
        f' document-profile="{escape(c.document_profile)}"'
        f' color-handling="{c.color_handling.value}"'
        f' printer-profile="{escape(c.printer_profile)}"'
        f' rendering-intent="{c.rendering_intent.value}"'
        f' preserve-rgb-numbers="{_bool_str(c.preserve_rgb_numbers)}"'
        f'/>'
    )


def _graphics_to_xml(g, indent: str) -> str:
    return (
        f'{indent}<jas:graphics'
        f' flatness="{_fmt(g.flatness)}"'
        f' font-download="{g.font_download.value}"'
        f' postscript-level="{g.postscript_level.value}"'
        f' data-format="{g.data_format.value}"'
        f' compatible-gradient-printing="{_bool_str(g.compatible_gradient_printing)}"'
        f' raster-effects-resolution="{_fmt(g.raster_effects_resolution)}"'
        f'/>'
    )


def _ink_override_to_xml(ink, indent: str) -> str:
    return (
        f'{indent}<jas:ink'
        f' name="{escape(ink.name)}"'
        f' print="{_bool_str(ink.print)}"'
        f' frequency="{_fmt(ink.frequency)}"'
        f' angle="{_fmt(ink.angle)}"'
        f' dot-shape="{ink.dot_shape.value}"'
        f'/>'
    )


def _output_to_xml(o, indent: str) -> str:
    inner = indent + "  "
    header = (
        f'{indent}<jas:output'
        f' mode="{o.mode.value}"'
        f' emulsion="{o.emulsion.value}"'
        f' image-polarity="{o.image_polarity.value}"'
        f' printer-resolution="{escape(o.printer_resolution)}"'
        f' convert-spot-to-process="{_bool_str(o.convert_spot_to_process)}"'
        f' overprint-black="{_bool_str(o.overprint_black)}"'
        f'>'
    )
    inks = "\n".join(_ink_override_to_xml(i, inner) for i in o.inks)
    return f"{header}\n{inks}\n{indent}</jas:output>"


def _advanced_to_xml(a, indent: str) -> str:
    return (
        f'{indent}<jas:advanced'
        f' print-as-bitmap="{_bool_str(a.print_as_bitmap)}"'
        f' overprint-flattener-preset="{a.overprint_flattener_preset.value}"'
        f'/>'
    )


def _document_setup_to_xml(s, indent: str) -> str:
    return (
        f'{indent}<jas:document-setup'
        f' bleed-top="{_fmt(s.bleed_top)}"'
        f' bleed-right="{_fmt(s.bleed_right)}"'
        f' bleed-bottom="{_fmt(s.bleed_bottom)}"'
        f' bleed-left="{_fmt(s.bleed_left)}"'
        f' bleed-uniform="{_bool_str(s.bleed_uniform)}"'
        f' show-images-outline="{_bool_str(s.show_images_outline)}"'
        f' highlight-substituted-glyphs="{_bool_str(s.highlight_substituted_glyphs)}"'
        f' grid-size="{_fmt(s.grid_size)}"'
        f' grid-color="{escape(s.grid_color)}"'
        f' paper-color="{escape(s.paper_color)}"'
        f' simulate-colored-paper="{_bool_str(s.simulate_colored_paper)}"'
        f' transparency-flattener-preset="{s.transparency_flattener_preset.value}"'
        f' discard-white-overprint="{_bool_str(s.discard_white_overprint)}"'
        f'/>'
    )


def _marks_and_bleed_to_xml(m, indent: str) -> str:
    return (
        f'{indent}<jas:marks-and-bleed'
        f' all-printer-marks="{_bool_str(m.all_printer_marks)}"'
        f' trim-marks="{_bool_str(m.trim_marks)}"'
        f' registration-marks="{_bool_str(m.registration_marks)}"'
        f' color-bars="{_bool_str(m.color_bars)}"'
        f' page-information="{_bool_str(m.page_information)}"'
        f' printer-mark-type="{m.printer_mark_type.value}"'
        f' trim-mark-weight="{_fmt(m.trim_mark_weight)}"'
        f' mark-offset="{_fmt(m.mark_offset)}"'
        f' use-document-bleed="{_bool_str(m.use_document_bleed)}"'
        f' bleed-top="{_fmt(m.bleed_top)}"'
        f' bleed-right="{_fmt(m.bleed_right)}"'
        f' bleed-bottom="{_fmt(m.bleed_bottom)}"'
        f' bleed-left="{_fmt(m.bleed_left)}"'
        f'/>'
    )


def _print_preferences_to_xml(p, indent: str) -> str:
    inner = indent + "  "
    parts = [
        f'{indent}<jas:print-preferences',
        f' preset-name="{escape(p.preset_name)}"',
        f' copies="{p.copies}"',
        f' collate="{_bool_str(p.collate)}"',
        f' reverse-order="{_bool_str(p.reverse_order)}"',
        f' artboard-range-mode="{p.artboard_range_mode.value}"',
        f' artboard-range="{escape(p.artboard_range)}"',
        f' ignore-artboards="{_bool_str(p.ignore_artboards)}"',
        f' skip-blank-artboards="{_bool_str(p.skip_blank_artboards)}"',
        f' media-size="{p.media_size.value}"',
        f' media-width="{_fmt(p.media_width)}"',
        f' media-height="{_fmt(p.media_height)}"',
        f' orientation="{p.orientation.value}"',
        f' auto-rotate="{_bool_str(p.auto_rotate)}"',
        f' transverse="{_bool_str(p.transverse)}"',
        f' print-layers="{p.print_layers.value}"',
        f' placement-x="{_fmt(p.placement_x)}"',
        f' placement-y="{_fmt(p.placement_y)}"',
        f' scaling-mode="{p.scaling_mode.value}"',
        f' custom-scale="{_fmt(p.custom_scale)}"',
        f' tile-overlap-h="{_fmt(p.tile_overlap_h)}"',
        f' tile-overlap-v="{_fmt(p.tile_overlap_v)}"',
        f' tile-range="{escape(p.tile_range)}"',
    ]
    header = "".join(parts)
    if p.printer_name is not None:
        header += f' printer-name="{escape(p.printer_name)}"'
    return (
        f'{header}>\n'
        f'{_marks_and_bleed_to_xml(p.marks_and_bleed, inner)}\n'
        f'{_output_to_xml(p.output, inner)}\n'
        f'{_graphics_to_xml(p.graphics, inner)}\n'
        f'{_color_management_to_xml(p.color_management, inner)}\n'
        f'{_advanced_to_xml(p.advanced, inner)}\n'
        f'{indent}</jas:print-preferences>'
    )


def document_to_svg(doc: Document) -> str:
    """Convert a Document to an SVG string."""
    from document.document_setup import DocumentSetup
    from document.print_preferences import PrintPreferences

    bx, by, bw, bh = doc.bounds()
    vb = (f"{_fmt(_px(bx))} {_fmt(_px(by))} "
          f"{_fmt(_px(bw))} {_fmt(_px(bh))}")
    setup_default = doc.document_setup == DocumentSetup()
    prefs_default = doc.print_preferences == PrintPreferences()
    needs_jas = (not setup_default) or (not prefs_default)
    ns_attrs = (
        f'xmlns="http://www.w3.org/2000/svg"'
        f' xmlns:inkscape="{_INKSCAPE_NS}"'
    )
    if needs_jas:
        ns_attrs += (
            f' xmlns:sodipodi="{_SODIPODI_NS}"'
            f' xmlns:jas="{_JAS_NS}"'
        )
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg {ns_attrs}'
        f' viewBox="{vb}"'
        f' width="{_fmt(_px(bw))}" height="{_fmt(_px(bh))}">',
    ]
    if needs_jas:
        lines.append('  <sodipodi:namedview id="namedview1">')
        if not setup_default:
            lines.append(_document_setup_to_xml(doc.document_setup, "    "))
        if not prefs_default:
            lines.append(_print_preferences_to_xml(doc.print_preferences, "    "))
        lines.append('  </sodipodi:namedview>')
    # Symbols (master store, SYMBOLS.md §5 / Fork S3): masters serialize
    # inside a single <defs> block (each as its normal element SVG, carrying
    # its id), placed before the layer content so the standard SVG
    # non-rendered-definition mechanism applies. Emitted only when the store
    # is non-empty (so existing fixtures stay byte-identical), sorted by id
    # (the §2 deterministic-order rule). Instances ride the existing
    # <use href="#id"> path in the layer tree. On import, <defs> children
    # become doc.symbols (see svg_to_document).
    if doc.symbols:
        sorted_masters = sorted(
            doc.symbols, key=lambda m: getattr(m, "id", None) or "")
        lines.append("  <defs>")
        for master in sorted_masters:
            lines.append(_element_svg(master, "    "))
        lines.append("  </defs>")
    for layer in doc.layers:
        lines.append(_element_svg(layer, "  "))
    lines.append("</svg>")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# SVG Import: parse SVG XML string back to a Document
# ---------------------------------------------------------------------------

_PX_TO_PT = 72.0 / 96.0


def _pt(v: float) -> float:
    """Convert a px value to pt."""
    return v * _PX_TO_PT


def _safe_float(s: str | None, default: float = 0.0) -> float:
    """Parse a string as float, returning default on failure."""
    if s is None:
        return default
    try:
        return float(s)
    except (ValueError, TypeError):
        return default


_NAMED_COLORS: dict[str, tuple[int, int, int]] = {
    "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0),
    "green": (0, 128, 0), "blue": (0, 0, 255), "yellow": (255, 255, 0),
    "cyan": (0, 255, 255), "magenta": (255, 0, 255), "gray": (128, 128, 128),
    "grey": (128, 128, 128), "silver": (192, 192, 192), "maroon": (128, 0, 0),
    "olive": (128, 128, 0), "lime": (0, 255, 0), "aqua": (0, 255, 255),
    "teal": (0, 128, 128), "navy": (0, 0, 128), "fuchsia": (255, 0, 255),
    "purple": (128, 0, 128), "orange": (255, 165, 0), "pink": (255, 192, 203),
    "brown": (165, 42, 42), "coral": (255, 127, 80), "crimson": (220, 20, 60),
    "gold": (255, 215, 0), "indigo": (75, 0, 130), "ivory": (255, 255, 240),
    "khaki": (240, 230, 140), "lavender": (230, 230, 250), "plum": (221, 160, 221),
    "salmon": (250, 128, 114), "sienna": (160, 82, 45), "tan": (210, 180, 140),
    "tomato": (255, 99, 71), "turquoise": (64, 224, 208), "violet": (238, 130, 238),
    "wheat": (245, 222, 179), "steelblue": (70, 130, 180), "skyblue": (135, 206, 235),
    "slategray": (112, 128, 144), "slategrey": (112, 128, 144),
    "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169),
    "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
    "darkblue": (0, 0, 139), "darkgreen": (0, 100, 0), "darkred": (139, 0, 0),
}


def _parse_color(s: str) -> Color | None:
    """Parse color string: rgb()/rgba(), #RRGGBB, #RGB, named colors, or 'none'."""
    s = s.strip()
    if s == "none":
        return None
    # Named SVG colors
    named = _NAMED_COLORS.get(s.lower())
    if named is not None:
        return RgbColor(named[0] / 255.0, named[1] / 255.0, named[2] / 255.0)
    # Hex colors: #RGB, #RGBA, #RRGGBB, #RRGGBBAA
    if s.startswith("#"):
        h = s[1:]
        if len(h) == 3:
            r = int(h[0] + h[0], 16) / 255.0
            g = int(h[1] + h[1], 16) / 255.0
            b = int(h[2] + h[2], 16) / 255.0
            return RgbColor(r, g, b)
        if len(h) == 4:
            r = int(h[0] + h[0], 16) / 255.0
            g = int(h[1] + h[1], 16) / 255.0
            b = int(h[2] + h[2], 16) / 255.0
            a = int(h[3] + h[3], 16) / 255.0
            return RgbColor(r, g, b, a)
        if len(h) == 6:
            r = int(h[0:2], 16) / 255.0
            g = int(h[2:4], 16) / 255.0
            b = int(h[4:6], 16) / 255.0
            return RgbColor(r, g, b)
        if len(h) == 8:
            r = int(h[0:2], 16) / 255.0
            g = int(h[2:4], 16) / 255.0
            b = int(h[4:6], 16) / 255.0
            a = int(h[6:8], 16) / 255.0
            return RgbColor(r, g, b, a)
        return None
    # rgb()/rgba() functional notation
    m = re.match(r"rgba?\(([^)]+)\)", s)
    if m:
        parts = m.group(1).split(",")
        r = int(parts[0].strip()) / 255.0
        g = int(parts[1].strip()) / 255.0
        b = int(parts[2].strip()) / 255.0
        a = float(parts[3].strip()) if len(parts) > 3 else 1.0
        return RgbColor(r, g, b, a)
    import logging
    logging.warning("Unrecognized SVG color value: %s", s)
    return None


def _parse_fill(node: ET.Element) -> Fill | None:
    val = node.get("fill")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    if c is None:
        return None
    opacity = _safe_float(node.get("fill-opacity"), 1.0)
    return Fill(c, opacity)


def _parse_stroke(node: ET.Element) -> Stroke | None:
    val = node.get("stroke")
    if val is None or val == "none":
        return None
    c = _parse_color(val)
    if c is None:
        return None
    width = _safe_float(node.get("stroke-width"), 1.0) * _PX_TO_PT
    lc_str = node.get("stroke-linecap", "butt")
    lj_str = node.get("stroke-linejoin", "miter")
    lc = {"butt": LineCap.BUTT, "round": LineCap.ROUND, "square": LineCap.SQUARE}.get(lc_str, LineCap.BUTT)
    lj = {"miter": LineJoin.MITER, "round": LineJoin.ROUND, "bevel": LineJoin.BEVEL}.get(lj_str, LineJoin.MITER)
    opacity = _safe_float(node.get("stroke-opacity"), 1.0)
    dash_align_raw = (node.get("data-jas-dash-align-anchors") or "").strip()
    dash_align_anchors = dash_align_raw in ("true", "1")
    return Stroke(c, width, lc, lj, opacity,
                  dash_align_anchors=dash_align_anchors)


def _parse_transform(node: ET.Element) -> Transform | None:
    val = node.get("transform")
    if val is None:
        return None
    m = re.match(r"matrix\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        return Transform(a=parts[0], b=parts[1], c=parts[2],
                         d=parts[3], e=_pt(parts[4]), f=_pt(parts[5]))
    m = re.match(r"translate\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        ty = parts[1] if len(parts) > 1 else 0.0
        return Transform.translate(_pt(parts[0]), _pt(ty))
    m = re.match(r"rotate\(([^)]+)\)", val)
    if m:
        return Transform.rotate(float(m.group(1)))
    m = re.match(r"scale\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in m.group(1).split(",")]
        sy = parts[1] if len(parts) > 1 else parts[0]
        return Transform.scale(parts[0], sy)
    return None


def _parse_matrix_attr(node: ET.Element, attr: str) -> Transform | None:
    """Parse a ``matrix(a,b,c,d,e,f)`` value from the named attribute,
    returning None when the attribute is absent or malformed. Used for the
    Symbols P4 instance transform (data-jas-instance-transform); e/f are
    converted from px to pt to match the render CTM attr (SYMBOLS.md §4 /
    Fork F2)."""
    val = node.get(attr)
    if val is None:
        return None
    m = re.match(r"matrix\(([^)]+)\)", val)
    if m:
        parts = [float(x) for x in re.split(r"[,\s]+", m.group(1).strip())]
        if len(parts) == 6:
            return Transform(a=parts[0], b=parts[1], c=parts[2],
                             d=parts[3], e=_pt(parts[4]), f=_pt(parts[5]))
    return None


def _parse_opacity(node: ET.Element) -> float:
    return _safe_float(node.get("opacity"), 1.0)


def _parse_points(s: str) -> tuple[tuple[float, float], ...]:
    """Parse a points attribute like '0,0 96,0 48,96'."""
    result = []
    for pair in s.strip().split():
        parts = pair.split(",")
        result.append((_pt(float(parts[0])), _pt(float(parts[1]))))
    return tuple(result)


# Path d-attribute tokenizer
_PATH_CMD_RE = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")


def _parse_path_d(d: str) -> tuple[PathCommand, ...]:
    """Parse an SVG path d attribute into PathCommands.

    Supports both absolute (uppercase) and relative (lowercase) commands,
    including H/h (horizontal lineto) and V/v (vertical lineto).
    All commands are converted to absolute coordinates.
    """
    tokens = _PATH_CMD_RE.findall(d)
    commands: list[PathCommand] = []
    i = 0
    cur_x = cur_y = 0.0  # current point (in px, before pt conversion)
    start_x = start_y = 0.0  # subpath start (for Z)

    def _next_num() -> float:
        nonlocal i
        while i < len(tokens) and tokens[i][0]:
            i += 1
        if i >= len(tokens):
            raise ValueError("unexpected end of path data")
        v = float(tokens[i][1])
        i += 1
        return v

    def _update(x: float, y: float) -> None:
        nonlocal cur_x, cur_y
        cur_x, cur_y = x, y

    while i < len(tokens):
        cmd_str, num_str = tokens[i]
        if cmd_str:
            cmd = cmd_str
            i += 1
        elif num_str:
            pass  # implicit repeat of previous command
        else:
            i += 1
            continue

        if cmd in ("Z", "z"):
            commands.append(ClosePath())
            cur_x, cur_y = start_x, start_y
        elif cmd == "M":
            x, y = _next_num(), _next_num()
            commands.append(MoveTo(_pt(x), _pt(y)))
            _update(x, y)
            start_x, start_y = x, y
        elif cmd == "m":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(MoveTo(_pt(x), _pt(y)))
            _update(x, y)
            start_x, start_y = x, y
        elif cmd == "L":
            x, y = _next_num(), _next_num()
            commands.append(LineTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "l":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(LineTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "H":
            x = _next_num()
            commands.append(LineTo(_pt(x), _pt(cur_y)))
            cur_x = x
        elif cmd == "h":
            x = cur_x + _next_num()
            commands.append(LineTo(_pt(x), _pt(cur_y)))
            cur_x = x
        elif cmd == "V":
            y = _next_num()
            commands.append(LineTo(_pt(cur_x), _pt(y)))
            cur_y = y
        elif cmd == "v":
            y = cur_y + _next_num()
            commands.append(LineTo(_pt(cur_x), _pt(y)))
            cur_y = y
        elif cmd == "C":
            x1, y1 = _next_num(), _next_num()
            x2, y2 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(CurveTo(_pt(x1), _pt(y1), _pt(x2), _pt(y2),
                                    _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "c":
            x1, y1 = cur_x + _next_num(), cur_y + _next_num()
            x2, y2 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(CurveTo(_pt(x1), _pt(y1), _pt(x2), _pt(y2),
                                    _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "S":
            x2, y2 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(SmoothCurveTo(_pt(x2), _pt(y2), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "s":
            x2, y2 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(SmoothCurveTo(_pt(x2), _pt(y2), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "Q":
            x1, y1 = _next_num(), _next_num()
            x, y = _next_num(), _next_num()
            commands.append(QuadTo(_pt(x1), _pt(y1), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "q":
            x1, y1 = cur_x + _next_num(), cur_y + _next_num()
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(QuadTo(_pt(x1), _pt(y1), _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "T":
            x, y = _next_num(), _next_num()
            commands.append(SmoothQuadTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "t":
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(SmoothQuadTo(_pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "A":
            rx, ry = _next_num(), _next_num()
            rotation = _next_num()
            large_arc = _next_num() != 0
            sweep = _next_num() != 0
            x, y = _next_num(), _next_num()
            commands.append(ArcTo(_pt(rx), _pt(ry), rotation, large_arc, sweep,
                                  _pt(x), _pt(y)))
            _update(x, y)
        elif cmd == "a":
            rx, ry = _next_num(), _next_num()
            rotation = _next_num()
            large_arc = _next_num() != 0
            sweep = _next_num() != 0
            x, y = cur_x + _next_num(), cur_y + _next_num()
            commands.append(ArcTo(_pt(rx), _pt(ry), rotation, large_arc, sweep,
                                  _pt(x), _pt(y)))
            _update(x, y)
        else:
            i += 1  # skip unsupported commands

    return tuple(commands)


_SVG_NS = "http://www.w3.org/2000/svg"
_INKSCAPE_NS = "http://www.inkscape.org/namespaces/inkscape"
_XLINK_NS = "http://www.w3.org/1999/xlink"


def _parse_tspan(node) -> list:
    """Parse an SVG ``<tspan>`` child node into one or more Tspans.

    Returns a list so SVG's multi-value ``rotate="a1 a2 a3 …"`` can
    be expanded into one tspan per glyph (each carrying its own
    rotate angle). The single-value case returns a one-element
    list. Ids are left at 0; the caller assigns fresh sequential
    ids across the whole tspan list.
    """
    from geometry.tspan import Tspan
    content = node.text or ""
    font_family = node.get("font-family")
    fs_str = node.get("font-size")
    font_size = _pt(float(fs_str)) if fs_str else None
    font_weight = node.get("font-weight")
    font_style = node.get("font-style")
    raw_decor = node.get("text-decoration")
    if raw_decor is not None:
        parts = [t for t in raw_decor.split() if t and t != "none"]
        parts.sort()
        decoration: tuple[str, ...] | None = tuple(parts)
    else:
        decoration = None
    rotate_raw = node.get("rotate")
    rotate_vals: list[float] = []
    if rotate_raw is not None:
        for p in rotate_raw.split():
            try:
                rotate_vals.append(float(p))
            except ValueError:
                pass
    jas_role = node.get("urn:jas:1:role")
    def _opt_float(s):
        try: return float(s) if s is not None else None
        except ValueError: return None
    def _opt_bool(s):
        return None if s is None else (s == "true")
    jas_left_indent = _opt_float(node.get("urn:jas:1:left-indent"))
    jas_right_indent = _opt_float(node.get("urn:jas:1:right-indent"))
    jas_hyphenate = _opt_bool(node.get("urn:jas:1:hyphenate"))
    jas_hanging_punctuation = _opt_bool(node.get("urn:jas:1:hanging-punctuation"))
    jas_list_style = node.get("urn:jas:1:list-style")
    text_align = node.get("text-align")
    text_align_last = node.get("text-align-last")
    text_indent = _opt_float(node.get("text-indent"))
    jas_space_before = _opt_float(node.get("urn:jas:1:space-before"))
    jas_space_after = _opt_float(node.get("urn:jas:1:space-after"))
    jas_word_spacing_min = _opt_float(node.get("urn:jas:1:word-spacing-min"))
    jas_word_spacing_desired = _opt_float(node.get("urn:jas:1:word-spacing-desired"))
    jas_word_spacing_max = _opt_float(node.get("urn:jas:1:word-spacing-max"))
    jas_letter_spacing_min = _opt_float(node.get("urn:jas:1:letter-spacing-min"))
    jas_letter_spacing_desired = _opt_float(node.get("urn:jas:1:letter-spacing-desired"))
    jas_letter_spacing_max = _opt_float(node.get("urn:jas:1:letter-spacing-max"))
    jas_glyph_scaling_min = _opt_float(node.get("urn:jas:1:glyph-scaling-min"))
    jas_glyph_scaling_desired = _opt_float(node.get("urn:jas:1:glyph-scaling-desired"))
    jas_glyph_scaling_max = _opt_float(node.get("urn:jas:1:glyph-scaling-max"))
    jas_auto_leading = _opt_float(node.get("urn:jas:1:auto-leading"))
    jas_single_word_justify = node.get("urn:jas:1:single-word-justify")
    jas_hyphenate_min_word = _opt_float(node.get("urn:jas:1:hyphenate-min-word"))
    jas_hyphenate_min_before = _opt_float(node.get("urn:jas:1:hyphenate-min-before"))
    jas_hyphenate_min_after = _opt_float(node.get("urn:jas:1:hyphenate-min-after"))
    jas_hyphenate_limit = _opt_float(node.get("urn:jas:1:hyphenate-limit"))
    jas_hyphenate_zone = _opt_float(node.get("urn:jas:1:hyphenate-zone"))
    jas_hyphenate_bias = _opt_float(node.get("urn:jas:1:hyphenate-bias"))
    jas_hyphenate_capitalized = _opt_bool(node.get("urn:jas:1:hyphenate-capitalized"))
    base_kwargs = dict(
        font_family=font_family, font_size=font_size,
        font_style=font_style, font_weight=font_weight,
        text_decoration=decoration, jas_role=jas_role,
        jas_left_indent=jas_left_indent,
        jas_right_indent=jas_right_indent,
        jas_hyphenate=jas_hyphenate,
        jas_hanging_punctuation=jas_hanging_punctuation,
        jas_list_style=jas_list_style,
        text_align=text_align,
        text_align_last=text_align_last,
        text_indent=text_indent,
        jas_space_before=jas_space_before,
        jas_space_after=jas_space_after,
        jas_word_spacing_min=jas_word_spacing_min,
        jas_word_spacing_desired=jas_word_spacing_desired,
        jas_word_spacing_max=jas_word_spacing_max,
        jas_letter_spacing_min=jas_letter_spacing_min,
        jas_letter_spacing_desired=jas_letter_spacing_desired,
        jas_letter_spacing_max=jas_letter_spacing_max,
        jas_glyph_scaling_min=jas_glyph_scaling_min,
        jas_glyph_scaling_desired=jas_glyph_scaling_desired,
        jas_glyph_scaling_max=jas_glyph_scaling_max,
        jas_auto_leading=jas_auto_leading,
        jas_single_word_justify=jas_single_word_justify,
        jas_hyphenate_min_word=jas_hyphenate_min_word,
        jas_hyphenate_min_before=jas_hyphenate_min_before,
        jas_hyphenate_min_after=jas_hyphenate_min_after,
        jas_hyphenate_limit=jas_hyphenate_limit,
        jas_hyphenate_zone=jas_hyphenate_zone,
        jas_hyphenate_bias=jas_hyphenate_bias,
        jas_hyphenate_capitalized=jas_hyphenate_capitalized,
    )
    if not rotate_vals:
        return [Tspan(id=0, content=content, **base_kwargs)]
    if len(rotate_vals) == 1 or len(content) <= 1:
        return [Tspan(id=0, content=content, rotate=rotate_vals[0],
                       **base_kwargs)]
    # Multi-value rotate: split the tspan into one per glyph. Each
    # inherits the other override fields and gets the matching
    # rotate angle; the last angle is reused for any trailing glyphs
    # past the end of the list (per SVG spec).
    last_angle = rotate_vals[-1]
    out = []
    for i, ch in enumerate(content):
        angle = rotate_vals[i] if i < len(rotate_vals) else last_angle
        out.append(Tspan(id=0, content=ch, rotate=angle, **base_kwargs))
    return out


def _collect_tspan_children(node):
    """Collect ``<tspan>`` children from an ElementTree node, in
    document order. Returns an empty tuple when none are present —
    the caller falls back to flat-content parsing.

    When a child's ``rotate`` attribute is multi-valued and the
    child has multiple characters, the tspan is split on parse into
    one per glyph — see :func:`_parse_tspan`. Ids are renumbered
    sequentially across the full flattened list.
    """
    from dataclasses import replace
    flat = []
    for child in node:
        if _strip_ns(child.tag) == "tspan":
            flat.extend(_parse_tspan(child))
    return tuple(replace(t, id=i) for i, t in enumerate(flat))


def _strip_ns(tag: str) -> str:
    """Strip namespace from an XML tag."""
    if tag.startswith("{"):
        return tag.split("}", 1)[1]
    return tag


def _parse_element(node: ET.Element) -> Element | None:
    """Parse an SVG XML element into a document Element."""
    tag = _strip_ns(node.tag)
    fill = _parse_fill(node)
    stroke = _parse_stroke(node)
    opacity = _parse_opacity(node)
    transform = _parse_transform(node)
    # User-visible name from inkscape:label (preferred) or <title> child.
    name = (node.get(f"{{{_INKSCAPE_NS}}}label")
            or node.get("inkscape:label"))
    if not name:
        for child in node:
            if _strip_ns(child.tag) == "title" and child.text:
                name = child.text
                break
    # Stable element identity from the standard SVG `id` attribute
    # (absent -> None). Reading a foreign id is fine. Mirrors `name`.
    eid = node.get("id") or None

    if tag == "line":
        return Line(
            x1=_pt(_safe_float(node.get("x1"))),
            y1=_pt(_safe_float(node.get("y1"))),
            x2=_pt(_safe_float(node.get("x2"))),
            y2=_pt(_safe_float(node.get("y2"))),
            stroke=stroke, opacity=opacity, transform=transform,
            name=name, id=eid)

    if tag == "rect":
        return Rect(
            x=_pt(_safe_float(node.get("x"))),
            y=_pt(_safe_float(node.get("y"))),
            width=_pt(_safe_float(node.get("width"))),
            height=_pt(_safe_float(node.get("height"))),
            rx=_pt(_safe_float(node.get("rx"))),
            ry=_pt(_safe_float(node.get("ry"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform,
            name=name, id=eid)

    if tag == "circle":
        return Circle(
            cx=_pt(_safe_float(node.get("cx"))),
            cy=_pt(_safe_float(node.get("cy"))),
            r=_pt(_safe_float(node.get("r"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform,
            name=name, id=eid)

    if tag == "ellipse":
        return Ellipse(
            cx=_pt(_safe_float(node.get("cx"))),
            cy=_pt(_safe_float(node.get("cy"))),
            rx=_pt(_safe_float(node.get("rx"))),
            ry=_pt(_safe_float(node.get("ry"))),
            fill=fill, stroke=stroke, opacity=opacity, transform=transform,
            name=name, id=eid)

    if tag == "polyline":
        pts = _parse_points(node.get("points", ""))
        return Polyline(points=pts, fill=fill, stroke=stroke,
                        opacity=opacity, transform=transform,
                        name=name, id=eid)

    if tag == "polygon":
        pts = _parse_points(node.get("points", ""))
        return Polygon(points=pts, fill=fill, stroke=stroke,
                       opacity=opacity, transform=transform,
                       name=name, id=eid)

    if tag == "path":
        d = _parse_path_d(node.get("d", ""))
        tool_origin = node.get("jas:tool-origin")
        return Path(d=d, fill=fill, stroke=stroke,
                    opacity=opacity, transform=transform,
                    tool_origin=tool_origin,
                    name=name, id=eid)

    if tag == "text":
        ff = node.get("font-family", "sans-serif")
        fs = _pt(_safe_float(node.get("font-size"), 16.0))
        fw = node.get("font-weight", "normal")
        fst = node.get("font-style", "normal")
        td = node.get("text-decoration", "none")
        tt = node.get("text-transform", "")
        fv = node.get("font-variant", "")
        bs = node.get("baseline-shift", "")
        lh = node.get("line-height", "")
        ls = node.get("letter-spacing", "")
        lang = (node.get("{http://www.w3.org/XML/1998/namespace}lang")
                or node.get("xml:lang")
                or node.get("lang")
                or "")
        aa = node.get("urn:jas:1:aa-mode", "")
        rotate = node.get("rotate", "")
        hs = node.get("horizontal-scale", "")
        vs = node.get("vertical-scale", "")
        kern = node.get("urn:jas:1:kerning-mode", "")
        # Check for <textPath> child
        for child in node:
            ctag = _strip_ns(child.tag)
            if ctag == "textPath":
                d_str = child.get("path") or child.get("d") or ""
                d = _parse_path_d(d_str)
                # Prefer <tspan> children inside the <textPath>; fall
                # back to flat string content when none are present.
                tp_tspans = _collect_tspan_children(child)
                tp_content = (
                    "".join(t.content for t in tp_tspans)
                    if tp_tspans else (child.text or "")
                )
                offset_str = child.get("startOffset", "0")
                start_offset = 0.0
                if offset_str.endswith("%"):
                    start_offset = _safe_float(offset_str[:-1]) / 100.0
                else:
                    start_offset = _safe_float(offset_str)
                tp = TextPath(
                    d=d, content=tp_content, start_offset=start_offset,
                    font_family=ff, font_size=fs,
                    font_weight=fw, font_style=fst, text_decoration=td,
                    text_transform=tt, font_variant=fv, baseline_shift=bs,
                    line_height=lh, letter_spacing=ls, xml_lang=lang,
                    aa_mode=aa, rotate=rotate, horizontal_scale=hs,
                    vertical_scale=vs, kerning=kern,
                    fill=fill, stroke=stroke, opacity=opacity, transform=transform,
                    id=eid)
                if tp_tspans:
                    # Override the seeded-from-content tspans with the
                    # parsed children so per-range overrides survive.
                    tp = dataclasses.replace(tp, tspans=tp_tspans)
                return tp
        tspan_children = _collect_tspan_children(node)
        if tspan_children:
            content = "".join(t.content for t in tspan_children)
        else:
            content = node.text or ""
        tw = 0.0
        style = node.get("style", "")
        if style:
            import re
            m = re.search(r'inline-size:\s*([\d.]+)px', style)
            if m:
                tw = _pt(float(m.group(1)))
        # Estimate height from inline-size and content length
        th = 0.0
        if tw > 0:
            lines = max(1, int(len(content) * fs * APPROX_CHAR_WIDTH_FACTOR / tw) + 1)
            th = lines * fs * 1.2
        # SVG `y` is the baseline of the first line; convert it to the
        # layout-box top by subtracting the ascent (0.8 * fs).
        svg_y = _pt(_safe_float(node.get("y")))
        t = Text(
            x=_pt(_safe_float(node.get("x"))),
            y=svg_y - fs * 0.8,
            content=content, font_family=ff, font_size=fs,
            font_weight=fw, font_style=fst, text_decoration=td,
            text_transform=tt, font_variant=fv, baseline_shift=bs,
            line_height=lh, letter_spacing=ls, xml_lang=lang,
            aa_mode=aa, rotate=rotate, horizontal_scale=hs,
            vertical_scale=vs, kerning=kern,
            width=tw, height=th,
            fill=fill, stroke=stroke, opacity=opacity, transform=transform,
            id=eid)
        if tspan_children:
            t = dataclasses.replace(t, tspans=tspan_children)
        return t

    if tag == "g":
        children = []
        for child in node:
            if _strip_ns(child.tag) == "title":
                continue  # title used for name; skip as element
            elem = _parse_element(child)
            if elem is not None:
                children.append(elem)
        # A live compound shape is <g data-jas-live="compound_shape">
        # (REFERENCE_GRAPH.md Phase 2): rebuild it instead of demoting
        # to a plain Group. Operation comes from data-jas-operation
        # (default union). Mirrors the Rust ``parse_element`` g-arm.
        if node.get("data-jas-live") == "compound_shape":
            op_str = node.get("data-jas-operation") or "union"
            operation = {
                "union": CompoundOperation.UNION,
                "subtract_front": CompoundOperation.SUBTRACT_FRONT,
                "intersection": CompoundOperation.INTERSECTION,
                "exclude": CompoundOperation.EXCLUDE,
            }.get(op_str, CompoundOperation.UNION)
            return CompoundShape(
                operation=operation, operands=tuple(children),
                fill=None, stroke=None,
                opacity=opacity, transform=transform, id=eid)
        # Layer detection: only inkscape:groupmode="layer" promotes a
        # <g> to a Layer. inkscape:label alone is a Group name now
        # (was historically Layer-only, but with non-Layer naming
        # support that heuristic is wrong). Existing fixtures opt in
        # via the explicit groupmode attribute.
        group_mode = (node.get(f"{{{_INKSCAPE_NS}}}groupmode")
                      or node.get("inkscape:groupmode"))
        label = node.get(f"{{{_INKSCAPE_NS}}}label") or node.get("inkscape:label")
        if group_mode == "layer":
            return Layer(children=tuple(children), name=label or "",
                         opacity=opacity, transform=transform, id=eid)
        return Group(children=tuple(children),
                     opacity=opacity, transform=transform,
                     name=name, id=eid)

    if tag == "use":
        # Native SVG <use href="#id"> imports as a live reference
        # (F-svg-use: any <use> becomes a reference). The reference's
        # own id/opacity/transform came from the common attrs above;
        # href (xlink:href fallback) names the target, '#' stripped.
        href = (node.get("href")
                or node.get(f"{{{_XLINK_NS}}}href")
                or node.get("xlink:href")
                or "")
        target = href[1:] if href.startswith("#") else href
        # Symbols P4: the instance transform field rides
        # data-jas-instance-transform (same matrix format as the render CTM
        # attr; e/f are px on the wire, pt in the model). SYMBOLS.md §4 / F2.
        return ReferenceElem(
            target=target, id=eid, name=name,
            opacity=opacity, transform=transform,
            instance_transform=_parse_matrix_attr(
                node, "data-jas-instance-transform"))

    if tag == "title":
        return None  # parent reads as the name

    return None


def _attr_get(node: ET.Element, name: str) -> str | None:
    """Try the bare attribute name first; fall back to a `jas:`-prefixed
    or {jas-namespace}-qualified variant for files written by
    namespace-aware writers."""
    v = node.get(name)
    if v is not None:
        return v
    v = node.get("jas:" + name)
    if v is not None:
        return v
    return node.get(f"{{{_JAS_NS}}}{name}")


def _parse_bool_attr(node: ET.Element, name: str, default: bool) -> bool:
    v = _attr_get(node, name)
    if v is None:
        return default
    if v in ("true", "1", "yes"):
        return True
    if v in ("false", "0", "no"):
        return False
    return default


def _parse_float_attr(node: ET.Element, name: str, default: float) -> float:
    v = _attr_get(node, name)
    if v is None:
        return default
    try:
        return float(v)
    except (ValueError, TypeError):
        return default


def _parse_int_attr(node: ET.Element, name: str, default: int) -> int:
    v = _attr_get(node, name)
    if v is None:
        return default
    try:
        return int(v)
    except (ValueError, TypeError):
        return default


def _parse_document_setup_node(node: ET.Element):
    from document.document_setup import DocumentSetup
    from document.print_preferences import FlattenerPreset, _enum_from_string
    d = DocumentSetup()
    return DocumentSetup(
        bleed_top=_parse_float_attr(node, "bleed-top", d.bleed_top),
        bleed_right=_parse_float_attr(node, "bleed-right", d.bleed_right),
        bleed_bottom=_parse_float_attr(node, "bleed-bottom", d.bleed_bottom),
        bleed_left=_parse_float_attr(node, "bleed-left", d.bleed_left),
        bleed_uniform=_parse_bool_attr(node, "bleed-uniform", d.bleed_uniform),
        show_images_outline=_parse_bool_attr(
            node, "show-images-outline", d.show_images_outline),
        highlight_substituted_glyphs=_parse_bool_attr(
            node, "highlight-substituted-glyphs", d.highlight_substituted_glyphs),
        grid_size=_parse_float_attr(node, "grid-size", d.grid_size),
        grid_color=_attr_get(node, "grid-color") or d.grid_color,
        paper_color=_attr_get(node, "paper-color") or d.paper_color,
        simulate_colored_paper=_parse_bool_attr(
            node, "simulate-colored-paper", d.simulate_colored_paper),
        transparency_flattener_preset=_enum_from_string(
            FlattenerPreset, _attr_get(node, "transparency-flattener-preset") or "",
            d.transparency_flattener_preset),
        discard_white_overprint=_parse_bool_attr(
            node, "discard-white-overprint", d.discard_white_overprint),
    )


def _parse_advanced_node(node: ET.Element):
    from document.print_preferences import (
        Advanced, FlattenerPreset, _enum_from_string,
    )
    d = Advanced()
    return Advanced(
        print_as_bitmap=_parse_bool_attr(
            node, "print-as-bitmap", d.print_as_bitmap),
        overprint_flattener_preset=_enum_from_string(
            FlattenerPreset, _attr_get(node, "overprint-flattener-preset") or "",
            d.overprint_flattener_preset),
    )


def _parse_color_management_node(node: ET.Element):
    from document.print_preferences import (
        ColorManagement, ColorHandling, RenderingIntent, _enum_from_string,
    )
    d = ColorManagement()
    return ColorManagement(
        document_profile=_attr_get(node, "document-profile") or d.document_profile,
        color_handling=_enum_from_string(
            ColorHandling, _attr_get(node, "color-handling") or "", d.color_handling),
        printer_profile=_attr_get(node, "printer-profile") or d.printer_profile,
        rendering_intent=_enum_from_string(
            RenderingIntent, _attr_get(node, "rendering-intent") or "", d.rendering_intent),
        preserve_rgb_numbers=_parse_bool_attr(
            node, "preserve-rgb-numbers", d.preserve_rgb_numbers),
    )


def _parse_graphics_node(node: ET.Element):
    from document.print_preferences import (
        Graphics, FontDownload, PostScriptLevel, DataFormat,
        _enum_from_string,
    )
    d = Graphics()
    return Graphics(
        flatness=_parse_float_attr(node, "flatness", d.flatness),
        font_download=_enum_from_string(
            FontDownload, _attr_get(node, "font-download") or "", d.font_download),
        postscript_level=_enum_from_string(
            PostScriptLevel, _attr_get(node, "postscript-level") or "", d.postscript_level),
        data_format=_enum_from_string(
            DataFormat, _attr_get(node, "data-format") or "", d.data_format),
        compatible_gradient_printing=_parse_bool_attr(
            node, "compatible-gradient-printing", d.compatible_gradient_printing),
        raster_effects_resolution=_parse_float_attr(
            node, "raster-effects-resolution", d.raster_effects_resolution),
    )


def _parse_ink_override_node(node: ET.Element):
    from document.print_preferences import (
        InkOverride, DotShape, _enum_from_string,
    )
    return InkOverride(
        name=_attr_get(node, "name") or "",
        print=_parse_bool_attr(node, "print", True),
        frequency=_parse_float_attr(node, "frequency", 75.0),
        angle=_parse_float_attr(node, "angle", 45.0),
        dot_shape=_enum_from_string(
            DotShape, _attr_get(node, "dot-shape") or "", DotShape.ROUND),
    )


def _parse_output_node(node: ET.Element):
    from document.print_preferences import (
        Output, OutputMode, Emulsion, ImagePolarity, _enum_from_string,
    )
    d = Output()
    inks: list = []
    for child in node:
        if _strip_ns(child.tag) == "ink":
            inks.append(_parse_ink_override_node(child))
    inks_tuple = tuple(inks) if inks else d.inks
    return Output(
        mode=_enum_from_string(
            OutputMode, _attr_get(node, "mode") or "", d.mode),
        emulsion=_enum_from_string(
            Emulsion, _attr_get(node, "emulsion") or "", d.emulsion),
        image_polarity=_enum_from_string(
            ImagePolarity, _attr_get(node, "image-polarity") or "", d.image_polarity),
        printer_resolution=_attr_get(node, "printer-resolution") or d.printer_resolution,
        convert_spot_to_process=_parse_bool_attr(
            node, "convert-spot-to-process", d.convert_spot_to_process),
        overprint_black=_parse_bool_attr(node, "overprint-black", d.overprint_black),
        inks=inks_tuple,
    )


def _parse_marks_and_bleed_node(node: ET.Element):
    from document.print_preferences import (
        MarksAndBleed, PrinterMarkType, _enum_from_string,
    )
    d = MarksAndBleed()
    return MarksAndBleed(
        all_printer_marks=_parse_bool_attr(
            node, "all-printer-marks", d.all_printer_marks),
        trim_marks=_parse_bool_attr(node, "trim-marks", d.trim_marks),
        registration_marks=_parse_bool_attr(
            node, "registration-marks", d.registration_marks),
        color_bars=_parse_bool_attr(node, "color-bars", d.color_bars),
        page_information=_parse_bool_attr(
            node, "page-information", d.page_information),
        printer_mark_type=_enum_from_string(
            PrinterMarkType,
            _attr_get(node, "printer-mark-type") or "",
            d.printer_mark_type),
        trim_mark_weight=_parse_float_attr(
            node, "trim-mark-weight", d.trim_mark_weight),
        mark_offset=_parse_float_attr(node, "mark-offset", d.mark_offset),
        use_document_bleed=_parse_bool_attr(
            node, "use-document-bleed", d.use_document_bleed),
        bleed_top=_parse_float_attr(node, "bleed-top", d.bleed_top),
        bleed_right=_parse_float_attr(node, "bleed-right", d.bleed_right),
        bleed_bottom=_parse_float_attr(node, "bleed-bottom", d.bleed_bottom),
        bleed_left=_parse_float_attr(node, "bleed-left", d.bleed_left),
    )


def _parse_print_preferences_node(node: ET.Element):
    from document.print_preferences import (
        PrintPreferences, MarksAndBleed, Output, Graphics, ColorManagement, Advanced,
        ArtboardRangeMode, MediaSize, Orientation, PrintLayers, ScalingMode,
        _enum_from_string,
    )
    d = PrintPreferences()
    mab = MarksAndBleed()
    output = Output()
    graphics = Graphics()
    color_management = ColorManagement()
    advanced = Advanced()
    for child in node:
        tag = _strip_ns(child.tag)
        if tag == "marks-and-bleed":
            mab = _parse_marks_and_bleed_node(child)
        elif tag == "output":
            output = _parse_output_node(child)
        elif tag == "graphics":
            graphics = _parse_graphics_node(child)
        elif tag == "color-management":
            color_management = _parse_color_management_node(child)
        elif tag == "advanced":
            advanced = _parse_advanced_node(child)
    return PrintPreferences(
        preset_name=_attr_get(node, "preset-name") or d.preset_name,
        printer_name=_attr_get(node, "printer-name"),
        copies=_parse_int_attr(node, "copies", d.copies),
        collate=_parse_bool_attr(node, "collate", d.collate),
        reverse_order=_parse_bool_attr(node, "reverse-order", d.reverse_order),
        artboard_range_mode=_enum_from_string(
            ArtboardRangeMode,
            _attr_get(node, "artboard-range-mode") or "", d.artboard_range_mode),
        artboard_range=_attr_get(node, "artboard-range") or d.artboard_range,
        ignore_artboards=_parse_bool_attr(
            node, "ignore-artboards", d.ignore_artboards),
        skip_blank_artboards=_parse_bool_attr(
            node, "skip-blank-artboards", d.skip_blank_artboards),
        media_size=_enum_from_string(
            MediaSize, _attr_get(node, "media-size") or "", d.media_size),
        media_width=_parse_float_attr(node, "media-width", d.media_width),
        media_height=_parse_float_attr(node, "media-height", d.media_height),
        orientation=_enum_from_string(
            Orientation, _attr_get(node, "orientation") or "", d.orientation),
        auto_rotate=_parse_bool_attr(node, "auto-rotate", d.auto_rotate),
        transverse=_parse_bool_attr(node, "transverse", d.transverse),
        print_layers=_enum_from_string(
            PrintLayers, _attr_get(node, "print-layers") or "", d.print_layers),
        placement_x=_parse_float_attr(node, "placement-x", d.placement_x),
        placement_y=_parse_float_attr(node, "placement-y", d.placement_y),
        scaling_mode=_enum_from_string(
            ScalingMode, _attr_get(node, "scaling-mode") or "", d.scaling_mode),
        custom_scale=_parse_float_attr(node, "custom-scale", d.custom_scale),
        tile_overlap_h=_parse_float_attr(node, "tile-overlap-h", d.tile_overlap_h),
        tile_overlap_v=_parse_float_attr(node, "tile-overlap-v", d.tile_overlap_v),
        tile_range=_attr_get(node, "tile-range") or d.tile_range,
        marks_and_bleed=mab,
        output=output,
        graphics=graphics,
        color_management=color_management,
        advanced=advanced,
    )


def _parse_jas_print_blocks(root: ET.Element):
    """Walk the root for <sodipodi:namedview> children and pull
    <jas:document-setup> / <jas:print-preferences> attributes out.
    Returns (DocumentSetup, PrintPreferences) — defaults when neither
    block is present."""
    from document.document_setup import DocumentSetup
    from document.print_preferences import PrintPreferences
    setup = DocumentSetup()
    prefs = PrintPreferences()
    for child in root:
        if _strip_ns(child.tag) != "namedview":
            continue
        for sub in child:
            t = _strip_ns(sub.tag)
            if t == "document-setup":
                setup = _parse_document_setup_node(sub)
            elif t == "print-preferences":
                prefs = _parse_print_preferences_node(sub)
    return setup, prefs


def _parse_artboards(root: ET.Element):
    """Parse ``<inkscape:page>`` children of any top-level
    ``<sodipodi:namedview>`` into Artboards. Per the writer side,
    x/y/width/height are stored in px and converted back to internal pt units
    here. ``inkscape:label`` carries the user-visible name, falling back to the
    id when absent. Phase-1 jas-specific fields are not round-tripped through
    SVG (defaulted). Returns ``()`` when no namedview / pages are present.
    Mirrors the Rust ``parse_artboards`` (the cross-language SVG read contract).
    """
    from document.artboard import Artboard
    out = []
    for child in root:
        if _strip_ns(child.tag) != "namedview":
            continue
        for page in child:
            if _strip_ns(page.tag) != "page":
                continue
            label = (page.get(f"{{{_INKSCAPE_NS}}}label")
                     or page.get("inkscape:label") or "")
            page_id = page.get("id") or ""
            name = page_id if not label else label
            out.append(Artboard(
                id=page_id,
                name=name,
                x=_pt(_parse_float_attr(page, "x", 0.0)),
                y=_pt(_parse_float_attr(page, "y", 0.0)),
                width=_pt(_parse_float_attr(page, "width", 0.0)),
                height=_pt(_parse_float_attr(page, "height", 0.0)),
                fill="transparent",
                show_center_mark=False,
                show_cross_hairs=False,
                show_video_safe_areas=False,
                video_ruler_pixel_aspect_ratio=1.0,
            ))
    return tuple(out)


def svg_to_document(svg: str) -> Document:
    """Parse an SVG string and return a Document.

    Returns an empty document if the SVG is malformed, logging a warning.
    """
    import logging
    try:
        root = ET.fromstring(svg)
    except ET.ParseError as e:
        logging.warning("Failed to parse SVG: %s", e)
        return Document(layers=(Layer(children=()),))
    parsed_setup, parsed_prefs = _parse_jas_print_blocks(root)
    parsed_artboards = _parse_artboards(root)
    layers: list[Layer] = []
    # Symbols (master store, SYMBOLS.md §5 / Fork S3): <defs> children parse
    # into doc.symbols (NOT into layers), so masters are never painted in
    # document order. Each <defs> child is its normal element (carrying its
    # id); instances ride the existing <use href="#id"> path in the layers.
    symbols: list[Element] = []
    for child in root:
        # Skip namedview — its children are pulled out above.
        if _strip_ns(child.tag) == "namedview":
            continue
        # A <defs> block holds the master store: its element children become
        # doc.symbols, never layers.
        if _strip_ns(child.tag) == "defs":
            for def_child in child:
                master = _parse_element(def_child)
                if master is not None:
                    symbols.append(master)
            continue
        elem = _parse_element(child)
        if elem is None:
            continue
        if isinstance(elem, Layer):
            layers.append(elem)
        elif isinstance(elem, Group):
            # Promote top-level groups to layers (id carried over so a
            # pinned group identity survives the structural promotion).
            layers.append(Layer(children=elem.children, name="",
                                opacity=elem.opacity, transform=elem.transform,
                                id=elem.id))
        else:
            # Wrap standalone elements in a default layer
            if not layers or layers[-1].name:
                layers.append(Layer(children=(elem,), name=""))
            else:
                layers[-1] = Layer(
                    children=layers[-1].children + (elem,),
                    name="", opacity=layers[-1].opacity,
                    transform=layers[-1].transform)
    if not layers:
        layers = [Layer(children=())]
    return dedupe_element_ids(normalize_document(Document(
        layers=tuple(layers),
        symbols=tuple(symbols),
        artboards=parsed_artboards,
        document_setup=parsed_setup,
        print_preferences=parsed_prefs)))
