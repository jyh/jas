"""Combined Rotate + Shear gesture-seam tests for the Python YAML tool runtime.

Ports the rotate_parity_* / shear_parity_* seam tests from the Rust
reference (jas_dioxus/src/tools/yaml_tool.rs, committed ec985080) 1:1.

The transform tools (rotate / shear) are harder than the draw and
selection tools because they do NOT mutate the element's local
geometry: they bake their matrix into the element's ``transform`` field
(via compose_matrix_over_paths), leaving the rect's local x/y/w/h
untouched. So an element's LOCAL bounds alone are blind to a
rotate/shear; to prove a transform fired we map the element's local
geometric-bounds CORNERS through ``transform`` and re-derive the
axis-aligned bbox (``_selection_transformed_bbox`` — the load-bearing
helper, a direct port of Rust's ``selection_transformed_bbox``).

Each tool gets four cases (mirroring Rust exactly):

  1. a plain click (press+release at the SAME point, no move) sets the
     handler-written reference point (state.transform_reference_point)
     and does NOT transform — moved stays false so the apply branch
     never runs; the document is byte-identical and nothing is undoable.
  2. a real drag (move past the >2px threshold) APPLIES the transform.
     Proven by the post-transform SELECTION BBOX dims: a 100x40 rect
     rotated 90deg about its centre (50,20) swaps to ~40x100; a
     horizontal shear k=1 widens to ~140 and shifts min_x to ~-20. The
     SAME tolerances / numbers as Rust. can_undo is true after commit.
  3. a SUB-THRESHOLD drag (<2px) leaves moved=false -> the apply branch
     never runs -> document UNCHANGED, can_undo false.
  4. Escape MID-DRAG sets mode back to idle, so the following mouseup's
     ``mode == 'rotating'/'shearing'`` guard fails and the apply that
     case 2 proves WOULD fire is suppressed -> document UNCHANGED.
     Non-vacuous precisely because case 2 shows the identical
     press+move+release path DOES mutate.

These tools read no app-level state.* (no bridge seeding); the
reference point is handler-written GLOBAL state read back out of the
tool's own store (``_read_ref_point`` — port of Rust's read_ref_point).
"""

from __future__ import annotations

import json
import math
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
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    Color, Fill, Layer, Rect as RectElem, Stroke, Transform,
)
from geometry.test_json import document_to_test_json
from tools.tool import KeyMods
from tools.yaml_tool import YamlTool


# ── Shared machinery (mirrors yaml_tool_selection_variants_test.py) ──


def _load_ws_tool(tool_id: str) -> "YamlTool | None":
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


def _rotate_yaml_tool() -> "YamlTool | None":
    """Load the real Rotate tool from the workspace bundle."""
    return _load_ws_tool("rotate")


def _shear_yaml_tool() -> "YamlTool | None":
    """Load the real Shear tool from the workspace bundle."""
    return _load_ws_tool("shear")


def _ctx(model: Model):
    ctrl = Controller(model)
    ctx_obj = type("Ctx", (), {})()
    ctx_obj.model = model
    ctx_obj.controller = ctrl
    ctx_obj.document = model.document
    ctx_obj.request_update = lambda: None
    return ctx_obj, ctrl


# ── Fixtures (mirror Rust fixtures) ─────────────────────────────


def _transform_nonsquare_model() -> Model:
    """One-layer document with a single stroked NON-SQUARE 100x40 rect
    at doc (0,0), selected via element path [0,0]. The aspect ratio is
    the whole point: a 90deg rotation about the centre SWAPS the bbox
    dims (100x40 -> 40x100), a swap a square could never show."""
    rect = RectElem(
        x=0.0, y=0.0, width=100.0, height=40.0,
        fill=Fill(color=Color.BLACK),
        stroke=Stroke(color=Color.BLACK, width=1.0),
    )
    layer = Layer(name="L", children=(rect,))
    sel = frozenset({ElementSelection.all((0, 0))})
    return Model(document=Document(layers=(layer,), selection=sel))


