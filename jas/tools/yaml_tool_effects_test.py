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


# ── doc.magic_wand.apply ────────────────────────────────


class TestMagicWandApply:
    @staticmethod
    def _red_rect(x: float) -> RectElem:
        from geometry.element import Color, Fill
        return RectElem(x=x, y=0.0, width=10.0, height=10.0,
                        fill=Fill(color=Color.rgb(1.0, 0.0, 0.0)))

    @staticmethod
    def _blue_rect(x: float) -> RectElem:
        from geometry.element import Color, Fill
        return RectElem(x=x, y=0.0, width=10.0, height=10.0,
                        fill=Fill(color=Color.rgb(0.0, 0.0, 1.0)))

    @staticmethod
    def _three_rect_model() -> Model:
        layer = Layer(name="L", children=(
            TestMagicWandApply._red_rect(0.0),
            TestMagicWandApply._red_rect(50.0),
            TestMagicWandApply._blue_rect(100.0),
        ))
        return Model(document=Document(layers=(layer,)))

    @staticmethod
    def _set_defaults(store: StateStore) -> None:
        store.set("magic_wand_fill_color", True)
        store.set("magic_wand_fill_tolerance", 32.0)
        store.set("magic_wand_stroke_color", True)
        store.set("magic_wand_stroke_tolerance", 32.0)
        store.set("magic_wand_stroke_weight", True)
        store.set("magic_wand_stroke_weight_tolerance", 5.0)
        store.set("magic_wand_opacity", True)
        store.set("magic_wand_opacity_tolerance", 5.0)
        store.set("magic_wand_blending_mode", False)

    def test_replace_selects_all_red_rects(self):
        model = self._three_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        self._set_defaults(store)
        _run(store, ctrl, [{
            "doc.magic_wand.apply": {
                "seed": {"__path__": [0, 0]},
                "mode": "'replace'",
            },
        }])
        paths = {es.path for es in model.document.selection}
        assert paths == {(0, 0), (0, 1)}

    def test_add_extends_existing_selection(self):
        model = self._three_rect_model()
        ctrl = _ctrl(model)
        ctrl.set_selection(frozenset({ElementSelection.all((0, 2))}))
        store = StateStore()
        self._set_defaults(store)
        _run(store, ctrl, [{
            "doc.magic_wand.apply": {
                "seed": {"__path__": [0, 0]},
                "mode": "'add'",
            },
        }])
        paths = {es.path for es in model.document.selection}
        assert paths == {(0, 0), (0, 1), (0, 2)}

    def test_subtract_removes_matches_only(self):
        model = self._three_rect_model()
        ctrl = _ctrl(model)
        ctrl.set_selection(frozenset({
            ElementSelection.all((0, 0)),
            ElementSelection.all((0, 1)),
            ElementSelection.all((0, 2)),
        }))
        store = StateStore()
        self._set_defaults(store)
        _run(store, ctrl, [{
            "doc.magic_wand.apply": {
                "seed": {"__path__": [0, 0]},
                "mode": "'subtract'",
            },
        }])
        paths = {es.path for es in model.document.selection}
        assert paths == {(0, 2)}

    def test_skips_locked_and_hidden_elements(self):
        from geometry.element import Visibility
        from dataclasses import replace as _replace
        layer = Layer(name="L", children=(
            self._red_rect(0.0),
            _replace(self._red_rect(50.0), locked=True),
            _replace(self._red_rect(100.0), visibility=Visibility.INVISIBLE),
        ))
        model = Model(document=Document(layers=(layer,)))
        ctrl = _ctrl(model)
        store = StateStore()
        self._set_defaults(store)
        _run(store, ctrl, [{
            "doc.magic_wand.apply": {
                "seed": {"__path__": [0, 0]},
                "mode": "'replace'",
            },
        }])
        paths = {es.path for es in model.document.selection}
        assert paths == {(0, 0)}


# ── doc.artboard.* effects (ARTBOARD_TOOL.md) ───────────────


def _artboard_model(artboards):
    from document.artboard import ArtboardOptions
    layer = Layer(name="L", children=())
    doc = Document(layers=(layer,), artboards=tuple(artboards),
                   artboard_options=ArtboardOptions())
    return Model(document=doc)


