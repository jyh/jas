"""The hit test hits painted geometry, not a bounding box.

The law is `transcripts/SELECTION_TOOL.md` § Hit test: painted geometry.
Each case below names the clause it pins. Distances are chosen well
inside or well outside `HIT_TOLERANCE` (3) so a case does not rest on
a boundary the three ports might round differently.
"""

from __future__ import annotations

import os
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import json
import pathlib

from document.document import Document
from geometry.test_json import document_to_test_json
from geometry.element import (
    ClosePath, Ellipse, Color, CompoundShape, CompoundOperation, Fill,
    FillRule, Group, Layer, Line, LineTo, MoveTo, Path, Polyline, Rect,
    Stroke, StrokeAlign, Text, Transform, Visibility,
)

from workspace_interpreter import doc_primitives, hit_law

RED = Fill(color=Color.BLACK)
INK = Stroke(color=Color.BLACK, width=2.0)


def _doc(children, layer_vis):
    return Document(layers=(Layer(name="L", children=tuple(children),
                                  visibility=layer_vis),))


def _hit(children, x, y, *, layer_vis=Visibility.PREVIEW, deep=False):
    with doc_primitives.with_doc(_doc(children, layer_vis)):
        r = (doc_primitives.hit_test_deep if deep else doc_primitives.hit_test)(x, y)
    return None if r is None else tuple(r)


# Every _check is also a row of the SHARED corpus the Rust and Swift ports
# replay (test_fixtures/algorithms/painted_hit.json). The expectation is
# written here, by hand, from the law; the reference must agree with it,
# and the corpus file must equal what these rows produce.
_RECORDING: list | None = None


def _check(children, x, y, *, expect, layer_vis=Visibility.PREVIEW, deep=False):
    got = _hit(children, x, y, layer_vis=layer_vis, deep=deep)
    assert got == expect, f"hit at ({x}, {y}) deep={deep}: got {got}, law says {expect}"
    if _RECORDING is not None:
        _RECORDING.append({
            "document": json.loads(document_to_test_json(_doc(children, layer_vis))),
            "x": float(x), "y": float(y), "deep": deep,
            "expect": None if expect is None else list(expect),
        })


def test_tolerance_is_three():
    assert hit_law.HIT_TOLERANCE == 3.0


# ── Fill ─────────────────────────────────────────────────


def test_filled_rect_is_hit_in_its_middle():
    _check([Rect(x=0, y=0, width=40, height=40, fill=RED)], 20, 20, expect=(0, 0))


def test_unfilled_rect_is_not_hit_in_its_middle():
    # The owner's own example.
    _check([Rect(x=0, y=0, width=40, height=40, stroke=INK)], 20, 20, expect=None)


def test_unpainted_rect_is_never_hit():
    r = Rect(x=0, y=0, width=40, height=40)
    _check([r], 20, 20, expect=None)
    _check([r], 0, 20, expect=None)


def test_filled_circle_misses_the_corner_of_its_box():
    # An Ellipse with rx == ry: the active ports read <circle> as one, and
    # the shared corpus's documents must parse in every port.
    c = Ellipse(cx=20, cy=20, rx=20, ry=20, fill=RED)
    _check([c], 20, 20, expect=(0, 0))
    _check([c], 2, 2, expect=None)


def test_open_polyline_fills_as_if_closed():
    p = Polyline(points=((0, 0), (40, 0), (40, 40)), fill=RED)
    _check([p], 30, 10, expect=(0, 0))   # inside the closed triangle
    _check([p], 10, 30, expect=None)     # the other half of the box


def test_even_odd_path_leaves_a_hole():
    square = lambda x0, s: (MoveTo(x0, x0), LineTo(x0 + s, x0),
                            LineTo(x0 + s, x0 + s), LineTo(x0, x0 + s), ClosePath())
    d = square(0, 60) + square(20, 20)
    eo = Path(d=d, fill=RED, fill_rule=FillRule.EVENODD)
    nz = Path(d=d, fill=RED, fill_rule=FillRule.NONZERO)
    _check([eo], 30, 30, expect=None)
    _check([eo], 10, 10, expect=(0, 0))
    _check([nz], 30, 30, expect=(0, 0))


# ── Stroke ───────────────────────────────────────────────


