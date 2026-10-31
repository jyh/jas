"""STATUS-jas row 65, arm (c): declare a floor where the stub text metric bites.

The planner measures text as ``len(text) * CHAR_WIDTH`` (10), a stub that
keeps every port integer-exact. At the dock's panel width, 228 (both shells
plan dock panels there, STATUS-flask 710), Magic Wand's four "Tolerance:"
rows are over-subscribed only because of that stub: the text plans 100 wide
where the web renders it 50.76, so the row's proportional shrink squeezes
each tolerance input to 30-38, below the 45 every port plans an unsqueezed
``number_input`` at. Each input declares ``min_width`` at that width, so the
row shrinks the text instead.

Align is over-subscribed at 228 too, but nothing in it is cut: each of its
texts plans at least as wide as the web renders it. Its arm below is the
control that the floor is needed only where it bites.

Windows draws "Tolerance:" wider than the web: WinUI needs 54.67 DIP
(STATUS-flask 717; 712 bracketed it at 54-57), so each "Tolerance:" text
declares 55. Windows draws the whole "Stroke Weight" toggle 104.67 wide
(STATUS-flask 717), one DIP more than the 104 its cell planned at, and WinUI
wraps the cut label, so it read "Stroke". The toggle declares 105, which a
``col`` grid line now honours (STATUS-jas row 68). That leaves the row's
right cell 101: 55 + gap + 45 exceeds it, and a row whose floors do not fit
drops them all, so that one input declares what is left, 42 ("100", its
max, had 18 DIP to spare at 41, STATUS-flask 715).

The web's and Windows' widths are flask's measurements (STATUS-flask 710 and
717), rounded up. They are the only typed numbers here.
"""

import json
import math
import pathlib

from workspace_interpreter.panel_layout import _KIND_FALLBACK_W, layout_panel

PANEL_W = 228  # the dock's panel body (STATUS-flask 710); the corpus's seed width
TOLERANCE_TEXT_ON_WEB = math.ceil(50.76)
TOLERANCE_TEXT_ON_WINDOWS = math.ceil(54.67)  # WinUI (STATUS-flask 717)
STROKE_WEIGHT_TOGGLE_ON_WINDOWS = math.ceil(104.67)  # box + padding + label (STATUS-flask 717)
TIGHT = "mwp_stroke_weight_tolerance"  # its cell cannot hold 55 + gap + 45 at 228
ALIGN_TEXTS_ON_WEB = {"Distribute Spacing:": math.ceil(83.94), "Align To:": math.ceil(38.18)}
INPUTS = ["mwp_fill_tolerance", "mwp_stroke_tolerance",
          "mwp_stroke_weight_tolerance", "mwp_opacity_tolerance"]


def _panel(pid):
    path = pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json"
    panel = json.loads(path.read_text(encoding="utf-8"))["panels"][pid]
    rects = {tuple(r["path"]): r["rect"] for r in layout_panel(panel, PANEL_W, 600, {})}
    nodes = {}

    def walk(n, p):
        nodes[p] = n
        for i, c in enumerate(n.get("children", [])):
            walk(c, p + (i,))

    walk(panel["content"], ())
    return rects, nodes


def _path_of(nodes, node_id):
    hits = [p for p, n in nodes.items() if n.get("id") == node_id]
    assert len(hits) == 1, (node_id, hits)
    return hits[0]


def _row_parts(rects, nodes, input_id):
    p = _path_of(nodes, input_id)
    text = p[:-1] + (p[-1] - 1,)
    assert nodes[text].get("content") == "Tolerance:", (input_id, nodes[text])
    row = p[:-1]
    gap = nodes[row]["style"]["gap"]
    return p, text, row, gap


def test_each_tolerance_input_keeps_the_width_an_unsqueezed_input_plans_at():
    rects, nodes = _panel("magic_wand_panel_content")
    floor = _KIND_FALLBACK_W["number_input"]
    widths = {i: rects[_path_of(nodes, i)]["w"] for i in INPUTS if i != TIGHT}
    assert widths == {i: floor for i in INPUTS if i != TIGHT}, widths


def test_the_tight_rows_input_takes_what_its_cell_leaves_the_windows_text():
    rects, nodes = _panel("magic_wand_panel_content")
    p, _text, row, gap = _row_parts(rects, nodes, TIGHT)
    left = rects[row]["w"] - gap - TOLERANCE_TEXT_ON_WINDOWS
    assert left < _KIND_FALLBACK_W["number_input"], "the row is not tight; drop the exception"
    assert rects[p]["w"] == left == nodes[p]["style"]["min_width"], (rects[p], rects[row])


def test_each_tolerance_input_declares_its_floor():
    _rects, nodes = _panel("magic_wand_panel_content")
    floor = _KIND_FALLBACK_W["number_input"]
    for i in INPUTS:
        if i != TIGHT:
            assert nodes[_path_of(nodes, i)]["style"]["min_width"] == floor, i


def test_each_tolerance_text_keeps_the_width_windows_draws_it_at():
    rects, nodes = _panel("magic_wand_panel_content")
    assert TOLERANCE_TEXT_ON_WINDOWS >= TOLERANCE_TEXT_ON_WEB
    for i in INPUTS:
        p, text, _row, _gap = _row_parts(rects, nodes, i)
        assert nodes[text]["style"]["min_width"] == TOLERANCE_TEXT_ON_WINDOWS, i
        assert rects[text]["w"] >= TOLERANCE_TEXT_ON_WINDOWS, (i, rects[text])
        # The text and the input share their cell, the row's inner width.
        assert rects[text]["x"] + rects[text]["w"] <= rects[p]["x"], (i, rects[text], rects[p])


def test_the_stroke_weight_toggle_keeps_the_width_windows_draws_it_at():
    rects, nodes = _panel("magic_wand_panel_content")
    p = _path_of(nodes, "mwp_stroke_weight")
    assert nodes[p]["style"]["min_width"] == STROKE_WEIGHT_TOGGLE_ON_WINDOWS
    assert rects[p]["w"] >= STROKE_WEIGHT_TOGGLE_ON_WINDOWS, rects[p]
    # Its cell (the col-5 container) is what the grid line sizes.
    assert rects[p[:-1]]["w"] >= STROKE_WEIGHT_TOGGLE_ON_WINDOWS, rects[p[:-1]]


def test_align_needs_no_floor_its_texts_plan_wider_than_they_render():
    rects, nodes = _panel("align_panel_content")
    seen = {}
    for p, n in nodes.items():
        if n.get("type") == "text" and n.get("content") in ALIGN_TEXTS_ON_WEB:
            seen[n["content"]] = rects[p]["w"]
    assert seen.keys() == ALIGN_TEXTS_ON_WEB.keys(), seen
    for t, w in seen.items():
        assert w >= ALIGN_TEXTS_ON_WEB[t], (t, w)
