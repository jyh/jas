"""OP_LOG.md §9 — production-route proofs (Python jas app).

Mirrors Rust's ``production_route_*`` tests in
``jas_dioxus/src/interpreter/renderer.rs`` and Swift's
``ProductionRouteJournalTests``: prove that the PANEL / MENU production handlers
for the verb33 verbs journal a real op through the SHARED ``op_apply`` dispatcher
(the same path the tool gestures already use), instead of mutating the document
directly.

Each test drives the REAL Python production handler (the LayersPanel-equivalent
dispatch ``panel_menu._dispatch_yaml_layers_action`` — which builds the same
platform-effect registry a panel/menu gesture uses and owns + names + commits
the transaction — or the native menu Delete/Cut routing helper), then asserts:
  (1) the committed Transaction journals the expected verb op(s) with the
      RESOLVED params (the production eval -> literal path, NOT the YAML expr
      string) and the right targets;
  (2) the transaction carries the action name (``name_txn``);
  (3) ZERO behavior change: replaying the journal from the pre-edit document is
      byte-identical to the live document (checkpoint_equivalence), AND the live
      document is what the gesture produced;
  (4) the snapshot/undo bracket still works (one undo step round-trips).

These complement the operations-fixture proofs (``cross_language_test``), which
drive ``op_apply`` directly via the harness — here we prove the PRODUCTION
gesture reaches the same dispatcher.
"""

import copy
import unittest

from document.model import Model
from document.document import Document, ElementSelection
from document.op_apply import op_apply
from geometry.element import Layer, Group, Rect, Fill, Color, Visibility
from geometry.test_json import document_to_test_json


# ── shared helpers ──────────────────────────────────────────────────────────


def _sel(*paths):
    return frozenset(ElementSelection(path=p) for p in paths)


def _rect(eid=None, x=0.0):
    return Rect(x=x, y=0.0, width=10.0, height=10.0,
                fill=Fill(color=Color.rgb(1.0, 0.0, 0.0)), id=eid)


def _assert_checkpoint_equivalence(test, model: Model, pre_doc: Document):
    """Replay the whole committed journal onto a fresh Model seeded from
    ``pre_doc`` and byte-compare to the live document — the
    checkpoint_equivalence gate (OP_LOG.md §6)."""
    snapshot = document_to_test_json(model.document)
    replay = Model(document=pre_doc)
    for txn in model.journal[:model.journal_head]:
        for o in txn.ops:
            op_apply(replay, o.params)
    replayed = document_to_test_json(replay.document)
    test.assertEqual(replayed, snapshot,
                     "checkpoint_equivalence: journal replay == snapshot path")


def _dispatch(action_name, model, **kw):
    # Import lazily so a Qt-less environment still imports this module; the
    # dispatch path itself does not require a running Qt app.
    from panels.panel_menu import _dispatch_yaml_layers_action
    _dispatch_yaml_layers_action(action_name, model, **kw)


def _two_artboard_doc():
    from document.artboard import Artboard
    return Document(
        layers=(Layer(name="A", children=()),),
        artboards=(Artboard.default_with_id("ab1"),
                   Artboard.default_with_id("ab2")),
    )


# ── Structural tree (delete_at / insert_after / insert_at / wrap_in_layer /
#    wrap_in_group / unpack_group_at / delete_selection) ──────────────────────


