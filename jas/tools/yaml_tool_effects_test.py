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