class TestDocArtboardCreateCommit:
    def test_appends_with_rounded_bounds(self):
        from document.artboard import Artboard
        seed = Artboard(id="seed00001", name="Artboard 1")
        model = _artboard_model([seed])
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.artboard.create_commit": {
                "x1": "10", "y1": "20", "x2": "110", "y2": "120"
            }
        }])
        assert len(model.document.artboards) == 2
        new_ab = model.document.artboards[1]
        assert new_ab.x == 10.0
        assert new_ab.y == 20.0
        assert new_ab.width == 100.0
        assert new_ab.height == 100.0
        assert new_ab.name == "Artboard 2"

    def test_clamps_at_min(self):
        from document.artboard import Artboard
        seed = Artboard(id="seed00001", name="Artboard 1")
        model = _artboard_model([seed])
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.artboard.create_commit": {
                "x1": "50", "y1": "50", "x2": "50.4", "y2": "50.4"
            }
        }])
        new_ab = model.document.artboards[1]
        assert new_ab.width == 1.0
        assert new_ab.height == 1.0


class TestDocArtboardProbeHit:
    def test_interior_sets_tool_state(self):
        # Probe_hit on an artboard interior sets tool state. The
        # panel-selection write also happens but verifying it
        # requires the renderer's active_document scope plumbing —
        # covered by the manual test suite §Session B.
        from document.artboard import Artboard
        ab = Artboard(id="aaa00001", name="Artboard 1",
                      x=0.0, y=0.0, width=100.0, height=100.0)
        model = _artboard_model([ab])
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.artboard.probe_hit": {
                "x": "50", "y": "50",
                "shift": "false", "cmd": "false", "alt": "false",
            }
        }])
        ctx = store.eval_context()
        ab_state = ctx.get("tool", {}).get("artboard", {})
        assert ab_state.get("mode") == "moving_pending"
        assert ab_state.get("hit_artboard_id") == "aaa00001"

    def test_empty_canvas_sets_creating(self):
        from document.artboard import Artboard
        ab = Artboard(id="aaa00001", name="Artboard 1",
                      x=0.0, y=0.0, width=100.0, height=100.0)
        model = _artboard_model([ab])
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.artboard.probe_hit": {
                "x": "999", "y": "999",
                "shift": "false", "cmd": "false", "alt": "false",
            }
        }])
        ab_state = store.eval_context().get("tool", {}).get("artboard", {})
        assert ab_state.get("mode") == "creating"


class TestDocArtboardProbeHover:
    def test_classifies_position(self):
        from document.artboard import Artboard
        ab = Artboard(id="aaa00001", name="Artboard 1",
                      x=0.0, y=0.0, width=100.0, height=100.0)
        model = _artboard_model([ab])
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.artboard.probe_hover": {"x": "50", "y": "50"}
        }])
        ab_state = store.eval_context().get("tool", {}).get("artboard", {})
        assert ab_state.get("hover_kind") == "interior"
        _run(store, ctrl, [{
            "doc.artboard.probe_hover": {"x": "999", "y": "999"}
        }])
        ab_state = store.eval_context().get("tool", {}).get("artboard", {})
        assert ab_state.get("hover_kind") == "empty"


