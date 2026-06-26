"""Combined Zoom + Hand viewport gesture-seam tests for the Python YAML
tool runtime.

Ports the zoom_parity_* (4) / hand_parity_* (3) seam tests from the Rust
reference (jas_dioxus/src/tools/yaml_tool.rs, committed 69fd8f1d) 1:1.

These are VIEWPORT tools: unlike the draw / selection / transform tools
they do NOT touch the document at all — they mutate the per-tab VIEW
STATE on the model (``zoom_level`` / ``view_offset_x`` / ``view_offset_y``).
So the cases assert against those three model fields directly, and prove
the no-op / Escape paths by asserting the document JSON is byte-identical
and ``can_undo`` stays false (view changes are never journaled).

The tools read SCREEN coordinates (``event.x`` / ``event.y``), not doc
coords, and the seam methods are driven with screen x/y. At the identity
view (zoom 1, offset 0) screen == doc, which is why the fixture forces the
identity view (the production Model constructor recenters on the artboard,
so we reset it).

Zoom reads ``preferences.viewport.zoom_step`` (= 1.2) — which the
production YamlTool dispatch must surface in the eval context so the
``zoom_in`` / ``zoom_out`` actions resolve ``factor:
"preferences.viewport.zoom_step"``. ``_bundle_zoom_step`` reads the same
key out of the bundle (mirroring Rust's ``bundle_zoom_step``) so the
tests assert against the REAL production factor, not a guess.

Mechanics mirrored from Rust:

  HAND — a drag press(s1) -> cursor(s2) sets
    view_offset = initial_offset + (cursor - press)   (same sign).
  Escape mid-pan restores the initial offset; mode idle -> panning ->
  idle.

  ZOOM — a plain CLICK (press+release, no drag) zooms IN to
    zoom_level == initial * 1.2 and recenters so the clicked screen point
    stays glued (off = sx*(1 - z_new) at the identity view). An ALT-click
    zooms OUT to initial * (1/1.2) == 0.8333…. A sub-4px drag is treated
    as a click. Escape mid-scrubby-drag restores the pre-drag view.
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
from document.document import Document
from document.model import Model
from geometry.element import Layer
from geometry.test_json import document_to_test_json
from tools.tool import KeyMods
from tools.yaml_tool import YamlTool


# ── Shared machinery (mirrors yaml_tool_transform_test.py) ───────────


def _load_ws_data() -> "dict | None":
    ws_path = os.path.abspath(os.path.join(
        _REPO_ROOT, "workspace", "workspace.json",
    ))
    if not os.path.exists(ws_path):
        return None
    with open(ws_path, "r") as f:
        return json.load(f)


def _load_ws_tool(tool_id: str) -> "YamlTool | None":
    data = _load_ws_data()
    if data is None:
        return None
    tools = data.get("tools")
    if not isinstance(tools, dict):
        return None
    spec = tools.get(tool_id)
    return YamlTool.from_workspace_tool(spec) if spec else None


def _zoom_yaml_tool() -> "YamlTool | None":
    """Load the real Zoom tool from the workspace bundle."""
    return _load_ws_tool("zoom")


def _hand_yaml_tool() -> "YamlTool | None":
    """Load the real Hand tool from the workspace bundle."""
    return _load_ws_tool("hand")


def _bundle_zoom_step() -> float:
    """Read ``preferences.viewport.zoom_step`` out of the bundle so the
    tests assert against the REAL production factor rather than a
    hardcoded guess. Mirrors Rust's ``bundle_zoom_step``. Raises loudly
    (via the assertion in the caller) if the key is absent — the tests
    are meaningless without it."""
    data = _load_ws_data()
    if data is None:
        return float("nan")
    return float(
        data.get("preferences", {})
        .get("viewport", {})
        .get("zoom_step")
    )


def _ctx(model: Model):
    """ToolContext stub matching yaml_tool_transform_test._ctx.

    ``app_state`` is omitted on purpose: the viewport tools read no
    app-level ``state.*`` (no bridge seeding), exactly like Rust's
    viewport_model which threads no app state."""
    ctrl = Controller(model)
    ctx_obj = type("Ctx", (), {})()
    ctx_obj.model = model
    ctx_obj.controller = ctrl
    ctx_obj.document = model.document
    ctx_obj.request_update = lambda: None
    return ctx_obj, ctrl


def _viewport_model() -> Model:
    """Minimal one-layer document for the VIEWPORT tools. They ignore
    document content entirely (they touch only view state), so an empty
    layer is enough. Mirrors Rust's ``viewport_model``.

    The Python Model constructor recenters the view on the current
    artboard, so we force the IDENTITY view (zoom 1.0, offset 0,0) after
    construction — matching Rust's fresh artboard-less model. At identity
    view screen == doc, which is what the zoom-anchor arithmetic assumes
    (off = sx*(1 - z_new))."""
    layer = Layer(name="L", children=())
    model = Model(document=Document(layers=(layer,)))
    model.zoom_level = 1.0
    model.view_offset_x = 0.0
    model.view_offset_y = 0.0
    return model


def _doc_json(model: Model) -> str:
    """Canonical document JSON for the "unchanged?" comparison — the same
    canonicalization the cross-language byte-gate uses."""
    return document_to_test_json(model.document)


def _read_hand_mode(tool: YamlTool) -> str:
    """Read ``tool.hand.mode`` out of the tool's own store (mirrors
    Rust's read_mode closure)."""
    ctx = tool._store.eval_context()
    tool_scope = ctx.get("tool")
    if not isinstance(tool_scope, dict):
        return ""
    hand = tool_scope.get("hand")
    if not isinstance(hand, dict):
        return ""
    mode = hand.get("mode")
    return mode if isinstance(mode, str) else ""


