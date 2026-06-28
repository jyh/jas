"""Path B layout property tests: no panel renders overlapping or
overflowing widgets.

The cross-language byte-gate (``test_fixtures/algorithms/panel_layout.json``)
proves the 5 apps *agree* on the rects, but a layout that is consistently
wrong across apps still passes it. This suite pins the *semantic* property
the byte-gate cannot: within a panel, no two leaf widgets overlap, and no
leaf extends past the panel width.

The defect this guards against: rows with ``col`` spans use the Bootstrap-12
grid; a child whose intrinsic width exceeds its column cell used to render at
that intrinsic width, overrunning its neighbour (e.g. the Opacity panel's
"Opacity:" label over the value field; the Stroke panel's dash inputs). The
grid now grows cells to their content and shrinks-to-fit when a row
over-subscribes, clamping each leaf to its cell so nothing overlaps.
"""

from __future__ import annotations

import importlib.util
import json
import os

import pytest

from workspace_interpreter.panel_layout import render_plan

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_PANEL_W = 228  # canonical dock panel width (matches the byte-gate seed)

# Composite panels whose data-driven widgets the v1 absolute pass does not
# size yet; they stay on each app's native layout path. color/gradient/layers
# carry composite/tree widgets; swatches embeds the fill/stroke control — a 2D
# arrangement (overlapping fill+stroke chips, swap arrow, default-colors, fill
# type) modelled as a fixed-height column whose content the generic column
# layout cannot fit (the dedicated fill_stroke_widget leaf would; future work).
_EXCLUDED = {
    "color_panel_content",
    "gradient_panel_content",
    "layers_panel_content",
    "swatches_panel_content",
}


def _load_ctx() -> dict:
    """The real per-panel eval context used by the byte-gate golden, so this
    test exercises the same data the apps render (foreach lists, bindings)."""
    path = os.path.join(_ROOT, "scripts", "gen_panel_layout_fixture.py")
    spec = importlib.util.spec_from_file_location("gen_panel_layout_fixture", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod._CTX


def _panels() -> dict:
    bundle = json.load(open(os.path.join(_ROOT, "workspace", "workspace.json")))
    return bundle["panels"]


def _overlap(a: dict, b: dict) -> bool:
    if a["w"] <= 0 or a["h"] <= 0 or b["w"] <= 0 or b["h"] <= 0:
        return False
    return not (
        a["x"] + a["w"] <= b["x"]
        or b["x"] + b["w"] <= a["x"]
        or a["y"] + a["h"] <= b["y"]
        or b["y"] + b["h"] <= a["y"]
    )


_PANEL_IDS = [
    pid
    for pid in _panels()
    if pid.endswith("_panel_content") and pid not in _EXCLUDED
]


@pytest.mark.parametrize("panel_id", _PANEL_IDS)
def test_panel_has_no_overlapping_leaves(panel_id):
    """No two leaf widgets in a panel overlap (avail_h=0 = what the dock draws)."""
    ctx = _load_ctx().get(panel_id.replace("_panel_content", ""), {})
    plan = render_plan(_panels()[panel_id], _PANEL_W, 0, ctx)
    leaves = plan["leaves"]
    overlaps = []
    for i in range(len(leaves)):
        for j in range(i + 1, len(leaves)):
            ri, rj = leaves[i]["rect"], leaves[j]["rect"]
            if _overlap(ri, rj):
                ki = leaves[i]["node"].get("type", "?")
                kj = leaves[j]["node"].get("type", "?")
                overlaps.append(f"{ki}{ri} X {kj}{rj}")
    assert not overlaps, f"{panel_id} has overlapping leaves:\n  " + "\n  ".join(overlaps)


@pytest.mark.parametrize("panel_id", _PANEL_IDS)
def test_panel_leaves_within_width(panel_id):
    """No leaf extends past the panel width."""
    ctx = _load_ctx().get(panel_id.replace("_panel_content", ""), {})
    plan = render_plan(_panels()[panel_id], _PANEL_W, 0, ctx)
    over = [
        (lf["node"].get("type", "?"), lf["rect"])
        for lf in plan["leaves"]
        if lf["rect"]["w"] > 0 and lf["rect"]["x"] + lf["rect"]["w"] > _PANEL_W
    ]
    assert not over, f"{panel_id} has leaves past width {_PANEL_W}:\n  " + "\n  ".join(
        f"{k}{r}" for k, r in over
    )