class TestDocArtboardMoveApply:
    def test_translates_via_hit_fallback(self):
        # No panel-selection set; move_apply falls back to
        # tool.artboard.hit_artboard_id (set by probe_hit).
        from document.artboard import Artboard
        ab = Artboard(id="aaa00001", name="Artboard 1",
                      x=100.0, y=100.0, width=200.0, height=200.0)
        model = _artboard_model([ab])
        model.capture_preview_snapshot()
        ctrl = _ctrl(model)
        store = StateStore()
        store.set_tool("artboard", "hit_artboard_id", "aaa00001")
        _run(store, ctrl, [{
            "doc.artboard.move_apply": {
                "press_x": "100", "press_y": "100",
                "cursor_x": "150", "cursor_y": "70",
                "shift_held": "false",
            }
        }])
        result = model.document.artboards[0]
        assert result.x == 150.0
        assert result.y == 70.0

    def test_shift_constrains_to_dominant_axis(self):
        from document.artboard import Artboard
        ab = Artboard(id="aaa00001", name="Artboard 1",
                      x=100.0, y=100.0, width=200.0, height=200.0)
        model = _artboard_model([ab])
        model.capture_preview_snapshot()
        ctrl = _ctrl(model)
        store = StateStore()
        store.set_tool("artboard", "hit_artboard_id", "aaa00001")
        # dx=80 > dy=30 → Y locked.
        _run(store, ctrl, [{
            "doc.artboard.move_apply": {
                "press_x": "100", "press_y": "100",
                "cursor_x": "180", "cursor_y": "130",
                "shift_held": "true",
            }
        }])
        result = model.document.artboards[0]
        assert result.x == 180.0
        assert result.y == 100.0  # locked


# ── Partial Selection control-point selection (SEL-100/103/105/106) ──
#
# CP-LEVEL selection through the Partial Selection effects. _two_rect_model's
# first rect (0,0,10,10) exposes four control points at its corners:
# cp0=(0,0), cp1=(10,0), cp2=(10,10), cp3=(0,10) (element.control_points).
# `doc.path.probe_partial_hit` selects the CP under the cursor (or
# shift-toggles it into the per-element partial set);
# `doc.path.commit_partial_marquee` selects every CP inside the rubber-band
# rect. These assert the CP-level SelectionKind (.partial carrying the
# enclosed indices), not just which element is touched. The second rect lives
# at path (0, 1) and must stay untouched.
#
# These use the PRODUCTION effects (doc.path.probe_partial_hit /
# doc.path.commit_partial_marquee, matching
# workspace/tools/partial_selection.yaml), NOT the legacy
# doc.partial_select_in_rect.

from document.document import (selection_kind_contains,  # noqa: E402
                               selection_kind_count,
                               selection_kind_is_all)


def _sel_entry(model, path):
    """Fetch the per-element selection entry at `path`, or None."""
    for es in model.document.selection:
        if es.path == path:
            return es
    return None


def _sel_kind(model, path):
    """Kind of the entry at `path`, or fail."""
    es = _sel_entry(model, path)
    assert es is not None, "expected selection entry at path"
    return es.kind


