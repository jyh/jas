"""Blob-brush-tool gesture-seam tests — Python port of the Rust blob-brush seam
tests in jas_dioxus/src/tools/yaml_tool.rs (the ``blob_brush_parity_*`` family).

These drive the production ``blob_brush`` tool loaded from the compiled
workspace bundle through the full gesture pipeline — on_press / on_move /
on_release / on_key_event — and assert the externally-observable outcomes
(committed Path, undo/redo, Escape-cancel, Alt-erase). They complement the
effect/primitive unit tests in yaml_tool_effects_test.py (which call
``doc.blob_brush.commit_painting`` / ``commit_erasing`` directly with a
PRE-SEEDED point buffer): the seam tests exercise mode latching on press
(Alt -> erasing), arc-length dab accumulation via doc.blob_brush.sweep_sample
on each move, and the commit on release.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_move(drag)       -> on_move(ctx, x, y, shift, alt, dragging)
    on_release          -> on_release(ctx, x, y, shift, alt)
    on_key_event(Esc)   -> on_key_event(ctx, "Escape", KeyMods())

The blob_brush commit reads APP-LEVEL state (state.blob_brush_size,
state.fill_color, ...) which is NOT part of the tool's own state defaults. The
YamlTool store is self-contained, so those values are seeded directly into the
tool's private store before driving the gesture — mirroring the
``_blob_brush_defaults`` seeding in yaml_tool_effects_test.py and the
``seed_blob_brush_app_state`` helper in the Rust reference.

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
from geometry.element import (
    ClosePath, Color, Fill, Layer, LineTo, MoveTo, Path,
)
from tools.tool import KeyMods, ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _blob_brush_tool() -> YamlTool | None:
    """Load the "blob_brush" spec from the compiled workspace bundle and build a
    YamlTool, mirroring the pencil-tool loader in yaml_tool_pencil_test.py."""
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
    spec = tools.get("blob_brush")
    return YamlTool.from_workspace_tool(spec) if spec else None


def _seed_blob_brush_app_state(tool: YamlTool) -> None:
    """Seed the app-level ``state.blob_brush_*`` + ``state.fill_color`` that the
    commit reads (tip shape, fill, fidelity, merge filter). The YamlTool store
    is self-contained, so these app-level values must be seeded directly — they
    are NOT part of the tool's own state defaults (mode / hover / alt_held).

    Mirrors ``_blob_brush_defaults`` in yaml_tool_effects_test.py and
    ``seed_blob_brush_app_state`` in the Rust reference (same keys/values)."""
    store = tool._store
    store.set("fill_color", "#ff0000")
    store.set("blob_brush_size", 10.0)
    store.set("blob_brush_angle", 0.0)
    store.set("blob_brush_roundness", 100.0)
    store.set("blob_brush_fidelity", 1.0)
    store.set("blob_brush_merge_only_with_selection", False)
    store.set("blob_brush_keep_selected", False)


def _empty_layer_model() -> Model:
    """A document with a single empty top-level layer — the empty-layer model
    the Rust port builds (committed paths land at layers[0].children[0])."""
    layer = Layer(name="L", children=())
    return Model(document=Document(layers=(layer,)))


def _model_with_square(x0: float, y0: float, x1: float, y1: float,
                       blob_origin: bool) -> Model:
    """Single-layer model holding one filled red square spanning
    (x0,y0)-(x1,y1). When ``blob_origin`` is true the square carries
    tool_origin="blob_brush" (an erase target); otherwise it has no tool-origin
    (an erase bystander). Mirrors ``model_with_square`` in the Rust reference."""
    square = Path(
        d=(MoveTo(x0, y0), LineTo(x1, y0), LineTo(x1, y1), LineTo(x0, y1),
           ClosePath()),
        fill=Fill(color=Color.from_hex("#ff0000")),
        tool_origin="blob_brush" if blob_origin else None,
    )
    layer = Layer(name="L", children=(square,))
    return Model(document=Document(layers=(layer,)))


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (the blob brush does no hit-testing). Mirrors the pencil
    seam-test harness ToolContext."""
    return ToolContext(
        model=model,
        controller=Controller(model=model),
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
    )


def _sweep(tool: YamlTool, ctx: ToolContext, x0: float, x1: float,
           alt: bool) -> None:
    """Drive a left-to-right paint (or erase, when ``alt`` is true) sweep along
    y=0 from x0 to x1 with a dab every 10pt — enough arc-length for sweep_sample
    to push a dab on each move (tip size 10 -> 1/2 min-dimension = 5pt
    threshold). press latches the mode (Alt -> erasing), release commits.

    Mirrors ``blob_brush_sweep`` in the Rust reference."""
    tool.on_press(ctx, x0, 0.0, False, alt)
    x = x0 + 10.0
    while x < x1:
        tool.on_move(ctx, x, 0.0, False, alt, True)
        x += 10.0
    tool.on_release(ctx, x1, 0.0, False, alt)