def _selection_transformed_bbox(
    model: Model, path: tuple[int, ...],
) -> tuple[float, float, float, float]:
    """Axis-aligned bounding box of the element at ``path``, in DOCUMENT
    space, WITH its ``transform`` applied. Returns
    ``(min_x, min_y, width, height)``.

    This is the load-bearing helper: the transform tools bake their
    matrix into the element ``transform`` (via compose_matrix_over_paths),
    leaving the rect's LOCAL x/y/w/h untouched — so the element's local
    bounds alone are blind to a rotate/shear. We therefore take the
    element's LOCAL geometric bounds, map its four corners through the
    transform, and re-derive the axis-aligned box. With identity
    transform this is a no-op, so it also validates the click-only /
    sub-threshold / escape cases honestly (their bbox stays 100x40).

    ``geometric_bounds`` (not ``bounds``) so the 1px stroke inflation
    does not bleed into the dims — the fixture's stroke is there only to
    match the scale fixture, not to be measured.
    """
    elem = model.document.get_element(path)
    lx, ly, lw, lh = elem.geometric_bounds()  # LOCAL geometry, no stroke
    t = getattr(elem, "transform", None) or Transform()
    corners = [
        (lx, ly), (lx + lw, ly), (lx + lw, ly + lh), (lx, ly + lh),
    ]
    min_x = math.inf
    min_y = math.inf
    max_x = -math.inf
    max_y = -math.inf
    for cx, cy in corners:
        tx, ty = t.apply_point(cx, cy)
        min_x = min(min_x, tx)
        min_y = min(min_y, ty)
        max_x = max(max_x, tx)
        max_y = max(max_y, ty)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


def _doc_json(model: Model) -> str:
    """Canonical document JSON for the "unchanged?" comparison — the
    same canonicalization the cross-language byte-gate uses."""
    return document_to_test_json(model.document)


def _read_ref_point(tool: YamlTool) -> "tuple[float, float] | None":
    """Read ``state.transform_reference_point`` back out of the tool's
    own store as ``(rx, ry)``, or None if unset / malformed. The stored
    list elements may be int- or float-typed depending on the
    evaluator's whole-number folding, so we coerce via float()."""
    ctx = tool._store.eval_context()
    state = ctx.get("state")
    if not isinstance(state, dict):
        return None
    arr = state.get("transform_reference_point")
    if not isinstance(arr, (list, tuple)) or len(arr) < 2:
        return None
    return (float(arr[0]), float(arr[1]))


# ── Rotate ──────────────────────────────────────────────────────


class TestRotateParity:
    def test_click_only_sets_ref_and_does_not_transform(self):
        tool = _rotate_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        before = _doc_json(model)

        # Plain click at doc (10, 20): press+release at the SAME point,
        # no move => moved stays false => the apply branch never runs,
        # the else branch writes transform_reference_point.
        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)

        # Pivot was stored in the tool's global state (handler-written,
        # not bridged), readable as state.transform_reference_point.
        rp = _read_ref_point(tool)
        assert rp is not None and abs(rp[0] - 10.0) < 1e-9 and abs(rp[1] - 20.0) < 1e-9, (
            f"click-only must store the pivot at the click's doc point, got {rp}"
        )

        # Document is byte-identical and nothing is undoable.
        assert _doc_json(model) == before, "click-only must not mutate the document"
        assert not model.can_undo, "click-only must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after a click-only gesture, got {w}x{h}"
        )

    def test_drag_applies_90deg_and_swaps_bbox(self):
        tool = _rotate_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)

        # Seed the pivot at the selection CENTRE (50, 20) via a
        # click-only gesture (the production path that writes it).
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        assert not model.can_undo, "seeding the pivot must not create an undo step"

        # Rotate drag for theta = +90deg about (50, 20):
        #   press  doc (150, 20)  -> atan2(0, 100)   = 0deg
        #   cursor doc (50, 120)  -> atan2(100, 0)   = 90deg
        #   theta = 90 - 0 = 90deg. Move is >2px => moved = true.
        tool.on_press(ctx, 150.0, 20.0, False, False)
        tool.on_move(ctx, 50.0, 120.0, False, False, True)
        tool.on_release(ctx, 50.0, 120.0, False, False)

        # A 90deg rotation about the centre SWAPS the bbox dims.
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 40.0) < 0.5 and abs(h - 100.0) < 0.5, (
            f"90deg rotation must swap bbox dims to ~40x100, got {w}x{h}"
        )
        assert model.can_undo, "the journaled rotate commit must be undoable"

    def test_subthreshold_drag_does_not_transform(self):
        tool = _rotate_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        # Pre-seed a pivot so the only variable is the drag distance.
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        before = _doc_json(model)

        # Press, then a 1px move (<2px on both axes => moved stays
        # false), then release. The apply branch must not run.
        tool.on_press(ctx, 150.0, 20.0, False, False)
        tool.on_move(ctx, 151.0, 21.0, False, False, True)
        tool.on_release(ctx, 151.0, 21.0, False, False)

        assert _doc_json(model) == before, "a sub-threshold drag must not mutate"
        assert not model.can_undo, "a sub-threshold drag must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after a sub-threshold drag, got {w}x{h}"
        )

    def test_escape_mid_drag_suppresses_apply(self):
        tool = _rotate_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        before = _doc_json(model)

        # Begin the SAME 90deg drag proven to mutate in the apply case,
        # but press Escape BEFORE releasing. Escape sets mode back to
        # idle, so the subsequent mouseup's `mode == 'rotating'` guard
        # fails and the apply is suppressed.
        tool.on_press(ctx, 150.0, 20.0, False, False)
        tool.on_move(ctx, 50.0, 120.0, False, False, True)
        tool.on_key_event(ctx, "Escape", KeyMods())
        tool.on_release(ctx, 50.0, 120.0, False, False)

        assert _doc_json(model) == before, (
            "Escape mid-drag must suppress the apply that case 2 proves would fire"
        )
        assert not model.can_undo, "an escaped rotate must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after an escaped rotate, got {w}x{h}"
        )


