"""Path-edit gesture-seam tests — Python port of the Rust path-edit seam tests
in jas_dioxus/src/tools/yaml_tool.rs (the ``path_eraser_parity_*`` and
``smooth_parity_*`` families).

These drive two production path-editing tools — ``path_eraser`` and
``smooth`` — loaded from the compiled workspace bundle through the full gesture
pipeline (on_press / on_release) and assert the externally-observable outcome:
the child count of the layer after an eraser split, the path-command count
after a smooth fit-curve simplification, and the no-op cases (miss / unselected)
that must leave the document untouched.

Neither tool reads app-level ``state.*`` — the path_eraser locates the hit path
directly off the live document, and smooth reads the document selection — so
there is no app-state seeding / bridge step. Under the identity view used here
doc coords == screen coords.

Seam mapping from Rust to this app (Python / PySide6):
    on_press            -> on_press(ctx, x, y, shift, alt)
    on_release          -> on_release(ctx, x, y, shift, alt)

The fixtures reproduce the Rust ``model_with_long_line_path`` and
``model_with_selected_zigzag_path`` EXACTLY (same MoveTo / LineTo coordinates
and the same SELECTED-vs-unselected document state), so the asserted numbers
match the Rust port:

  path_eraser:
    model_with_long_line_path -> single Path = MoveTo(0,0), LineTo(100,0) in
    one layer named "L", NO selection. A press+release at (50,0) — the line
    midpoint — splits the open path into 2 sub-paths; a press+release at
    (500,500) misses and leaves the single path unchanged.

  smooth:
    model_with_selected_zigzag_path -> single Path with MoveTo(0,0) followed by
    20 LineTo's stepping x = 5,10,...,100 with y alternating -5 / +5, in one
    layer named "L", with the path (path [0,0]) SELECTED. A smooth gesture at
    (50,0) reduces the command count via fit-curve simplification; an
    UNSELECTED copy is left untouched.

Element-type parity with Rust:
    every fixture is a single Element::Path  <-> geometry.element.Path
committed at ``layers[0].children[0]``.
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

import dataclasses

import pytest

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import (
    Color,
    Layer,
    LineTo,
    MoveTo,
    Path,
    Stroke,
)
from tools.tool import ToolContext
from tools.yaml_tool import YamlTool


# ── Loader + harness helpers ───────────────────────────────


def _path_edit_tool(tool_id: str) -> YamlTool | None:
    """Load ``tool_id``'s spec from the compiled workspace bundle and build a
    YamlTool, mirroring the loader in yaml_tool_anchor_test.py."""
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


def _ctx(model: Model) -> ToolContext:
    """A faithful headless ToolContext over a live document, with inert
    hit-test callbacks (these tools hit-test / read the document themselves).
    Mirrors the anchor seam-test harness ToolContext. The Controller shares the
    SAME Model instance so the effects' ``controller.model.begin_txn`` and
    ``model.can_undo`` observe one undo journal."""
    return ToolContext(
        model=model,
        controller=Controller(model=model),
        hit_test_selection=lambda x, y: False,
        hit_test_handle=lambda x, y: None,
        hit_test_text=lambda x, y: None,
        hit_test_path_curve=lambda x, y: None,
        request_update=lambda: None,
    )


def _children(model: Model):
    return model.document.layers[0].children


def _path(model: Model) -> Path:
    el = _children(model)[0]
    assert isinstance(el, Path), f"expected Path, got {type(el).__name__}"
    return el


# ── Fixtures (exact ports of the Rust model_* builders) ────


def _model_with_long_line_path() -> Model:
    """Port of Rust ``model_with_long_line_path``: a single Path =
    MoveTo(0,0), LineTo(100,0), fill=None, stroke=black/1.0, in one layer named
    "L", NO selection."""
    pe = Path(
        d=(
            MoveTo(0.0, 0.0),
            LineTo(100.0, 0.0),
        ),
        fill=None,
        stroke=Stroke(color=Color.BLACK, width=1.0),
    )
    return Model(document=Document(
        layers=(Layer(name="L", children=(pe,)),),
        selected_layer=0,
        selection=frozenset(),
    ))


def _model_with_selected_zigzag_path() -> Model:
    """Port of Rust ``model_with_selected_zigzag_path``: a single Path =
    MoveTo(0,0) followed by 20 LineTo's at x = i*5, y = +5 when i even else -5
    (i = 1..=20), fill=None, stroke=black/1.0, in one layer named "L". The path
    (path [0,0]) is SELECTED (.all) — selection matters for smooth."""
    cmds = [MoveTo(0.0, 0.0)]
    for i in range(1, 21):
        x = float(i) * 5.0
        y = 5.0 if i % 2 == 0 else -5.0
        cmds.append(LineTo(x, y))
    pe = Path(
        d=tuple(cmds),
        fill=None,
        stroke=Stroke(color=Color.BLACK, width=1.0),
    )
    return Model(document=Document(
        layers=(Layer(name="L", children=(pe,)),),
        selected_layer=0,
        selection=frozenset({ElementSelection.all((0, 0))}),
    ))


# ── Path Eraser tool ───────────────────────────────────────


class TestPathEraserTool:
    def test_path_eraser_tool_loads_from_workspace(self):
        tool = _path_edit_tool("path_eraser")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "path_eraser"

    def test_splits_open_path(self):
        # Port of path_eraser_parity_splits_open_path. A press+release in the
        # middle of the line at (50,0) splits the single open path into two
        # sub-paths — the layer goes from 1 child to 2 — and the cut is
        # undoable.
        tool = _path_edit_tool("path_eraser")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_long_line_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 0.0, False, False)

        children = _children(model)
        assert len(children) == 2, (
            "single line should split into 2 sub-paths")
        assert model.can_undo

    def test_miss_does_nothing(self):
        # Port of path_eraser_parity_miss_does_nothing. A press+release far
        # from the line at (500,500) leaves the layer's single path unchanged.
        tool = _path_edit_tool("path_eraser")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_long_line_path()
        ctx = _ctx(model)
        tool.on_press(ctx, 500.0, 500.0, False, False)
        tool.on_release(ctx, 500.0, 500.0, False, False)

        children = _children(model)
        assert len(children) == 1, (
            "miss should not change the path count")


# ── Smooth tool ────────────────────────────────────────────


class TestSmoothTool:
    def test_smooth_tool_loads_from_workspace(self):
        tool = _path_edit_tool("smooth")
        if tool is None:
            pytest.skip("workspace.json not available")
        assert tool.spec.id == "smooth"

    def test_reduces_commands_on_zigzag(self):
        # Port of smooth_parity_reduces_commands_on_zigzag. With the zigzag path
        # SELECTED, a smooth gesture at (50,0) — the midpoint of the zigzag —
        # reduces the path's command count via fit-curve simplification, and
        # the edit is undoable.
        tool = _path_edit_tool("smooth")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_selected_zigzag_path()
        original_len = len(_path(model).d)
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 0.0, False, False)

        new_len = len(_path(model).d)
        assert new_len < original_len, (
            "smooth should reduce command count on a zigzag "
            f"(was {original_len}, now {new_len})")
        assert model.can_undo

    def test_only_affects_selected_paths(self):
        # Port of smooth_parity_only_affects_selected_paths. The SAME zigzag
        # path but with the selection cleared — a smooth gesture at (50,0)
        # leaves the path's command count unchanged.
        base = _model_with_selected_zigzag_path()
        doc = dataclasses.replace(base.document, selection=frozenset())
        model = Model(document=doc)
        original_len = len(_path(model).d)
        tool = _path_edit_tool("smooth")
        if tool is None:
            pytest.skip("workspace.json not available")
        ctx = _ctx(model)
        tool.on_press(ctx, 50.0, 0.0, False, False)
        tool.on_release(ctx, 50.0, 0.0, False, False)

        new_len = len(_path(model).d)
        assert new_len == original_len, (
            "smooth on an unselected path should not change it")