def _children(model: Model):
    return model.document.layers[0].children


class TestBlobBrushTool:
    # ── Loader sanity (non-vacuity guard) ──────────────────

    def test_blob_brush_tool_loads_from_workspace(self):
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "blob_brush"

    # ── 1. Paint commits one tagged, fill-only Path (BB-010/011) ─

    def test_paint_commits_tagged_path(self):
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _sweep(tool, ctx, 0.0, 50.0, False)

        children = _children(model)
        assert len(children) == 1, "paint commits exactly one Path"
        pe = children[0]
        assert isinstance(pe, Path), f"expected Path, got {type(pe).__name__}"
        assert pe.tool_origin == "blob_brush", (
            "committed path carries jas:tool-origin=blob_brush")
        assert pe.fill is not None, "blob path is filled"
        assert pe.stroke is None, "blob path has no stroke"
        # Closed swept region: MoveTo + LineTos + ClosePath.
        assert len(pe.d) >= 3, (
            "closed swept region needs MoveTo + LineTos + ClosePath")

    # ── 2. Undo / redo round-trips the blob (BB-016) ───────

    def test_undo_redo_round_trips(self):
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _sweep(tool, ctx, 0.0, 50.0, False)
        assert len(_children(model)) == 1, "paint commits one Path"

        model.undo()
        assert len(_children(model)) == 0, "undo removes the blob"

        model.redo()
        assert len(_children(model)) == 1, "redo restores the blob"

    # ── 3. Escape mid-drag cancels (BB-004) ────────────────

    def test_escape_during_drag_cancels(self):
        # Press + drag put the blob brush in mode='painting'. Delivering Escape
        # via the SAME key entry the canvas shell dispatches for a non-capturing
        # tool (on_key_event "Escape" -> on_keydown) flips mode to 'idle' and
        # clears the buffer. The subsequent on_release then takes neither the
        # painting nor the erasing commit branch (both guarded by mode), so the
        # document is left unchanged with zero children.
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        model = _empty_layer_model()
        ctx = _ctx(model)
        tool.on_press(ctx, 0.0, 0.0, False, False)
        tool.on_move(ctx, 20.0, 0.0, False, False, True)
        tool.on_move(ctx, 40.0, 0.0, False, False, True)
        # The canvas's actual Escape dispatch for a non-capturing tool.
        tool.on_key_event(ctx, "Escape", KeyMods())
        tool.on_release(ctx, 50.0, 0.0, False, False)

        assert len(_children(model)) == 0, (
            "Esc during drag cancels — no blob committed")

    # ── 4. Alt-erase removes a fully-covered blob (BB-100/101) ─

    def test_alt_erase_removes_covered_blob(self):
        # Alt-at-press latches erasing mode; the swept region boolean-subtracts
        # from overlapping blob-brush elements. A small blob square fully inside
        # the sweep is deleted.
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        # Square (23,-1)-(27,1): fully inside a 0..50 sweep, 10pt tip.
        model = _model_with_square(23.0, -1.0, 27.0, 1.0, blob_origin=True)
        ctx = _ctx(model)
        assert len(_children(model)) == 1

        _sweep(tool, ctx, 0.0, 50.0, True)  # alt = erase
        assert len(_children(model)) == 0, (
            "Alt-erase deletes a fully-covered blob-brush element")

    # ── 5. Alt-erase leaves a non-blob element (BB-104) ────

    def test_alt_erase_leaves_non_blob(self):
        # Erase only subtracts from elements tagged jas:tool-origin=blob_brush.
        # A bystander square without that tag is left untouched even when fully
        # under the sweep.
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        model = _model_with_square(23.0, -1.0, 27.0, 1.0, blob_origin=False)
        ctx = _ctx(model)

        _sweep(tool, ctx, 0.0, 50.0, True)  # alt = erase
        children = _children(model)
        assert len(children) == 1, (
            "erase must not touch non-blob-brush elements")
        pe = children[0]
        assert isinstance(pe, Path), f"expected Path, got {type(pe).__name__}"
        assert pe.tool_origin is None, "the untouched bystander has no origin"

    # ── 6. Overlapping same-fill paint merges (BB-070) ─────

    def test_overlapping_same_fill_merges(self):
        # A second paint overlapping an existing blob-brush element of the same
        # fill is unioned into it — the layer still holds exactly one Path.
        tool = _blob_brush_tool()
        if tool is None:
            pytest.skip("workspace.json not available")
        _seed_blob_brush_app_state(tool)
        model = _empty_layer_model()
        ctx = _ctx(model)
        _sweep(tool, ctx, 0.0, 50.0, False)
        assert len(_children(model)) == 1, "first paint commits one Path"

        # Second stroke (25..75) overlaps the first (0..50).
        _sweep(tool, ctx, 25.0, 75.0, False)
        assert len(_children(model)) == 1, (
            "overlapping same-fill paint merges into one Path")
