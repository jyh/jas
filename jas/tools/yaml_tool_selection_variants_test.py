"""Selection-VARIANT gesture-seam tests for the Python YAML tool runtime.

Ports the selection-variant seam tests from the Rust reference
(jas_dioxus/src/tools/yaml_tool.rs) for three selection tools that are
harder than the draw tools because they hit-test the document and (for
partial_selection) run an alt-drag-copy preview state machine:

  * partial_selection — control-point selection + marquee + the
    SEL-132 at-press / mid-drag alt-copy flow.
  * lasso — polygon enclosure selection + click-without-drag behavior.
  * interior_selection — click recurses into groups; marquee selects
    partially.

The base ``selection`` tool already works in this app, so this module
reuses the exact loader + model/context/hit-test/selection-seeding
machinery from ``yaml_tool_test.py``; only the cases are new. The
asserted child counts, selection paths, rect positions, and mode
strings mirror the Rust reference exactly.
"""

from __future__ import annotations

import json
import os
import sys

_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from document.controller import Controller
from document.document import Document, selection_kind_contains
from document.model import Model
from geometry.element import Group, Layer, Rect as RectElem


# ── Shared machinery (mirrors yaml_tool_test.py) ────────────────


def _load_ws_tool(tool_id: str) -> "YamlTool | None":
    from tools.yaml_tool import YamlTool

    ws_path = os.path.abspath(os.path.join(
        _REPO_ROOT, "workspace", "workspace.json",
    ))
    if not os.path.exists(ws_path):
        return None
    with open(ws_path, "r") as f:
        data = json.load(f)
    tools = data.get("tools")
    if not isinstance(tools, dict):
        return None
    spec = tools.get(tool_id)
    return YamlTool.from_workspace_tool(spec) if spec else None


def _ctx(model: Model):
    ctrl = Controller(model)
    ctx_obj = type("Ctx", (), {})()
    ctx_obj.model = model
    ctx_obj.controller = ctrl
    ctx_obj.document = model.document
    ctx_obj.request_update = lambda: None
    return ctx_obj, ctrl


def _children(model: Model):
    return model.document.layers[0].children


# ── Fixtures (mirror Rust fixtures) ─────────────────────────────


def _model_with_rect_element() -> Model:
    # Rect at (0, 0) 10x10 — control points:
    #   0 = (0, 0)   top-left
    #   1 = (10, 0)  top-right
    #   2 = (10, 10) bottom-right
    #   3 = (0, 10)  bottom-left
    layer = Layer(name="L", children=(
        RectElem(x=0.0, y=0.0, width=10.0, height=10.0),
    ))
    return Model(document=Document(layers=(layer,)))


def _selection_model_for_lasso() -> Model:
    # Single rect at (50, 50, 20, 20).
    layer = Layer(name="L", children=(
        RectElem(x=50.0, y=50.0, width=20.0, height=20.0),
    ))
    return Model(document=Document(layers=(layer,)))


def _model_with_rect_inside_group() -> Model:
    rect = RectElem(x=50.0, y=50.0, width=20.0, height=20.0)
    group = Group(children=(rect,))
    layer = Layer(name="L", children=(group,))
    return Model(document=Document(layers=(layer,)))


# ── Partial Selection variant tests ─────────────────────────────