class TestPartialSelectionCp:
    def test_cp_click_selects_single_control_point(self):
        # SEL-100: clicking a single CP selects exactly that CP (a partial
        # selection of one), not the whole element.
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {"x": 0, "y": 0, "hit_radius": 8},
        }])
        assert _sel_entry(model, (0, 0)) is not None
        kind = _sel_kind(model, (0, 0))
        assert selection_kind_contains(kind, 0)            # cp0 = (0,0)
        assert selection_kind_count(kind, total=4) == 1    # exactly one CP …
        assert not selection_kind_is_all(kind, total=4)    # … not whole element
        assert store.get_tool("partial_selection", "mode") == "moving_pending"
        assert _sel_entry(model, (0, 1)) is None

    def test_shift_click_adds_and_toggles_control_points(self):
        # SEL-103/104: shift-click ADDS CPs to the per-element partial set,
        # and shift-clicking a selected CP toggles it OFF.
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Plain click cp0.
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {"x": 0, "y": 0, "hit_radius": 8},
        }])
        assert selection_kind_count(_sel_kind(model, (0, 0)), total=4) == 1
        # Shift-click cp1 = (10,0): ADDS it -> two CPs on the same element.
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {
                "x": 10, "y": 0, "hit_radius": 8, "shift": True,
            },
        }])
        two = _sel_kind(model, (0, 0))
        assert selection_kind_count(two, total=4) == 2
        assert selection_kind_contains(two, 0)
        assert selection_kind_contains(two, 1)
        # Shift-click cp1 AGAIN: toggles it OFF -> back to just cp0.
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {
                "x": 10, "y": 0, "hit_radius": 8, "shift": True,
            },
        }])
        one = _sel_kind(model, (0, 0))
        assert selection_kind_count(one, total=4) == 1
        assert selection_kind_contains(one, 0)
        assert not selection_kind_contains(one, 1)

    def test_marquee_selects_only_enclosed_control_point(self):
        # SEL-105: a marquee enclosing only one corner selects exactly that
        # one CP (proving CP-level, not whole-element, marquee granularity).
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Rect (-5,-5)..(5,5) encloses cp0=(0,0) only; the others are at
        # x or y = 10.
        _run(store, ctrl, [{
            "doc.path.commit_partial_marquee": {
                "x1": -5, "y1": -5, "x2": 5, "y2": 5,
            },
        }])
        assert _sel_entry(model, (0, 0)) is not None
        kind = _sel_kind(model, (0, 0))
        assert selection_kind_contains(kind, 0)
        assert selection_kind_count(kind, total=4) == 1
        assert not selection_kind_is_all(kind, total=4)
        assert _sel_entry(model, (0, 1)) is None

    def test_marquee_selects_all_enclosed_control_points(self):
        # SEL-105: a marquee enclosing all four corners selects every CP of
        # the element, and leaves the out-of-rect element untouched.
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Rect (-5,-5)..(15,15) encloses all four corners of rect[0,0];
        # rect[0,1] lives at (50,50) and is fully outside.
        _run(store, ctrl, [{
            "doc.path.commit_partial_marquee": {
                "x1": -5, "y1": -5, "x2": 15, "y2": 15,
            },
        }])
        assert _sel_entry(model, (0, 0)) is not None
        kind = _sel_kind(model, (0, 0))
        assert selection_kind_count(kind, total=4) == 4
        assert selection_kind_is_all(kind, total=4)
        assert _sel_entry(model, (0, 1)) is None

    def test_empty_marquee_clears_selection(self):
        # SEL-106: an empty (zero-size) marquee with no shift clears the CP
        # selection.
        model = _two_rect_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Select a CP first.
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {"x": 0, "y": 0, "hit_radius": 8},
        }])
        assert len(model.document.selection) != 0
        # A zero-size marquee (rw,rh <= 1), non-additive, clears the
        # selection.
        _run(store, ctrl, [{
            "doc.path.commit_partial_marquee": {
                "x1": 100, "y1": 100, "x2": 100, "y2": 100,
            },
        }])
        assert len(model.document.selection) == 0


# ── Partial Selection control-point DRAG (SEL-130 CP translate) ──
#
# Dragging a selected control point is `doc.translate_selection` over a
# PARTIAL selection: the move calls element.move_control_points on the kind,
# so ONLY the selected CPs move. A rect's corners are not independently
# movable, so these use a triangle Path whose anchors are cp0=(0,0),
# cp1=(100,0), cp2=(50,100) (element.control_points == path anchor points).


def _make_path_element(d):
    from geometry.element import Path as PathElem
    from geometry.element import Color, Stroke
    return PathElem(d=d,
                    stroke=Stroke(color=Color.rgb(0.0, 0.0, 0.0), width=1.0))


def _path_children_model(d):
    layer = Layer(name="L", children=(_make_path_element(d),))
    doc = Document(layers=(layer,))
    return Model(document=doc)


def _triangle_path_model():
    from geometry.element import ClosePath, LineTo, MoveTo
    return _path_children_model((
        MoveTo(0.0, 0.0), LineTo(100.0, 0.0),
        LineTo(50.0, 100.0), ClosePath(),
    ))


def _cps_of(model):
    """Control-point positions of the single path child."""
    from geometry.element import control_points
    return control_points(model.document.layers[0].children[0])


def _cp_eq(a, x, y):
    return abs(a[0] - x) < 1e-9 and abs(a[1] - y) < 1e-9