class StructuralRouteTests(unittest.TestCase):

    def test_delete_at_journals_through_op_apply(self):
        # delete_layer_selection deletes the panel-selected element via doc.delete_at.
        doc = Document(layers=(
            Layer(name="L0", children=()),
            Layer(name="L1", children=()),
        ))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("delete_layer_selection", model, panel_selection=[(1,)])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "delete_layer_selection")
        del_ops = [o for o in txn.ops if o.op == "delete_at"]
        self.assertEqual(len(del_ops), 1, "exactly one delete_at op journaled")
        self.assertEqual(del_ops[0].params.get("path"), [1],
                         "the RESOLVED path literal, not the expr string")
        self.assertEqual(len(model.document.layers), 1)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers), 2)

    def test_insert_after_value_in_op(self):
        # duplicate_layer_selection: clone_at (binder, no op) -> insert_after
        # carrying the live Element verbatim (value-in-op).
        doc = Document(layers=(Layer(name="L0", children=()),))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("duplicate_layer_selection", model, panel_selection=[(0,)])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "duplicate_layer_selection")
        ins = [o for o in txn.ops if o.op == "insert_after"]
        self.assertEqual(len(ins), 1, "exactly one insert_after op journaled")
        # value-in-op: the element param is a LIVE Layer carried verbatim.
        self.assertIsInstance(ins[0].params.get("element"), Layer)
        self.assertEqual(ins[0].params.get("path"), [0])
        self.assertEqual(len(model.document.layers), 2)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers), 1)

    def test_insert_at_value_in_op(self):
        # new_layer: create_layer (binder, no op) -> insert_at carrying the
        # live Layer verbatim.
        doc = Document(layers=(Layer(name="L0", children=()),))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("new_layer", model)

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "new_layer")
        ins = [o for o in txn.ops if o.op == "insert_at"]
        self.assertEqual(len(ins), 1, "exactly one insert_at op journaled")
        self.assertIsInstance(ins[0].params.get("element"), Layer)
        self.assertEqual(ins[0].params.get("parent_path"), [])
        self.assertEqual(len(model.document.layers), 2)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers), 1)

    def test_wrap_in_layer_resolved_name_literal(self):
        # collect_in_new_layer wraps the selected top-level layers into a new
        # Layer; the name is journaled as a RESOLVED literal.
        doc = Document(layers=(
            Layer(name="L0", children=()),
            Layer(name="L1", children=()),
        ))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("collect_in_new_layer", model, panel_selection=[(0,), (1,)])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "collect_in_new_layer")
        wrap = [o for o in txn.ops if o.op == "wrap_in_layer"]
        self.assertEqual(len(wrap), 1)
        # paths are RESOLVED plain index arrays; name is a RESOLVED string literal.
        self.assertEqual(wrap[0].params.get("paths"), [[0], [1]])
        self.assertIsInstance(wrap[0].params.get("name"), str)
        _assert_checkpoint_equivalence(self, model, pre)
        n_after = len(model.document.layers)
        model.undo()
        self.assertEqual(len(model.document.layers), 2)
        self.assertNotEqual(n_after, 2)

    def test_wrap_in_group_routes_through_op_apply(self):
        # new_group wraps nested same-parent elements into a Group. (Parity fix:
        # Python previously lacked a doc.wrap_in_group handler entirely — it was
        # a silent no-op; routing it through op_apply makes it work AND journal.)
        doc = Document(layers=(
            Layer(name="L0", children=(_rect("r0", 0.0), _rect("r1", 20.0))),
        ))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("new_group", model, panel_selection=[(0, 0), (0, 1)])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "new_group")
        wrap = [o for o in txn.ops if o.op == "wrap_in_group"]
        self.assertEqual(len(wrap), 1)
        self.assertEqual(wrap[0].params.get("paths"), [[0, 0], [0, 1]])
        # A Group now wraps the two rects.
        self.assertIsInstance(model.document.layers[0].children[0], Group)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers[0].children), 2)
        self.assertNotIsInstance(model.document.layers[0].children[0], Group)

    def test_unpack_group_at_routes_through_op_apply(self):
        # flatten_artwork unpacks the selected group in place.
        grp = Group(children=(_rect("r0", 0.0), _rect("r1", 20.0)))
        doc = Document(layers=(Layer(name="L0", children=(grp,)),))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("flatten_artwork", model, panel_selection=[(0, 0)])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "flatten_artwork")
        unpack = [o for o in txn.ops if o.op == "unpack_group_at"]
        self.assertEqual(len(unpack), 1)
        self.assertEqual(unpack[0].params.get("path"), [0, 0])
        self.assertEqual(len(model.document.layers[0].children), 2)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertIsInstance(model.document.layers[0].children[0], Group)


# ── Artboard CRUD / reorder / field (7 verbs) ────────────────────────────────