class TestPartialSelectionVariants:
    def test_click_on_cp_selects_it(self):
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, _ = _ctx(model)
        # Click on CP 0 at (0, 0).
        tool.on_press(ctx, 0.0, 0.0)
        tool.on_release(ctx, 0.0, 0.0)
        sel = list(model.document.selection)
        assert len(sel) == 1
        assert sel[0].path == (0, 0)
        # The selection kind should include cp 0.
        assert selection_kind_contains(sel[0].kind, 0)
        assert model.can_undo

    def test_click_empty_starts_marquee(self):
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, _ = _ctx(model)
        # Click far from any CP.
        tool.on_press(ctx, 500.0, 500.0)
        # Mode should be "marquee".
        assert tool.tool_state("mode") == "marquee"
        # Release at a far position to commit the marquee.
        tool.on_release(ctx, 600.0, 600.0)
        # No hits → no selection.
        assert len(model.document.selection) == 0

    def test_marquee_picks_control_points(self):
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, _ = _ctx(model)
        # Marquee covering the rect's CPs (all at 0 or 10 in x and y).
        tool.on_press(ctx, -5.0, -5.0)
        tool.on_move(ctx, 15.0, 15.0, dragging=True)
        tool.on_release(ctx, 15.0, 15.0)
        # All 4 CPs of the rect should be selected (partial_select_rect
        # with extend=false replaces selection).
        sel = list(model.document.selection)
        assert len(sel) == 1
        assert sel[0].path == (0, 0)

    def test_at_press_alt_drag_copies_path(self):
        # SEL-132 at-press flow: with the rect selected, press on a CP
        # with Alt held, drag past threshold, release. Exactly one copy
        # is inserted (children 1 -> 2).
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        n_before = len(_children(model))
        tool.on_press(ctx, 0.0, 0.0, alt=True)
        tool.on_move(ctx, 5.0, 0.0, alt=True, dragging=True)
        tool.on_move(ctx, 80.0, 0.0, alt=True, dragging=True)
        tool.on_release(ctx, 80.0, 0.0, alt=True)
        n_after = len(_children(model))
        assert n_after == n_before + 1, (
            "alt-at-press drag should produce exactly one copy"
        )

    def test_mid_drag_alt_copies_path(self):
        # SEL-132 mid-drag flow: press WITHOUT Alt, drag past threshold,
        # press Alt mid-drag, release WITH Alt held. Same outcome as
        # at-press alt: exactly one copy inserted, original stays at its
        # original position (preview-restored on the alt-press
        # transition).
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        n_before = len(_children(model))
        tool.on_press(ctx, 0.0, 0.0)
        # Past 4-px threshold, no alt yet — snapshot fires, mode=moving,
        # translate by (5,0).
        tool.on_move(ctx, 5.0, 0.0, dragging=True)
        # Alt pressed mid-drag — entering preview: original snaps back
        # to (0,0,10,10).
        tool.on_move(ctx, 10.0, 0.0, alt=True, dragging=True)
        tool.on_move(ctx, 80.0, 0.0, alt=True, dragging=True)
        # Release with Alt still held — commit copy at cursor's release
        # position relative to the press position.
        tool.on_release(ctx, 80.0, 0.0, alt=True)
        children = _children(model)
        assert len(children) == n_before + 1, (
            "mid-drag alt + release-with-alt should commit exactly one copy"
        )
        # Original at (0,0) unchanged — preview snapped it back.
        original = children[0]
        assert isinstance(original, RectElem)
        assert original.x == 0.0, "original x preserved by preview restore"
        assert original.y == 0.0, "original y preserved by preview restore"
        # Copy at (80, 0) — translated by (cursor - press).
        copy = children[1]
        assert isinstance(copy, RectElem)
        assert copy.x == 80.0, "copy at cursor x"
        assert copy.y == 0.0, "copy at cursor y"

    def test_mid_drag_alt_preview_shows_real_copy(self):
        # During the mid-drag alt-preview phase, the document should
        # contain BOTH the original (snapped back to press) AND a real
        # copy at the cursor — so the user sees a moving rendered
        # element, not a bounding-box ghost.
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        n_before = len(_children(model))
        tool.on_press(ctx, 0.0, 0.0)
        tool.on_move(ctx, 5.0, 0.0, dragging=True)
        # Alt pressed mid-drag — enter preview.
        tool.on_move(ctx, 30.0, 0.0, alt=True, dragging=True)
        children = _children(model)
        assert len(children) == n_before + 1, (
            "during preview the document holds original + real copy"
        )
        original = children[0]
        assert isinstance(original, RectElem)
        assert original.x == 0.0, "original snapped back to press"
        copy = children[1]
        assert isinstance(copy, RectElem)
        assert copy.x == 30.0, "copy at cursor delta from press"

    def test_mid_drag_alt_released_before_mouseup_no_copy(self):
        # Press WITHOUT Alt, drag past threshold, press Alt mid-drag,
        # RELEASE Alt before mouseup. Should be a normal move — the
        # exit-preview transition re-applies the cumulative delta so the
        # original lands at the cursor; no copy is created.
        tool = _load_ws_tool("partial_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_element()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        n_before = len(_children(model))
        tool.on_press(ctx, 0.0, 0.0)
        tool.on_move(ctx, 5.0, 0.0, dragging=True)
        tool.on_move(ctx, 30.0, 0.0, alt=True, dragging=True)
        # Alt released before mouseup — exit preview: translate by
        # cumulative-from-press to land original at the cursor.
        tool.on_move(ctx, 50.0, 0.0, alt=False, dragging=True)
        tool.on_release(ctx, 50.0, 0.0, alt=False)
        children = _children(model)
        assert len(children) == n_before, (
            "alt-released-before-mouseup is a normal move; no copy"
        )
        original = children[0]
        assert isinstance(original, RectElem)
        assert original.x == 50.0, "original moved to cursor x"
        assert original.y == 0.0, "original y unchanged"


# ── Lasso variant tests ─────────────────────────────────────────


class TestLassoVariants:
    def test_lasso_select(self):
        tool = _load_ws_tool("lasso")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _selection_model_for_lasso()
        ctx, _ = _ctx(model)
        # Polygon enclosing the rect.
        tool.on_press(ctx, 40.0, 40.0)
        tool.on_move(ctx, 80.0, 40.0, dragging=True)
        tool.on_move(ctx, 80.0, 80.0, dragging=True)
        tool.on_move(ctx, 40.0, 80.0, dragging=True)
        tool.on_release(ctx, 40.0, 80.0)
        assert len(model.document.selection) != 0

    def test_lasso_miss(self):
        tool = _load_ws_tool("lasso")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _selection_model_for_lasso()
        ctx, _ = _ctx(model)
        # Polygon nowhere near the rect.
        tool.on_press(ctx, 0.0, 0.0)
        tool.on_move(ctx, 10.0, 0.0, dragging=True)
        tool.on_move(ctx, 10.0, 10.0, dragging=True)
        tool.on_move(ctx, 0.0, 10.0, dragging=True)
        tool.on_release(ctx, 0.0, 10.0)
        assert len(model.document.selection) == 0

    def test_click_without_drag_clears(self):
        tool = _load_ws_tool("lasso")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _selection_model_for_lasso()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        assert len(model.document.selection) != 0
        # Press + release at same point, no shift — buffer has 1 point,
        # fewer than 3 → falls into "clear selection" branch.
        tool.on_press(ctx, 5.0, 5.0)
        tool.on_release(ctx, 5.0, 5.0)
        assert len(model.document.selection) == 0

    def test_click_without_drag_shift_preserves(self):
        tool = _load_ws_tool("lasso")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _selection_model_for_lasso()
        ctx, ctrl = _ctx(model)
        ctrl.select_element((0, 0))
        # Shift+click without drag — the "clear selection" else-branch is
        # guarded by not shift_held so nothing happens.
        tool.on_press(ctx, 5.0, 5.0, shift=True)
        tool.on_release(ctx, 5.0, 5.0, shift=True)
        assert len(model.document.selection) != 0

    def test_state_transitions(self):
        tool = _load_ws_tool("lasso")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _selection_model_for_lasso()
        ctx, _ = _ctx(model)
        assert tool.tool_state("mode") == "idle"
        tool.on_press(ctx, 10.0, 10.0)
        assert tool.tool_state("mode") == "drawing"
        tool.on_release(ctx, 10.0, 10.0)
        assert tool.tool_state("mode") == "idle"


# ── Interior Selection variant tests ────────────────────────────


class TestInteriorSelectionVariants:
    def test_click_enters_group(self):
        tool = _load_ws_tool("interior_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_inside_group()
        ctx, _ = _ctx(model)
        # Click inside the rect (which lives at layer[0]/group[0]/rect[0]).
        tool.on_press(ctx, 55.0, 55.0)
        tool.on_release(ctx, 55.0, 55.0)
        sel = list(model.document.selection)
        assert len(sel) == 1
        assert sel[0].path == (0, 0, 0), (
            "interior selection should pick the leaf inside the group"
        )

    def test_marquee_selects_partial(self):
        tool = _load_ws_tool("interior_selection")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_rect_inside_group()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 40.0, 40.0)
        tool.on_move(ctx, 80.0, 80.0, dragging=True)
        tool.on_release(ctx, 80.0, 80.0)
        # partial_select_in_rect produced a selection; entries are
        # Partial so even whole-box coverage lists the element with
        # partial control points.
        assert len(model.document.selection) != 0