# ── Hand ─────────────────────────────────────────────────────────────


class TestHandParity:
    def test_drag_pans_view_offset_by_screen_delta(self):
        tool = _hand_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        # Start from a NON-zero baseline offset so the test proves the
        # pan is `initial + delta`, not just `delta`.
        model.view_offset_x = 30.0
        model.view_offset_y = -10.0
        before_doc = _doc_json(model)
        z_before = model.zoom_level

        # Press at screen (100,100); drag to (160,135).
        #   delta = (160-100, 135-100) = (+60, +35)
        # doc.pan.apply: off = initial + delta (SAME sign), so
        #   off_x = 30 + 60 = 90
        #   off_y = -10 + 35 = 25
        tool.on_press(ctx, 100.0, 100.0, False, False)
        tool.on_move(ctx, 160.0, 135.0, False, False, True)

        assert abs(model.view_offset_x - 90.0) < 1e-9, (
            "pan must shift view_offset_x by the +60 screen delta from the "
            f"initial 30 to 90, got {model.view_offset_x}"
        )
        assert abs(model.view_offset_y - 25.0) < 1e-9, (
            "pan must shift view_offset_y by the +35 screen delta from the "
            f"initial -10 to 25, got {model.view_offset_y}"
        )
        # The pan must touch ONLY the offset — zoom and document stay put.
        assert abs(model.zoom_level - z_before) < 1e-9, (
            "a Hand pan must not change zoom_level"
        )
        assert _doc_json(model) == before_doc, (
            "a Hand pan must not mutate the document"
        )
        assert not model.can_undo, "a view-only pan must leave no undo step"

        # Idempotency: a SECOND move to the same cursor recomputes from
        # press+initial, so the offset is identical (not doubled).
        tool.on_move(ctx, 160.0, 135.0, False, False, True)
        assert (
            abs(model.view_offset_x - 90.0) < 1e-9
            and abs(model.view_offset_y - 25.0) < 1e-9
        ), (
            "doc.pan.apply must be idempotent: re-issuing the same cursor "
            f"must not accumulate, got ({model.view_offset_x}, {model.view_offset_y})"
        )

    def test_escape_mid_pan_restores_initial_offset(self):
        tool = _hand_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        model.view_offset_x = 30.0
        model.view_offset_y = -10.0
        off_x0 = model.view_offset_x
        off_y0 = model.view_offset_y
        before_doc = _doc_json(model)

        # Begin the SAME pan proven to move the view in the drag case,
        # but press Escape BEFORE the next event. Escape's on_keydown
        # restores the pre-drag offset (initial_offx/offy) via
        # doc.zoom.set_full and sets mode back to idle.
        tool.on_press(ctx, 100.0, 100.0, False, False)
        tool.on_move(ctx, 160.0, 135.0, False, False, True)
        # Mid-pan the view IS shifted (90, 25) — same as the drag case.
        assert (
            abs(model.view_offset_x - 90.0) < 1e-9
            and abs(model.view_offset_y - 25.0) < 1e-9
        ), (
            "precondition: mid-pan offset must be the moved (90,25), got "
            f"({model.view_offset_x}, {model.view_offset_y})"
        )

        tool.on_key_event(ctx, "Escape", KeyMods())

        assert (
            abs(model.view_offset_x - off_x0) < 1e-9
            and abs(model.view_offset_y - off_y0) < 1e-9
        ), (
            f"Escape mid-pan must restore the initial offset ({off_x0}, "
            f"{off_y0}), got ({model.view_offset_x}, {model.view_offset_y})"
        )

        # A subsequent mousemove must NOT re-pan: Escape set mode=idle,
        # so the on_mousemove `mode == 'panning'` guard now fails.
        tool.on_move(ctx, 300.0, 300.0, False, False, True)
        assert (
            abs(model.view_offset_x - off_x0) < 1e-9
            and abs(model.view_offset_y - off_y0) < 1e-9
        ), (
            "after Escape (mode idle) a further move must not re-pan, got "
            f"({model.view_offset_x}, {model.view_offset_y})"
        )
        assert _doc_json(model) == before_doc, (
            "an escaped pan must not mutate the document"
        )
        assert not model.can_undo, "an escaped pan must leave no undo step"

    def test_mode_idle_panning_idle_lifecycle(self):
        tool = _hand_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)

        # on_enter resets to idle.
        tool.activate(ctx)
        assert _read_hand_mode(tool) == "idle", (
            "mode must start idle after activate"
        )

        # mousedown => panning.
        tool.on_press(ctx, 100.0, 100.0, False, False)
        assert _read_hand_mode(tool) == "panning", (
            "mousedown must enter panning"
        )

        # mouseup => idle.
        tool.on_release(ctx, 160.0, 135.0, False, False)
        assert _read_hand_mode(tool) == "idle", (
            "mouseup must return to idle"
        )