class ArtboardRouteTests(unittest.TestCase):

    def test_create_artboard_mints_id_once_as_literal(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("new_artboard", model)

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "new_artboard")
        ops = [o for o in txn.ops if o.op == "create_artboard"]
        self.assertEqual(len(ops), 1)
        new_id = ops[0].params.get("id")
        self.assertIsInstance(new_id, str)
        self.assertTrue(new_id)
        # value-in-op: the journaled id is the one that actually landed.
        self.assertEqual(ops[0].targets, [new_id])
        self.assertEqual(len(model.document.artboards), 3)
        self.assertEqual(model.document.artboards[-1].id, new_id)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.artboards), 2)

    def test_duplicate_artboard_mints_new_id_once(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("duplicate_artboards", model,
                  artboards_panel_selection=["ab1"])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "duplicate_artboards")
        ops = [o for o in txn.ops if o.op == "duplicate_artboard"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0].params.get("id"), "ab1")
        new_id = ops[0].params.get("new_id")
        self.assertIsInstance(new_id, str)
        self.assertTrue(new_id and new_id != "ab1")
        self.assertEqual(len(model.document.artboards), 3)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.artboards), 2)

    def test_set_artboard_field_resolved_literal(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("confirm_artboard_rename", model,
                  artboards_panel_selection=["ab1"],
                  params={"artboard_id": "ab1", "new_name": "Renamed"})

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "confirm_artboard_rename")
        ops = [o for o in txn.ops if o.op == "set_artboard_field"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0].params.get("id"), "ab1")
        self.assertEqual(ops[0].params.get("field"), "name")
        self.assertEqual(ops[0].params.get("value"), "Renamed",
                         "the RESOLVED literal, not the expr string")
        self.assertEqual(ops[0].targets, ["ab1"])
        ab1 = next(a for a in model.document.artboards if a.id == "ab1")
        self.assertEqual(ab1.name, "Renamed")
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        ab1 = next(a for a in model.document.artboards if a.id == "ab1")
        self.assertNotEqual(ab1.name, "Renamed")

    def test_delete_artboard_by_id(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("delete_artboards", model,
                  artboards_panel_selection=["ab2"])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "delete_artboards")
        ops = [o for o in txn.ops if o.op == "delete_artboard_by_id"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0].params.get("id"), "ab2")
        self.assertEqual(ops[0].targets, ["ab2"])
        self.assertEqual(len(model.document.artboards), 1)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.artboards), 2)

    def test_move_artboards_down(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("move_artboard_down", model,
                  artboards_panel_selection=["ab1"])

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "move_artboard_down")
        ops = [o for o in txn.ops if o.op == "move_artboards_down"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0].params.get("ids"), ["ab1"])
        self.assertEqual([a.id for a in model.document.artboards], ["ab2", "ab1"])
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual([a.id for a in model.document.artboards], ["ab1", "ab2"])

    def test_set_artboard_options_field(self):
        model = Model(document=_two_artboard_doc())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)
        start = model.document.artboard_options.fade_region_outside_artboard

        _dispatch("artboard_options_confirm", model,
                  artboards_panel_selection=["ab1"],
                  params={"artboard_id": "ab1",
                          "name": "ab1name", "x": 0.0, "y": 0.0,
                          "width": 100.0, "height": 100.0, "fill": "white",
                          "show_center_mark": False, "show_cross_hairs": False,
                          "show_video_safe_areas": False,
                          "video_ruler_pixel_aspect_ratio": 1.0,
                          "fade_region_outside_artboard": (not start),
                          "update_while_dragging":
                              model.document.artboard_options.update_while_dragging})

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "artboard_options_confirm")
        opt_ops = [o for o in txn.ops if o.op == "set_artboard_options_field"]
        self.assertTrue(any(
            o.params.get("field") == "fade_region_outside_artboard"
            for o in opt_ops))
        _assert_checkpoint_equivalence(self, model, pre)


# ── Print-config setters (8 verbs) ───────────────────────────────────────────