# ── Shear ───────────────────────────────────────────────────────


class TestShearParity:
    def test_click_only_sets_ref_and_does_not_transform(self):
        tool = _shear_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        before = _doc_json(model)

        tool.on_press(ctx, 10.0, 20.0, False, False)
        tool.on_release(ctx, 10.0, 20.0, False, False)

        rp = _read_ref_point(tool)
        assert rp is not None and abs(rp[0] - 10.0) < 1e-9 and abs(rp[1] - 20.0) < 1e-9, (
            f"click-only must store the pivot at the click's doc point, got {rp}"
        )

        assert _doc_json(model) == before, "click-only must not mutate the document"
        assert not model.can_undo, "click-only must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after a click-only gesture, got {w}x{h}"
        )

    def test_drag_applies_horizontal_shear_and_widens_bbox(self):
        tool = _shear_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)

        # Seed the pivot at the selection CENTRE (50, 20).
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        assert not model.can_undo, "seeding the pivot must not create an undo step"

        # Shift-constrained HORIZONTAL shear, k = 1 (angle = 45deg):
        #   press  doc (50, 60)  -> |press_y - ref_y| = 40
        #   cursor doc (90, 60)  -> dx = 40 (dominant-x), dy = 0
        #   k = dx / 40 = 1.0  =>  angle = atan(1) = 45deg.
        # Shift is the FIRST bool arg to the seam methods.
        tool.on_press(ctx, 50.0, 60.0, True, False)
        tool.on_move(ctx, 90.0, 60.0, True, False, True)
        tool.on_release(ctx, 90.0, 60.0, True, False)

        # Horizontal shear widens the bbox (100 + k*height = 140), keeps
        # the height (40), and shifts the box LEFT (min_x = -20: the top
        # edge slides left, the bottom edge slides right).
        min_x, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 140.0) < 0.5, (
            f"horizontal shear must widen bbox to ~140, got width {w}"
        )
        assert abs(h - 40.0) < 0.5, (
            f"horizontal shear must keep height ~40, got {h}"
        )
        assert abs(min_x - (-20.0)) < 0.5, (
            f"horizontal shear about the centre must push min_x to ~-20, got {min_x}"
        )
        assert model.can_undo, "the journaled shear commit must be undoable"

    def test_subthreshold_drag_does_not_transform(self):
        tool = _shear_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        before = _doc_json(model)

        # 1px move on both axes (<2px => moved stays false).
        tool.on_press(ctx, 50.0, 60.0, True, False)
        tool.on_move(ctx, 51.0, 61.0, True, False, True)
        tool.on_release(ctx, 51.0, 61.0, True, False)

        assert _doc_json(model) == before, "a sub-threshold drag must not mutate"
        assert not model.can_undo, "a sub-threshold drag must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after a sub-threshold drag, got {w}x{h}"
        )

    def test_escape_mid_drag_suppresses_apply(self):
        tool = _shear_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _transform_nonsquare_model()
        ctx, _ = _ctx(model)
        tool.on_press(ctx, 50.0, 20.0, False, False)
        tool.on_release(ctx, 50.0, 20.0, False, False)
        before = _doc_json(model)

        # The SAME k=1 shear drag that case 2 proves mutates, but Escape
        # before release suppresses the apply.
        tool.on_press(ctx, 50.0, 60.0, True, False)
        tool.on_move(ctx, 90.0, 60.0, True, False, True)
        tool.on_key_event(ctx, "Escape", KeyMods())
        tool.on_release(ctx, 90.0, 60.0, True, False)

        assert _doc_json(model) == before, (
            "Escape mid-drag must suppress the apply that case 2 proves would fire"
        )
        assert not model.can_undo, "an escaped shear must leave no undo step"
        _, _, w, h = _selection_transformed_bbox(model, (0, 0))
        assert abs(w - 100.0) < 0.5 and abs(h - 40.0) < 0.5, (
            f"bbox must stay 100x40 after an escaped shear, got {w}x{h}"
        )