# ── Zoom ─────────────────────────────────────────────────────────────


class TestZoomParity:
    def test_plain_click_zooms_in_by_zoom_step(self):
        tool = _zoom_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        before_doc = _doc_json(model)
        step = _bundle_zoom_step()
        # Sanity: the bundle ships the documented 1.2 step.
        assert abs(step - 1.2) < 1e-9, (
            f"zoom.yaml/preferences must ship zoom_step 1.2, read {step}"
        )

        # Plain CLICK: press + release at the SAME screen point, no
        # intervening move => moved stays false => the not-moved branch
        # dispatches zoom_in anchored at the click.
        #   z_new   = 1.0 * 1.2 = 1.2
        #   anchor  = (200, 150) (screen)
        #   doc_a   = (200-0)/1, (150-0)/1 = (200, 150)
        #   off_new = anchor - doc_a*z_new = 200 - 200*1.2 = -40
        #                                    150 - 150*1.2 = -30
        tool.on_press(ctx, 200.0, 150.0, False, False)
        tool.on_release(ctx, 200.0, 150.0, False, False)

        expected_zoom = 1.0 * step  # 1.2
        assert abs(model.zoom_level - expected_zoom) < 1e-9, (
            f"a plain click must zoom IN to 1.0*{step} = {expected_zoom}, "
            f"got {model.zoom_level}"
        )
        assert (
            abs(model.view_offset_x - (-40.0)) < 1e-9
            and abs(model.view_offset_y - (-30.0)) < 1e-9
        ), (
            "click-zoom must recenter offset to (-40,-30) so screen "
            "(200,150) stays glued to its doc point, got "
            f"({model.view_offset_x}, {model.view_offset_y})"
        )
        # The clicked SCREEN point maps to the SAME doc point before and
        # after the zoom — the invariant the recenter exists to keep.
        doc_before = (200.0 - 0.0) / 1.0  # = 200
        doc_after = (200.0 - model.view_offset_x) / model.zoom_level
        assert abs(doc_after - doc_before) < 1e-9, (
            f"the clicked screen x must map to the same doc x (={doc_before}) "
            f"after the zoom, got {doc_after}"
        )
        assert _doc_json(model) == before_doc, (
            "a zoom click must not mutate the document"
        )
        assert not model.can_undo, "a view-only zoom must leave no undo step"

    def test_alt_click_zooms_out(self):
        tool = _zoom_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        before_doc = _doc_json(model)
        step = _bundle_zoom_step()

        # ALT-click (alt = the LAST bool arg of the seam). alt_at_press
        # latches true on mousedown, so the not-moved branch dispatches
        # zoom_OUT with factor 1/step.
        #   z_new   = 1.0 * (1/1.2) = 0.833333…
        #   anchor  = (200, 150)
        #   off_new = 200 - 200*z_new ; 150 - 150*z_new
        tool.on_press(ctx, 200.0, 150.0, False, True)
        tool.on_release(ctx, 200.0, 150.0, False, True)

        expected_zoom = 1.0 / step  # 0.83333…
        assert abs(model.zoom_level - expected_zoom) < 1e-9, (
            f"an Alt-click must zoom OUT to 1.0/{step} = {expected_zoom}, "
            f"got {model.zoom_level}"
        )
        assert model.zoom_level < 1.0, (
            f"Alt-click must DECREASE zoom below 1.0, got {model.zoom_level}"
        )
        expected_off_x = 200.0 - 200.0 * expected_zoom
        expected_off_y = 150.0 - 150.0 * expected_zoom
        assert (
            abs(model.view_offset_x - expected_off_x) < 1e-9
            and abs(model.view_offset_y - expected_off_y) < 1e-9
        ), (
            f"Alt-click recenter must put offset at ({expected_off_x}, "
            f"{expected_off_y}), got ({model.view_offset_x}, {model.view_offset_y})"
        )
        # Same screen->doc invariant under zoom-out.
        doc_after = (200.0 - model.view_offset_x) / model.zoom_level
        assert abs(doc_after - 200.0) < 1e-9, (
            "the clicked screen x must still map to doc 200 after zoom-out, "
            f"got {doc_after}"
        )
        assert _doc_json(model) == before_doc, (
            "an Alt zoom click must not mutate the document"
        )
        assert not model.can_undo, "a view-only zoom must leave no undo step"

    def test_escape_mid_scrubby_drag_restores_initial_view(self):
        tool = _zoom_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        # Non-identity starting view so the restore target is distinctive.
        model.zoom_level = 2.0
        model.view_offset_x = 15.0
        model.view_offset_y = 25.0
        z0 = model.zoom_level
        off_x0 = model.view_offset_x
        off_y0 = model.view_offset_y
        before_doc = _doc_json(model)

        # Scrubby is on by default in the bundle, so a horizontal drag
        # past the 4px threshold applies a continuous scrubby zoom on
        # each move. Press captures the initial snapshot; the move
        # (>4px in x) flips moved=true and writes a NEW zoom/offset.
        tool.on_press(ctx, 100.0, 100.0, False, False)
        tool.on_move(ctx, 180.0, 100.0, False, False, True)

        # Precondition: the scrubby move actually CHANGED the view (so
        # the Escape restore is non-vacuous).
        assert abs(model.zoom_level - z0) > 1e-6, (
            f"precondition: a >4px scrubby drag must change zoom from {z0}, "
            f"got {model.zoom_level}"
        )

        # Escape mid-drag: zoom.yaml restores the pre-drag snapshot
        # (initial_zoom/offx/offy) via doc.zoom.set_full and idles.
        tool.on_key_event(ctx, "Escape", KeyMods())

        assert (
            abs(model.zoom_level - z0) < 1e-9
            and abs(model.view_offset_x - off_x0) < 1e-9
            and abs(model.view_offset_y - off_y0) < 1e-9
        ), (
            f"Escape mid-scrubby must restore the pre-drag view (z={z0}, "
            f"off=({off_x0},{off_y0})), got (z={model.zoom_level}, "
            f"off=({model.view_offset_x},{model.view_offset_y}))"
        )

        # After Escape (mode idle) a further move must NOT re-zoom.
        tool.on_move(ctx, 300.0, 100.0, False, False, True)
        assert abs(model.zoom_level - z0) < 1e-9, (
            "after Escape (mode idle) a further move must not re-zoom, got "
            f"{model.zoom_level}"
        )
        assert _doc_json(model) == before_doc, (
            "an escaped zoom must not mutate the document"
        )
        assert not model.can_undo, "an escaped zoom must leave no undo step"

    def test_subthreshold_drag_is_a_click(self):
        # A press + tiny move (<=4px) + release is NOT a drag: moved
        # stays false, so mouseup takes the click branch and zooms IN
        # by zoom_step. Proves the 4px click-vs-drag threshold and that
        # scrubby did NOT fire on the sub-threshold move.
        tool = _zoom_yaml_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _viewport_model()
        ctx, _ = _ctx(model)
        step = _bundle_zoom_step()

        tool.on_press(ctx, 200.0, 150.0, False, False)
        # 3px in x, 0 in y — both within the >4px gate, so moved stays
        # false and no scrubby zoom is written on the move.
        tool.on_move(ctx, 203.0, 150.0, False, False, True)
        assert abs(model.zoom_level - 1.0) < 1e-9, (
            "a sub-threshold move must NOT scrubby-zoom; zoom must still be "
            f"1.0, got {model.zoom_level}"
        )

        tool.on_release(ctx, 203.0, 150.0, False, False)
        # Release takes the click branch => zoom IN by step. Anchor is
        # the RELEASE point (203,150): off_x = 203 - 203*1.2.
        assert abs(model.zoom_level - step) < 1e-9, (
            f"a sub-threshold gesture must commit as a click-zoom to {step}, "
            f"got {model.zoom_level}"
        )
        expected_off_x = 203.0 - 203.0 * step
        assert abs(model.view_offset_x - expected_off_x) < 1e-9, (
            "click-zoom anchor must be the release point (203): off_x = "
            f"{expected_off_x}, got {model.view_offset_x}"
        )
        assert not model.can_undo, "a view-only zoom must leave no undo step"