class PrintConfigRouteTests(unittest.TestCase):

    def test_document_setup_field_resolved_literal(self):
        model = Model(document=Document(layers=(Layer(name="A", children=()),)))
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _dispatch("document_setup_confirm", model,
                  params={"bleed_top": 0.0, "bleed_right": 0.0,
                          "bleed_bottom": 0.0, "bleed_left": 0.0,
                          "bleed_uniform": True,
                          "show_images_outline": False,
                          "highlight_substituted_glyphs": False,
                          "grid_size": 42.0,
                          "grid_color": model.document.document_setup.grid_color,
                          "paper_color": model.document.document_setup.paper_color,
                          "simulate_colored_paper":
                              model.document.document_setup.simulate_colored_paper,
                          "transparency_flattener_preset":
                              model.document.document_setup
                              .transparency_flattener_preset.value,
                          "discard_white_overprint":
                              model.document.document_setup.discard_white_overprint})

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "document_setup_confirm")
        grid = [o for o in txn.ops
                if o.op == "set_document_setup_field"
                and o.params.get("field") == "grid_size"]
        self.assertEqual(len(grid), 1)
        self.assertEqual(grid[0].params.get("value"), 42.0,
                         "the RESOLVED numeric literal")
        self.assertEqual(grid[0].targets, [], "print-config ops carry no targets")
        self.assertEqual(model.document.document_setup.grid_size, 42.0)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(model.document.document_setup.grid_size,
                         pre.document_setup.grid_size)


# ── set_attr_on_selection (brush apply / remove) ─────────────────────────────


class BrushAttrRouteTests(unittest.TestCase):

    def _doc_with_selected_path(self):
        from geometry.element import Path, MoveTo, LineTo
        p = Path(d=(MoveTo(0.0, 0.0), LineTo(10.0, 10.0)), id="p0")
        doc = Document(layers=(Layer(name="L0", children=(p,)),),
                       selection=_sel((0, 0)))
        return doc

    def test_apply_brush_to_selection_journals(self):
        from tools.yaml_tool_effects import build as build_tool_effects
        from document.controller import Controller
        model = Model(document=self._doc_with_selected_path())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        # Drive the REAL tool-effect registry handler the same way the
        # apply_brush_to_selection action does (doc.snapshot opens; the batch
        # owner names + commits). Reuse the shared run_effects bracket.
        from workspace_interpreter.effects import run_effects
        from workspace_interpreter.state_store import StateStore
        effects = build_tool_effects(Controller(model=model))
        run_effects(
            [
                "doc.snapshot",
                {"doc.set_attr_on_selection":
                    {"attr": "stroke_brush", "value": "'art:charcoal'"}},
            ],
            {}, StateStore(), platform_effects=effects,
            model=model, action_name="apply_brush_to_selection")

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "apply_brush_to_selection")
        ops = [o for o in txn.ops if o.op == "set_attr_on_selection"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0].params.get("attr"), "stroke_brush")
        self.assertEqual(ops[0].params.get("value"), "art:charcoal",
                         "the RESOLVED literal value")
        self.assertEqual(ops[0].targets, ["p0"])
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        _assert_back = document_to_test_json(model.document)
        self.assertEqual(_assert_back, document_to_test_json(pre))


# ── Native menu Delete / Cut (no YAML action; native confirm) ─────────────────


class NativeDeleteCutRouteTests(unittest.TestCase):

    def _doc_with_two_selected(self):
        doc = Document(layers=(
            Layer(name="L0", children=(_rect("r0", 0.0), _rect("r1", 20.0))),
        ), selection=_sel((0, 0), (0, 1)))
        return doc

    def test_menu_delete_routes_through_op_apply(self):
        from menu.menu import _route_delete_selection
        model = Model(document=self._doc_with_two_selected())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _route_delete_selection(model, "delete_selection")

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "delete_selection")
        ops = [o for o in txn.ops if o.op == "delete_selection"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(sorted(ops[0].targets), ["r0", "r1"])
        self.assertEqual(len(model.document.layers[0].children), 0)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers[0].children), 2)

    def test_cut_delete_half_routes_through_op_apply(self):
        from menu.menu import _route_delete_selection
        model = Model(document=self._doc_with_two_selected())
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        _route_delete_selection(model, "cut_selection")

        self.assertEqual(len(model.journal), before + 1)
        txn = model.journal[-1]
        self.assertEqual(txn.name, "cut_selection")
        ops = [o for o in txn.ops if o.op == "delete_selection"]
        self.assertEqual(len(ops), 1)
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers[0].children), 2)


