"""Phase 2 of the Python YAML tool-runtime migration.

Tests for :func:`yaml_tool_effects.build` — the doc.* selection-family
effects wired to a :class:`Controller`.
"""

from __future__ import annotations

import os
import sys

# Bootstrap sys.path so `tools.*` / `workspace_interpreter.*` resolve
# the same way they do when pytest loads the rest of the Python suite.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Element, Layer, Rect as RectElem
from tools import yaml_tool_effects
from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore


def _make_rect(x, y, w, h):
    return RectElem(x=x, y=y, width=w, height=h)


def _two_rect_model() -> Model:
    layer = Layer(name="L", children=(
        _make_rect(0.0, 0.0, 10.0, 10.0),
        _make_rect(50.0, 50.0, 10.0, 10.0),
    ))
    doc = Document(layers=(layer,))
    return Model(document=doc)


def _ctrl(model: Model) -> Controller:
    return Controller(model)


def _run(store, ctrl, effects_list, ctx=None):
    pe = yaml_tool_effects.build(ctrl)
    run_effects(effects_list, ctx or {}, store, platform_effects=pe)


# ── doc.snapshot ────────────────────────────────────────


class TestDocSnapshot:
    def test_pushes_undo(self):
        model = Model()
        ctrl = _ctrl(model)
        assert not model.can_undo
        store = StateStore()
        _run(store, ctrl, [{"doc.snapshot": None}])
        assert model.can_undo


# ── doc.clear_selection ─────────────────────────────────


class TestDocClearSelection:
    def test_empties_selection(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        ctrl.select_element((0, 0))
        assert len(model.document.selection) == 1
        store = StateStore()
        _run(store, ctrl, [{"doc.clear_selection": None}])
        assert len(model.document.selection) == 0


# ── doc.set_selection ───────────────────────────────────


class TestDocSetSelection:
    def test_from_paths(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        spec = {"paths": [[0, 0], [0, 1]]}
        _run(store, ctrl, [{"doc.set_selection": spec}])
        paths = {es.path for es in model.document.selection}
        assert (0, 0) in paths
        assert (0, 1) in paths

    def test_drops_invalid(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        spec = {"paths": [[0, 0], [99, 99]]}
        _run(store, ctrl, [{"doc.set_selection": spec}])
        paths = {es.path for es in model.document.selection}
        assert paths == {(0, 0)}


# ── doc.add_to_selection ────────────────────────────────


class TestDocAddToSelection:
    def test_adds(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{"doc.add_to_selection": [0, 0]}])
        assert any(es.path == (0, 0) for es in model.document.selection)

    def test_idempotent(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        ctrl.select_element((0, 0))
        before = len(model.document.selection)
        store = StateStore()
        _run(store, ctrl, [{"doc.add_to_selection": [0, 0]}])
        assert len(model.document.selection) == before

    def test_accepts_path_from_context(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        ctx = {"hit": {"__path__": [0, 0]}}
        _run(store, ctrl, [{"doc.add_to_selection": "hit"}], ctx=ctx)
        assert any(es.path == (0, 0) for es in model.document.selection)


# ── doc.toggle_selection ────────────────────────────────


class TestDocToggleSelection:
    def test_adds_when_absent(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{"doc.toggle_selection": [0, 0]}])
        assert any(es.path == (0, 0) for es in model.document.selection)

    def test_removes_when_present(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        ctrl.select_element((0, 0))
        store = StateStore()
        _run(store, ctrl, [{"doc.toggle_selection": [0, 0]}])
        assert not any(es.path == (0, 0) for es in model.document.selection)


# ── doc.translate_selection ─────────────────────────────


class TestDocTranslateSelection:
    def test_moves_selected(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        ctrl.select_element((0, 0))
        store = StateStore()
        _run(store, ctrl, [{
            "doc.translate_selection": {"dx": 5, "dy": 3},
        }])
        child = model.document.layers[0].children[0]
        assert isinstance(child, RectElem)
        assert child.x == 5.0 and child.y == 3.0


# ── doc.select_in_rect / doc.partial_select_in_rect ─────


class TestDocSelectInRect:
    def test_select_in_rect_hits_first_rect(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.select_in_rect": {
                "x1": -1, "y1": -1, "x2": 11, "y2": 11,
                "additive": False,
            },
        }])
        assert any(es.path == (0, 0) for es in model.document.selection)

    def test_partial_select_in_rect_hits_cps(self):
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.partial_select_in_rect": {
                "x1": -1, "y1": -1, "x2": 11, "y2": 11,
                "additive": False,
            },
        }])
        assert any(es.path == (0, 0) for es in model.document.selection)