class TestPartialSelectionCpDrag:
    def test_cp_drag_translates_only_selected_control_point(self):
        # SEL-130: dragging a single selected CP translates ONLY that anchor;
        # the other anchors of the same path stay put.
        model = _triangle_path_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Select anchor 0 = (0,0).
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {"x": 0, "y": 0, "hit_radius": 8},
        }])
        assert selection_kind_contains(_sel_kind(model, (0, 0)), 0)
        # Drag that CP by (+20, +30).
        _run(store, ctrl, [{
            "doc.translate_selection": {"dx": 20, "dy": 30},
        }])
        cps = _cps_of(model)
        assert len(cps) == 3
        assert _cp_eq(cps[0], 20.0, 30.0)     # anchor 0 moved …
        assert _cp_eq(cps[1], 100.0, 0.0)     # … anchor 1 unchanged
        assert _cp_eq(cps[2], 50.0, 100.0)    # … anchor 2 unchanged
        # Selection preserved (still the same single CP).
        assert selection_kind_count(_sel_kind(model, (0, 0)), total=3) == 1

    def test_cp_drag_translates_all_selected_control_points(self):
        # SEL-130: dragging a multi-CP selection translates EVERY selected
        # anchor by the same delta and leaves the unselected anchor put.
        model = _triangle_path_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # Select anchor 0 = (0,0), then shift-add anchor 2 = (50,100).
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {"x": 0, "y": 0, "hit_radius": 8},
        }])
        _run(store, ctrl, [{
            "doc.path.probe_partial_hit": {
                "x": 50, "y": 100, "hit_radius": 8, "shift": True,
            },
        }])
        assert selection_kind_count(_sel_kind(model, (0, 0)), total=3) == 2
        # Drag the pair by (+10, -10).
        _run(store, ctrl, [{
            "doc.translate_selection": {"dx": 10, "dy": -10},
        }])
        cps = _cps_of(model)
        assert _cp_eq(cps[0], 10.0, -10.0)    # anchor 0 moved
        assert _cp_eq(cps[1], 100.0, 0.0)     # anchor 1 not selected
        assert _cp_eq(cps[2], 60.0, 90.0)     # anchor 2 moved


# ── Partial Selection Bezier HANDLE drag (SEL-131 / SEL-306) ──
#
# Dragging a Bezier HANDLE (not the anchor) of a SMOOTH path anchor is
# `doc.move_path_handle`. The effect reads the latched handle target from
# partial_selection tool state — handle_path (encoded element path as
# {"__path__": [..]}), handle_anchor_idx, handle_type ("in"|"out") — and
# applies (dx,dy) to the named handle. The opposite handle is then rotated to
# stay COLLINEAR through the anchor while keeping its OWN distance
# (smooth-point semantics), and the anchor stays put.
#
# Handle drags need a CURVED Path: a smooth middle anchor whose in- and
# out-handles are collinear-through-the-anchor and equidistant, so the
# reflection is an exact point-reflection (clean integer assertions).
#
# Fixture — a two-segment cubic path:
#   MoveTo(0,100)                                     anchor 0 = (0,100)
#   CurveTo(20,100, 80,100, 100,100)   anchor 1 = (100,100), in-handle (80,100)
#   CurveTo(120,100, 180,100, 200,100) anchor 2 = (200,100), out-handle of
#                                      anchor 1 = (120,100)
# Anchor 1 is the SMOOTH anchor under test: in-handle (80,100) and out-handle
# (120,100) sit on opposite sides of the anchor, both 20 units away — a true
# smooth point. (path_handle_positions returns (in, out) for an anchor index.)


def _smooth_curve_path_model():
    from geometry.element import CurveTo, MoveTo
    return _path_children_model((
        MoveTo(0.0, 100.0),
        CurveTo(20.0, 100.0, 80.0, 100.0, 100.0, 100.0),
        CurveTo(120.0, 100.0, 180.0, 100.0, 200.0, 100.0),
    ))


def _path_d_of(model):
    from geometry.element import Path as PathElem
    elem = model.document.layers[0].children[0]
    assert isinstance(elem, PathElem)
    return elem.d


def _anchor_pos(d, anchor_idx):
    # Anchor (end-point) position of a path command, for asserting the anchor
    # stays put. Mirrors the anchor read in path_handle_positions.
    from geometry.element import ClosePath, CurveTo, LineTo, MoveTo
    cmd_indices = [ci for ci, cmd in enumerate(d)
                   if not isinstance(cmd, ClosePath)]
    cmd = d[cmd_indices[anchor_idx]]
    if isinstance(cmd, (MoveTo, LineTo)):
        return (cmd.x, cmd.y)
    if isinstance(cmd, CurveTo):
        return (cmd.x, cmd.y)
    raise AssertionError("anchor command has no end point")


