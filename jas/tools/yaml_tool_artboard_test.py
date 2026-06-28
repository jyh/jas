"""Artboard gesture-seam tests for the Python YAML tool runtime.

Ports the artboard-parity seam tests from the Rust reference
(jas_dioxus/src/tools/yaml_tool.rs, committed d1b8c911 — the
``artboard_parity_*`` cases). The Artboard tool is a pure state machine
that reads NO app-level ``state.*`` (no bridge seeding); it probes the
document, latches a hit, and on drag builds/moves/duplicates artboards.
We assert against the document's ARTBOARD LIST
(``model.document.artboards``) — each entry carries id/x/y/width/height.

Gestures are driven at the identity view (screen coords == doc coords)
through ``on_press`` / ``on_move`` / ``on_release``; the seam registers
the document so ``probe_hit`` resolves headlessly. All asserted artboard
rects and counts mirror the Rust reference exactly.

RESIZE is intentionally NOT covered here: the resize-handle path needs
``artboards_panel_selection_ids`` which the headless seam can't reach;
the resize math is pinned by a separate effect test
(``yaml_tool_effects_test.py``). Skipped the same way the Rust reference
skips it — not faked.
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

from document.artboard import Artboard
from document.controller import Controller
from document.document import Document
from document.model import Model
from geometry.element import Layer


# ── Shared machinery (mirrors yaml_tool_selection_variants_test.py) ──


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


# ── Fixture (mirrors Rust model_with_one_artboard) ──────────────────


def _model_with_one_artboard() -> Model:
    """A document with exactly ONE artboard "A" at (0,0) 200x200 and no
    document elements. Mirrors the Rust fixture: clear the seeded default
    artboard and push our own so the count + geometry assertions are
    unambiguous. Identity view → screen coords == doc coords."""
    a = Artboard(id="A", name="Artboard A", x=0.0, y=0.0,
                 width=200.0, height=200.0)
    layer = Layer(name="L", children=())
    m = Model(document=Document(layers=(layer,), artboards=(a,)))
    # Force the identity view (offset 0, zoom 1) the docstring assumes, so
    # gesture canvas coords == doc coords. The Model constructor auto-centers
    # the current artboard (non-zero view_offset); now that the artboard tool
    # correctly converts canvas->doc via event.doc_x, that centering offset
    # would otherwise shift every created/moved/duplicated artboard.
    m.view_offset_x = 0.0
    m.view_offset_y = 0.0
    m.zoom_level = 1.0
    return m


def _artboards(model: Model):
    return list(model.document.artboards)


def _artboard_a_rect(model: Model):
    """The single artboard's (x, y, w, h) — id "A". Raises if absent so a
    vanished artboard fails loudly instead of silently skipping."""
    a = next((ab for ab in model.document.artboards if ab.id == "A"), None)
    assert a is not None, "artboard A must still be present"
    return (a.x, a.y, a.width, a.height)


# ── Artboard-parity gesture tests ───────────────────────────────────


class TestArtboardGestures:
    def test_drag_empty_space_creates_artboard(self):
        tool = _load_ws_tool("artboard")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_one_artboard()
        ctx, _ = _ctx(model)
        tool.activate(ctx)
        assert len(_artboards(model)) == 1, "precondition: one artboard"

        # Press in EMPTY space at (300,300) — well clear of the 0..200
        # artboard — then drag to (450,420) (past the 4 px threshold) and
        # release. create_commit builds the rect from press → release:
        # x = min(300,450)=300, y = min(300,420)=300,
        # w = |300-450| = 150, h = |300-420| = 120.
        tool.on_press(ctx, 300.0, 300.0)
        tool.on_move(ctx, 450.0, 420.0, dragging=True)
        tool.on_release(ctx, 450.0, 420.0)

        abs_list = _artboards(model)
        assert len(abs_list) == 2, (
            "drag-to-create in empty space adds exactly one artboard, "
            f"got {len(abs_list)}"
        )
        created = next((ab for ab in abs_list if ab.id != "A"), None)
        assert created is not None, "the newly created artboard"
        assert (created.x, created.y, created.width, created.height) == (
            300.0, 300.0, 150.0, 120.0
        ), (
            "created artboard rect must equal the integer-rounded drag "
            "bounds (x300 y300 w150 h120), got "
            f"{(created.x, created.y, created.width, created.height)}"
        )
        assert _artboard_a_rect(model) == (0.0, 0.0, 200.0, 200.0), (
            "the pre-existing artboard A is untouched by a create gesture"
        )

    def test_drag_interior_moves_artboard(self):
        tool = _load_ws_tool("artboard")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_one_artboard()
        ctx, _ = _ctx(model)
        tool.activate(ctx)

        # Press INSIDE artboard A at (100,100) → moving_pending (probe_hit
        # latches hit_artboard_id = "A"). Drag by (+50,+30) to (150,130)
        # past threshold → moving + move_apply. Release → move_commit
        # (integer rounding). move_apply / move_commit fall back to
        # hit_artboard_id when panel-selection is empty, so the
        # single-artboard move works end-to-end through the seam.
        tool.on_press(ctx, 100.0, 100.0)
        tool.on_move(ctx, 150.0, 130.0, dragging=True)
        tool.on_release(ctx, 150.0, 130.0)

        assert len(_artboards(model)) == 1, (
            "a move must not change the artboard count"
        )
        assert _artboard_a_rect(model) == (50.0, 30.0, 200.0, 200.0), (
            "artboard A shifts by exactly the drag delta (+50,+30); size "
            f"unchanged, got {_artboard_a_rect(model)}"
        )

    def test_alt_drag_interior_duplicates_artboard(self):
        tool = _load_ws_tool("artboard")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_one_artboard()
        ctx, _ = _ctx(model)
        tool.activate(ctx)
        assert len(_artboards(model)) == 1, "precondition: one artboard"

        # ALT-press inside A at (100,100) → duplicating_pending. Drag by
        # (+60,+40) past threshold → duplicate_init mints the copy at A's
        # position and retargets translate ops at it, then
        # duplicate_apply / duplicate_commit translate the COPY. The
        # source A stays put; the copy lands at A + delta.
        tool.on_press(ctx, 100.0, 100.0, alt=True)
        tool.on_move(ctx, 160.0, 140.0, alt=True, dragging=True)
        tool.on_release(ctx, 160.0, 140.0, alt=True)

        abs_list = _artboards(model)
        assert len(abs_list) == 2, (
            f"alt-drag duplicates: count grows by exactly one, got {len(abs_list)}"
        )
        assert _artboard_a_rect(model) == (0.0, 0.0, 200.0, 200.0), (
            "the source artboard A stays at its origin during an alt-drag "
            f"duplicate, got {_artboard_a_rect(model)}"
        )
        copy = next((ab for ab in abs_list if ab.id != "A"), None)
        assert copy is not None, "the duplicate artboard"
        assert (copy.x, copy.y, copy.width, copy.height) == (
            60.0, 40.0, 200.0, 200.0
        ), (
            "the duplicate lands at A + drag delta with A's dimensions, got "
            f"{(copy.x, copy.y, copy.width, copy.height)}"
        )

    def test_press_release_no_drag_is_a_noop(self):
        tool = _load_ws_tool("artboard")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _model_with_one_artboard()
        ctx, _ = _ctx(model)
        tool.activate(ctx)

        # Snapshot the artboard list before the gesture for an exact
        # no-op proof.
        before = repr(model.document.artboards)

        # Press inside A then release with NO intervening move — a
        # sub-threshold click. `moved` stays false, so on_mouseup's
        # mode-guarded commit arms never fire: no move, no create, no
        # duplicate, no new artboard.
        tool.on_press(ctx, 100.0, 100.0)
        tool.on_release(ctx, 100.0, 100.0)

        assert len(_artboards(model)) == 1, (
            "a sub-threshold click must not add or remove an artboard"
        )
        assert repr(model.document.artboards) == before, (
            "a press+release with no drag leaves the artboard list "
            "byte-identical"
        )

        # Same for a press on EMPTY canvas with no drag — creating mode
        # is latched but the sub-threshold mouseup commits nothing.
        before_empty = repr(model.document.artboards)
        tool.on_press(ctx, 400.0, 400.0)
        tool.on_release(ctx, 400.0, 400.0)
        assert repr(model.document.artboards) == before_empty, (
            "a sub-threshold click on empty canvas creates nothing"
        )
