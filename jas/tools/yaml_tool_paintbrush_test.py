"""Paintbrush-tool gesture-seam tests — Python port of the Rust paintbrush seam
tests in jas_dioxus/src/tools/yaml_tool.rs (the ``paintbrush_parity_*`` family).

These drive the production ``paintbrush`` tool loaded from the compiled
workspace bundle through the full gesture pipeline — on_press / on_move /
on_release / on_key_event — and assert the externally-observable outcomes (the
committed smoothed Path, fill on/off, undo/redo, Escape-cancel). They complement
the effect/primitive unit tests (which call ``doc.add_path_from_buffer`` /
edit_start / commit directly with a PRE-SEEDED point buffer): the seam tests
exercise the FULL gesture pipeline AND the app-state bridge — fidelity ->
fit_error (smoothing) and fill_new_strokes -> fill both arrive only via the
bridge.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_move(drag)       -> on_move(ctx, x, y, shift, alt, dragging)
    on_release          -> on_release(ctx, x, y, shift, alt)
    on_key_event(Esc)   -> on_key_event(ctx, "Escape", KeyMods())

The paintbrush commit reads APP-LEVEL state (state.paintbrush_fidelity,
state.paintbrush_fill_new_strokes, state.fill_color, ...) which is NOT part of
the tool's own state defaults (mode / alt_held). The YamlTool store is
self-contained, so those values are seeded through the PRODUCTION bridge
(StateStore.seed_globals_from over BRIDGED_STATE_KEYS) before driving the
gesture — the same path the canvas uses (ToolContext.app_state in
YamlTool._dispatch), exactly as the blob-brush seam tests do. With
paintbrush_fidelity=3 the commit maps to fit_error=5.0 (a SMOOTHED fit:
MoveTo + CurveTos), not the degenerate fit_error=0 over-fit a null fidelity
would produce.

Committed paths land at ``layers[0].children[0]``.
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
from geometry.element import CurveTo, Layer, MoveTo, Path
from tools.tool import KeyMods, ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _paintbrush_tool() -> YamlTool | None:
    """Load the "paintbrush" spec from the compiled workspace bundle and build a
    YamlTool, mirroring the blob-brush loader in yaml_tool_blob_brush_test.py."""
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
    spec = tools.get("paintbrush")
    return YamlTool.from_workspace_tool(spec) if spec else None


def _seed_paintbrush_app_state(tool: YamlTool, fill_new: bool) -> None:
    """Seed the app-level state the paintbrush commit reads, through the
    PRODUCTION bridge (``StateStore.seed_globals_from``) — NOT a direct
    ``tool._store`` poke — so these seam tests exercise the same path the
    canvas uses (via ``ToolContext.app_state`` in ``YamlTool._dispatch``).

    fidelity=3 -> fit_error 5.0 (a smoothed fit); pass ``fill_new`` to
    exercise fill_new_strokes + fill_color. The fill (red) reaches the
    commit ONLY through this bridge — before it existed the live paintbrush
    used fit_error=0 (no smoothing) and dropped the fill. Mirrors
    ``seed_paintbrush_app_state`` in the Rust reference (same keys/values)."""
    from workspace_interpreter.state_store import StateStore
    from tools.yaml_tool import BRIDGED_STATE_KEYS

    app_state = StateStore({
        "fill_color": "#ff0000",
        "paintbrush_fidelity": 3,
        "paintbrush_fill_new_strokes": fill_new,
        "paintbrush_edit_within": 12,
        "paintbrush_edit_selected_paths": True,
        "paintbrush_keep_selected": True,
    })
    tool._store.seed_globals_from(app_state, BRIDGED_STATE_KEYS)


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust port builds (committed paths land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the paintbrush does no hit-testing in these cases).
    Mirrors the blob-brush seam-test harness ToolContext."""
    return ToolContext(
        model=model,
        controller=Controller(model=model),
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
    )


