"""SVG opacity normalizer.

Extracts color alpha into fill/stroke opacity (multiplicative),
then sets color alpha to 1.0.  This ensures that element
transparency is expressed through opacity attributes rather than
color alpha channels.
"""

from dataclasses import replace

from document.document import Document
from geometry.element import Element, Fill, Group, Stroke


def normalize_document(doc: Document) -> Document:
    """Normalize all elements: extract color alpha into fill/stroke opacity,
    set color alpha to 1.0."""
    return replace(
        doc,
        layers=tuple(_normalize_element(l) for l in doc.layers),
        # Masters get the same opacity normalization as layer content.
        symbols=tuple(_normalize_element(m) for m in doc.symbols))


def dedupe_element_ids(doc: Document) -> Document:
    """Enforce the unique-id invariant after import (REFERENCE_GRAPH.md §2.5):
    walk the document in canonical pre-order; the FIRST element to use a given
    id keeps it, and every later element carrying the same id has its id cleared
    to None (first-pre-order-wins). Element ids are then unique within the
    document, so the live-reference index never collides. A no-op on a document
    whose ids are already unique (the normal case) -- well-formed documents
    round-trip unchanged; only ill-formed (e.g. foreign-SVG) duplicates are
    normalized. Called by every document reader.

    Elements are frozen dataclasses, so this rebuilds via dataclasses.replace,
    recursing into Group/Layer children only (mirroring the Rust reference).
    """
    seen: set[str] = set()
    layers = tuple(_dedupe_walk(l, seen) for l in doc.layers)
    # The id space spans layers + symbols (SYMBOLS.md §6): the master store is
    # part of the same pre-order walk so a master id can never collide with a
    # layer-element id. Layers walk first (first-pre-order-wins), then symbols.
    symbols = tuple(_dedupe_walk(m, seen) for m in doc.symbols)
    return replace(doc, layers=layers, symbols=symbols)


def _dedupe_walk(elem: Element, seen: set[str]) -> Element:
    kwargs = {}
    elem_id = getattr(elem, "id", None)
    if elem_id is not None:
        # set.add never reports membership, so check-then-add: a hit marks
        # this as a later duplicate, so clear its id.
        if elem_id in seen:
            kwargs["id"] = None
        else:
            seen.add(elem_id)
    if isinstance(elem, Group):  # also matches Layer (a Group subclass)
        kwargs["children"] = tuple(_dedupe_walk(c, seen) for c in elem.children)
    return replace(elem, **kwargs) if kwargs else elem


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