def test_unfilled_rect_is_hit_on_and_near_its_stroke():
    r = Rect(x=0, y=0, width=40, height=40, stroke=INK)
    _check([r], 0, 20, expect=(0, 0))
    # width/2 + tolerance = 4: 3.5 in is a hit, 6 in is not.
    _check([r], 3.5, 20, expect=(0, 0))
    _check([r], -3.5, 20, expect=(0, 0))
    _check([r], 6, 20, expect=None)


def test_an_inside_stroke_paints_a_full_width_band():
    wide = Stroke(color=Color.BLACK, width=8.0, align=StrokeAlign.INSIDE)
    r = Rect(x=0, y=0, width=40, height=40, stroke=wide)
    # width + tolerance = 11; centred it would be 7.
    _check([r], 9, 20, expect=(0, 0))
    _check([r], 14, 20, expect=None)


def test_a_line_is_hit_only_near_itself():
    ln = Line(x1=0, y1=40, x2=40, y2=0, stroke=INK)
    _check([ln], 20, 20, expect=(0, 0))
    _check([ln], 10, 10, expect=None)    # inside the box, far from the line


def test_a_line_over_a_filled_rect_does_not_steal_its_middle():
    # The case that raised the question: a line group drawn over a
    # rect took every click inside the rect, because its box covers it.
    rect = Rect(x=0, y=0, width=72, height=72, fill=RED)
    grp = Group(children=(Line(x1=0, y1=72, x2=72, y2=0, stroke=INK),))
    _check([rect, grp], 20, 20, expect=(0, 0))
    _check([rect, grp], 36, 36, expect=(0, 1))


# ── Outline mode ─────────────────────────────────────────


def test_outline_mode_ignores_fill():
    r = Rect(x=0, y=0, width=40, height=40, fill=RED)
    _check([r], 20, 20, layer_vis=Visibility.OUTLINE, expect=None)
    _check([r], 1, 20, layer_vis=Visibility.OUTLINE, expect=(0, 0))


def test_outline_mode_ignores_stroke_width():
    fat = Stroke(color=Color.BLACK, width=20.0)
    r = Rect(x=0, y=0, width=40, height=40, stroke=fat)
    _check([r], 8, 20, expect=(0, 0))
    _check([r], 8, 20, layer_vis=Visibility.OUTLINE, expect=None)


def test_outline_mode_hits_an_unpainted_outline():
    r = Rect(x=0, y=0, width=40, height=40)
    _check([r], 40, 20, layer_vis=Visibility.OUTLINE, expect=(0, 0))


def test_outline_mode_set_on_the_element_itself():
    r = Rect(x=0, y=0, width=40, height=40, fill=RED, visibility=Visibility.OUTLINE)
    _check([r], 20, 20, expect=None)


def test_text_is_hit_by_its_box_even_in_outline_mode():
    # Area text: its box is its own width and height, so no font
    # measurement (and no Qt) is involved.
    t = Text(x=0, y=0, content="Hello", width=100.0, height=20.0)
    assert t.bounds() == (0, 0, 100.0, 20.0)
    _check([t], 50, 10, expect=(0, 0))
    _check([t], 50, 10, layer_vis=Visibility.OUTLINE, expect=(0, 0))
    _check([t], 50, 30, expect=None)


# ── Groups, transforms, locks ────────────────────────────


def test_a_group_passes_clicks_through_its_empty_interior():
    under = Rect(x=0, y=0, width=100, height=100, fill=RED)
    grp = Group(children=(Rect(x=0, y=0, width=10, height=10, fill=RED),
                          Rect(x=90, y=90, width=10, height=10, fill=RED)))
    _check([under, grp], 50, 50, expect=(0, 0))
    _check([under, grp], 5, 5, expect=(0, 1))


def test_deep_hit_returns_the_painted_leaf():
    grp = Group(children=(Rect(x=0, y=0, width=40, height=40, fill=RED),
                          Rect(x=0, y=0, width=40, height=40, stroke=INK)))
    # The unfilled rect is on top, but only its edge is painted.
    _check([grp], 20, 20, deep=True, expect=(0, 0, 0))
    _check([grp], 0, 20, deep=True, expect=(0, 0, 1))


def test_an_element_transform_moves_what_is_hit():
    r = Rect(x=0, y=0, width=20, height=20, fill=RED,
             transform=Transform.translate(100, 0))
    _check([r], 110, 10, expect=(0, 0))
    _check([r], 10, 10, expect=None)