# Blob Brush commit effects.


class TestBlobBrushCommit:
    @staticmethod
    def _seed_sweep():
        from workspace_interpreter import point_buffers
        point_buffers.clear("blob_brush")
        # 6 points spanning 50 pt horizontally at y=0.
        for i in range(6):
            point_buffers.push("blob_brush", float(i) * 10.0, 0.0)

    @staticmethod
    def _blob_brush_defaults(store):
        store.set("fill_color", "#ff0000")
        store.set("blob_brush_size", 10.0)
        store.set("blob_brush_angle", 0.0)
        store.set("blob_brush_roundness", 100.0)

    @staticmethod
    def _empty_layer_model():
        layer = Layer(name="L", children=())
        doc = Document(layers=(layer,))
        return Model(document=doc)

    def test_commit_painting_creates_tagged_path(self):
        from geometry.element import Path as PathElem
        model = self._empty_layer_model()
        ctrl = _ctrl(model)
        store = StateStore()
        self._blob_brush_defaults(store)
        self._seed_sweep()
        _run(store, ctrl, [{
            "doc.blob_brush.commit_painting": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0",
                "merge_only_with_selection": "false",
                "keep_selected": "false",
            },
        }])
        children = model.document.layers[0].children
        assert len(children) == 1
        pe = children[0]
        assert isinstance(pe, PathElem)
        assert pe.tool_origin == "blob_brush"
        assert pe.fill is not None
        assert pe.stroke is None
        # At least MoveTo + some LineTos + ClosePath.
        assert len(pe.d) >= 3

    def test_commit_erasing_deletes_fully_covered_element(self):
        from geometry.element import (ClosePath, Color, Fill, LineTo,
                                      MoveTo)
        from geometry.element import Path as PathElem
        # Small 4x2 blob-brush square fully inside sweep coverage
        # (sweep = 50pt horizontal, tip 10pt -> covers y in [-5, 5]).
        target = PathElem(
            d=(MoveTo(23.0, -1.0), LineTo(27.0, -1.0),
               LineTo(27.0, 1.0), LineTo(23.0, 1.0), ClosePath()),
            fill=Fill(color=Color.from_hex("#ff0000")),
            tool_origin="blob_brush",
        )
        layer = Layer(name="L", children=(target,))
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = _ctrl(model)
        store = StateStore()
        self._blob_brush_defaults(store)
        self._seed_sweep()
        _run(store, ctrl, [{
            "doc.blob_brush.commit_erasing": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0",
            },
        }])
        children = model.document.layers[0].children
        assert len(children) == 0, \
            "erasing should delete fully-covered element"

    def test_commit_erasing_ignores_non_blob_brush(self):
        from geometry.element import (ClosePath, Color, Fill, LineTo,
                                      MoveTo)
        from geometry.element import Path as PathElem
        # Same square but tool_origin = None -- erase must skip.
        target = PathElem(
            d=(MoveTo(20.0, -2.0), LineTo(30.0, -2.0),
               LineTo(30.0, 2.0), LineTo(20.0, 2.0), ClosePath()),
            fill=Fill(color=Color.from_hex("#ff0000")),
        )
        layer = Layer(name="L", children=(target,))
        doc = Document(layers=(layer,))
        model = Model(document=doc)
        ctrl = _ctrl(model)
        store = StateStore()
        self._blob_brush_defaults(store)
        self._seed_sweep()
        _run(store, ctrl, [{
            "doc.blob_brush.commit_erasing": {
                "buffer": "blob_brush",
                "fidelity_epsilon": "5.0",
            },
        }])
        children = model.document.layers[0].children
        assert len(children) == 1, \
            "erasing must not touch non-blob-brush elements"