def _paintbrush_stroke(tool: YamlTool, ctx: ToolContext) -> None:
    """Drive a multi-point paintbrush zigzag: press -> moves -> release.
    Mirrors ``paintbrush_stroke`` in the Rust reference."""
    tool.on_press(ctx, 40.0, 60.0, False, False)
    tool.on_move(ctx, 60.0, 40.0, False, False, True)
    tool.on_move(ctx, 80.0, 60.0, False, False, True)
    tool.on_move(ctx, 100.0, 40.0, False, False, True)
    tool.on_release(ctx, 120.0, 60.0, False, False)


def _children(model: Model):
    return model.document.layers[0].children


class TestPaintbrushTool:
    # ── Loader sanity (non-vacuity guard) ──────────────────

    def test_paintbrush_tool_loads_from_workspace(self):
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "paintbrush"

    # ── 1. Paint commits ONE smoothed Path ─────────────────

    def test_paint_commits_smoothed_stroke(self):
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_paintbrush_app_state(tool, fill_new=False)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _paintbrush_stroke(tool, ctx)

        children = _children(model)
        assert len(children) == 1, "paint commits one Path"
        pe = children[0]
        assert isinstance(pe, Path), f"expected Path, got {type(pe).__name__}"
        assert pe.stroke is not None, "paintbrush path has a stroke"
        # fidelity=3 -> fit_error 5.0 (via the bridge): a SMOOTHED fit
        # (MoveTo + CurveTos), not the degenerate fit_error=0 over-fit that
        # a null fidelity would produce.
        assert isinstance(pe.d[0], MoveTo), "first command is MoveTo"
        assert len(pe.d) >= 2 and all(
            isinstance(c, CurveTo) for c in pe.d[1:]
        ), "smoothed: MoveTo + CurveTo(s)"

    # ── 2. fill_new_strokes=true fills the new Path (via bridge) ─

    def test_fill_new_strokes_fills_via_bridge(self):
        # The fill (red) reaches the commit ONLY through the app-state bridge
        # (fill_color), gated by fill_new_strokes=true. Before the bridge the
        # live tool dropped it (fill_new_strokes -> null -> false). This is the
        # paintbrush analogue of the blob fill bug.
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_paintbrush_app_state(tool, fill_new=True)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _paintbrush_stroke(tool, ctx)

        pe = _children(model)[0]
        assert isinstance(pe, Path), f"expected Path, got {type(pe).__name__}"
        assert pe.fill is not None, "fill_new_strokes=true fills the path"

    # ── 3. fill_new_strokes=false leaves the Path unfilled ─

    def test_no_fill_when_option_off(self):
        # fill_new_strokes=false (default) -> open freehand stroke, no fill.
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_paintbrush_app_state(tool, fill_new=False)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _paintbrush_stroke(tool, ctx)

        pe = _children(model)[0]
        assert isinstance(pe, Path), f"expected Path, got {type(pe).__name__}"
        assert pe.fill is None, "no fill when fill_new_strokes is off"

    # ── 4. Undo / redo round-trips the stroke ──────────────

    def test_undo_redo_round_trips(self):
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_paintbrush_app_state(tool, fill_new=False)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _paintbrush_stroke(tool, ctx)
        assert len(_children(model)) == 1, "paint commits one Path"

        model.undo()
        assert len(_children(model)) == 0, "undo removes the stroke"

        model.redo()
        assert len(_children(model)) == 1, "redo restores it"

    # ── 5. Escape mid-drag cancels (no commit) ─────────────

    def test_escape_during_drag_cancels(self):
        # Press + drag put the paintbrush in mode='drawing'. Delivering Escape
        # via the SAME key entry the canvas shell dispatches for a non-capturing
        # tool (on_key_event "Escape" -> on_keydown) flips mode to 'idle' and
        # clears the buffer. The subsequent on_release then takes neither the
        # drawing nor the edit commit branch (both guarded by mode), so the
        # document is left unchanged with zero children.
        tool = _paintbrush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_paintbrush_app_state(tool, fill_new=False)
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 40.0, 60.0, False, False)
        tool.on_move(ctx, 60.0, 40.0, False, False, True)
        # The canvas's actual Escape dispatch for a non-capturing tool.
        tool.on_key_event(ctx, "Escape", KeyMods())
        tool.on_release(ctx, 80.0, 60.0, False, False)

        assert len(_children(model)) == 0, (
            "Esc during drag cancels — no stroke committed")