def test_a_group_transform_reaches_its_children():
    grp = Group(children=(Rect(x=0, y=0, width=20, height=20, fill=RED),),
                transform=Transform.translate(0, 100))
    _check([grp], 10, 110, expect=(0, 0))
    _check([grp], 10, 10, expect=None)
    _check([grp], 10, 110, deep=True, expect=(0, 0, 0))


def test_a_locked_child_inside_a_group_is_not_hit():
    grp = Group(children=(Rect(x=0, y=0, width=20, height=20, fill=RED, locked=True),))
    _check([grp], 10, 10, expect=None)
    _check([grp], 10, 10, deep=True, expect=None)


def test_an_invisible_child_inside_a_group_is_not_hit():
    grp = Group(children=(Rect(x=0, y=0, width=20, height=20, fill=RED,
                               visibility=Visibility.INVISIBLE),))
    _check([grp], 10, 10, expect=None)


def _compound(**paint):
    a = Rect(x=0, y=0, width=40, height=40, fill=RED)
    b = Rect(x=10, y=10, width=20, height=20, fill=RED)
    return CompoundShape(operation=CompoundOperation.SUBTRACT_FRONT,
                         operands=(a, b), **paint)


def test_a_compound_shape_hits_its_evaluated_area():
    # NOT in the shared corpus: test_json omits a compound's own paint in
    # every port, so the corpus can only carry the outline case below. The
    # Rust and Swift ports pin this one in their own unit tests.
    global _RECORDING
    saved, _RECORDING = _RECORDING, None
    try:
        cs = _compound(fill=RED)
        _check([cs], 5, 5, expect=(0, 0))
        _check([cs], 20, 20, expect=None)    # the hole
    finally:
        _RECORDING = saved


def test_a_compound_shape_in_outline_mode_hits_both_rings():
    cs = _compound()
    _check([cs], 0, 20, expect=(0, 0), layer_vis=Visibility.OUTLINE)
    _check([cs], 10, 20, expect=(0, 0), layer_vis=Visibility.OUTLINE)   # the hole's edge
    _check([cs], 5, 5, expect=None, layer_vis=Visibility.OUTLINE)
    _check([cs], 20, 20, expect=None, layer_vis=Visibility.OUTLINE)


def test_open_subpaths_are_not_joined():
    # Two separate strokes; nothing is painted between their ends.
    d = (MoveTo(0, 0), LineTo(40, 0), MoveTo(0, 40), LineTo(40, 40))
    p = Path(d=d, stroke=INK)
    _check([p], 20, 0, expect=(0, 0))
    _check([p], 20, 40, expect=(0, 0))
    _check([p], 20, 20, expect=None)   # the join 40,0 → 0,40 would pass here


# ── The shared corpus ────────────────────────────────────

CORPUS = (pathlib.Path(__file__).resolve().parents[2]
          / "test_fixtures" / "algorithms" / "painted_hit.json")


def _record_all():
    global _RECORDING
    cases = []
    for name, fn in sorted(globals().items()):
        if not (name.startswith("test_") and callable(fn)) or name.startswith("test_the_shared"):
            continue
        _RECORDING = []
        try:
            fn()
        finally:
            rows, _RECORDING = _RECORDING, None
        for i, row in enumerate(rows):
            cases.append({"name": f"{name[5:]}#{i}", **row})
    return cases


def _corpus_text(cases) -> str:
    return json.dumps({
        "_doc": ("Generated from workspace_interpreter/tests/test_hit_law.py, whose "
                 "expectations are hand-written from transcripts/SELECTION_TOOL.md "
                 "§ Hit test: painted geometry. Regenerate with "
                 "JAS_WRITE_HIT_CORPUS=1 pytest that file; never edit by hand."),
        "cases": cases,
    }, indent=1, sort_keys=True) + "\n"


def test_the_shared_corpus_is_current():
    text = _corpus_text(_record_all())
    if os.environ.get("JAS_WRITE_HIT_CORPUS") == "1":
        with open(CORPUS, "w", encoding="utf-8", newline="") as f:
            f.write(text)
    assert CORPUS.read_text(encoding="utf-8") == text, "regenerate: JAS_WRITE_HIT_CORPUS=1 pytest " + __file__
    # Anti-vacuity: the corpus carries every row this file checks.
    assert len(json.loads(text)["cases"]) >= 49