# ── Layers-panel in-tree keyboard Delete/Backspace (live tree_view) ──────────


class LayersPanelKeyboardDeleteRouteTests(unittest.TestCase):
    """The in-panel keyboard Delete/Backspace gesture in the live tree_view
    must journal through op_apply, exactly like the panel context-menu Delete
    (and like Rust's render_tree_view keydown -> dispatch_action and Swift's
    performDeleteSelection -> dispatchYamlAction). It used to mutate the
    document DIRECTLY (loop doc.delete_element + model.edit_document), journaling
    nothing. This drives the REAL renderer keyboard handler (_on_key ->
    _do_delete -> _dispatch_yaml_layers_action("delete_layer_selection") ->
    doc.delete_at -> op_apply) and asserts it journals a delete_at op, names the
    transaction, passes checkpoint_equivalence, and survives a one-step undo."""

    @classmethod
    def setUpClass(cls):
        from PySide6.QtWidgets import QApplication
        cls.app = QApplication.instance() or QApplication([])

    def _build_tree_view(self, model):
        from PySide6.QtWidgets import QMessageBox
        from workspace_interpreter.state_store import StateStore
        from panels.yaml_renderer import _render_tree_view
        ctx = {"_get_model": lambda: model}
        widget = _render_tree_view({}, StateStore(), ctx, dispatch_fn=None)
        return widget

    def _press_delete(self, widget):
        from PySide6.QtGui import QKeyEvent
        from PySide6.QtCore import Qt, QEvent
        ev = QKeyEvent(QEvent.KeyPress, Qt.Key_Delete, Qt.NoModifier)
        widget._jas_on_key(ev)

    def test_keyboard_delete_routes_through_op_apply(self):
        # Two top-level layers so deleting one does not trip the last-layer
        # guard; plain layers carry no references, so no orphan confirm fires.
        doc = Document(layers=(
            Layer(name="L0", children=()),
            Layer(name="L1", children=()),
        ))
        model = Model(document=doc)
        pre = copy.deepcopy(model.document)
        before = len(model.journal)

        widget = self._build_tree_view(model)
        # Drive the REAL in-panel selection state the keyboard handler reads.
        widget._jas_panel_selection.clear()
        widget._jas_panel_selection.add((1,))
        self._press_delete(widget)

        self.assertEqual(len(model.journal), before + 1,
                         "the keyboard Delete journaled exactly one transaction")
        txn = model.journal[-1]
        self.assertEqual(txn.name, "delete_layer_selection")
        del_ops = [o for o in txn.ops if o.op == "delete_at"]
        self.assertEqual(len(del_ops), 1, "exactly one delete_at op journaled")
        self.assertEqual(del_ops[0].params.get("path"), [1],
                         "the RESOLVED path literal, not the expr string")
        self.assertEqual(len(model.document.layers), 1)
        self.assertEqual(model.document.layers[0].name, "L0")
        _assert_checkpoint_equivalence(self, model, pre)
        model.undo()
        self.assertEqual(len(model.document.layers), 2)

    def test_keyboard_delete_last_layer_guard_no_journal(self):
        # Selecting the only top-level layer must NOT delete it (last-layer
        # guard) and must journal nothing — same guard as _do_delete.
        doc = Document(layers=(Layer(name="L0", children=()),))
        model = Model(document=doc)
        before = len(model.journal)

        widget = self._build_tree_view(model)
        widget._jas_panel_selection.clear()
        widget._jas_panel_selection.add((0,))
        self._press_delete(widget)

        self.assertEqual(len(model.journal), before,
                         "last-layer guard: no transaction journaled")
        self.assertEqual(len(model.document.layers), 1)


if __name__ == "__main__":
    unittest.main()
