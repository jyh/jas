"""SVG opacity normalizer.

Extracts color alpha into fill/stroke opacity (multiplicative),
then sets color alpha to 1.0.  This ensures that element
transparency is expressed through opacity attributes rather than
color alpha channels.
"""

from dataclasses import replace

from document.document import Document
from geometry.element import Fill, Stroke


def normalize_document(doc: Document) -> Document:
    """Normalize all elements: extract color alpha into fill/stroke opacity,
    set color alpha to 1.0."""
    return replace(doc, layers=tuple(_normalize_element(l) for l in doc.layers))


def _normalize_fill(fill: Fill) -> Fill:
    alpha = fill.color.alpha
    return Fill(color=fill.color.with_alpha(1.0), opacity=fill.opacity * alpha)


def _normalize_stroke(stroke: Stroke) -> Stroke:
    # Preserve every Stroke field — only the color alpha is folded
    # into opacity. Earlier versions of this function dropped
    # dash_pattern, miter_limit, align, arrows, and dash_align_anchors,
    # silently losing them on every SVG round-trip.
    alpha = stroke.color.alpha
    return Stroke(color=stroke.color.with_alpha(1.0), width=stroke.width,
                  linecap=stroke.linecap, linejoin=stroke.linejoin,
                  opacity=stroke.opacity * alpha,
                  miter_limit=stroke.miter_limit,
                  align=stroke.align,
                  dash_pattern=stroke.dash_pattern,
                  dash_align_anchors=stroke.dash_align_anchors,
                  start_arrow=stroke.start_arrow,
                  end_arrow=stroke.end_arrow,
                  start_arrow_scale=stroke.start_arrow_scale,
                  end_arrow_scale=stroke.end_arrow_scale,
                  arrow_align=stroke.arrow_align)


def _normalize_element(elem):
    kwargs = {}
    if hasattr(elem, 'fill') and elem.fill is not None:
        kwargs['fill'] = _normalize_fill(elem.fill)
    if hasattr(elem, 'stroke') and elem.stroke is not None:
        kwargs['stroke'] = _normalize_stroke(elem.stroke)
    if hasattr(elem, 'children'):
        kwargs['children'] = tuple(_normalize_element(c) for c in elem.children)
    return replace(elem, **kwargs) if kwargs else elem