def _opt_eq(o, x, y):
    return o is not None and _cp_eq(o, x, y)


class TestPartialSelectionHandle:
    def test_handle_drag_out_mirrors_opposite_in_handle(self):
        # SEL-131/306: dragging the OUT handle of a smooth anchor moves that
        # handle by (dx,dy); the opposite IN handle is reflected through the
        # anchor (mirror / smooth-point behavior), and the anchor itself does
        # not move.
        #
        #   anchor 1 = (100,100) before and after — stays put.
        #   out-handle (120,100) --[drag (-20,+20)]--> (100,120)  moved
        #   in-handle  (80,100)  --[MIRRORED]--------> (100, 80)  reflected
        #       through the anchor: 2*anchor - new_out
        #       = (200,200)-(100,120) = (100,80).
        from geometry.element import path_handle_positions
        model = _smooth_curve_path_model()
        ctrl = _ctrl(model)
        store = StateStore()
        # BEFORE: confirm the smooth-point fixture.
        d0 = _path_d_of(model)
        in0, out0 = path_handle_positions(d0, 1)
        assert _opt_eq(in0, 80.0, 100.0)     # in-handle  (80,100)
        assert _opt_eq(out0, 120.0, 100.0)   # out-handle (120,100)
        assert _cp_eq(_anchor_pos(d0, 1), 100.0, 100.0)  # anchor (100,100)
        # Latch the handle target the way probe_partial_hit would: anchor 1's
        # OUT handle on element (0,0).
        store.set_tool("partial_selection", "handle_path",
                       {"__path__": [0, 0]})
        store.set_tool("partial_selection", "handle_anchor_idx", 1)
        store.set_tool("partial_selection", "handle_type", "out")
        # Drag the OUT handle by (dx=-20, dy=+20): (120,100) -> (100,120).
        _run(store, ctrl, [{
            "doc.move_path_handle": {"dx": -20, "dy": 20},
        }])
        # AFTER.
        d1 = _path_d_of(model)
        in1, out1 = path_handle_positions(d1, 1)
        assert _opt_eq(out1, 100.0, 120.0)   # dragged handle moved by (dx,dy)
        assert _opt_eq(in1, 100.0, 80.0)     # opposite handle MIRRORED
        assert _cp_eq(_anchor_pos(d1, 1), 100.0, 100.0)  # anchor unmoved
        assert _cp_eq(_anchor_pos(d1, 0), 0.0, 100.0)    # others untouched
        assert _cp_eq(_anchor_pos(d1, 2), 200.0, 100.0)

    def test_handle_drag_in_mirrors_opposite_out_handle(self):
        # SEL-131/306 (symmetric case): dragging the IN handle mirrors the OUT
        # handle. Drag the in-handle (80,100) by (dx=+20, dy=+20) -> (100,120);
        # the out-handle reflects through the anchor to (100,80) =
        # 2*(100,100)-(100,120).
        from geometry.element import path_handle_positions
        model = _smooth_curve_path_model()
        ctrl = _ctrl(model)
        store = StateStore()
        store.set_tool("partial_selection", "handle_path",
                       {"__path__": [0, 0]})
        store.set_tool("partial_selection", "handle_anchor_idx", 1)
        store.set_tool("partial_selection", "handle_type", "in")
        # Drag the IN handle by (dx=+20, dy=+20): (80,100) -> (100,120).
        _run(store, ctrl, [{
            "doc.move_path_handle": {"dx": 20, "dy": 20},
        }])
        d1 = _path_d_of(model)
        in1, out1 = path_handle_positions(d1, 1)
        assert _opt_eq(in1, 100.0, 120.0)    # dragged in-handle
        assert _opt_eq(out1, 100.0, 80.0)    # MIRRORED out-handle
        assert _cp_eq(_anchor_pos(d1, 1), 100.0, 100.0)  # anchor put
