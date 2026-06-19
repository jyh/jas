"""Cross-language equivalence tests.

These tests read shared SVG fixtures from test_fixtures/ at the
repository root, parse them, serialize to canonical test JSON, and
compare against the expected JSON files.
"""

import json
import os
from absl.testing import absltest

from algorithms.hit_test import (
    point_in_rect, segments_intersect, segment_intersects_rect,
    rects_intersect, circle_intersects_rect, ellipse_intersects_rect,
    point_in_polygon,
)
from document.controller import Controller, selection_to_ids
from document.model import Model
from document.op_apply import op_apply
from document.op_log import PrimitiveOp
from geometry.svg import document_to_svg, svg_to_document
from geometry.binary import document_to_binary, binary_to_document
from geometry.test_json import document_to_test_json, test_json_to_document
from workspace.workspace_layout import (
    WorkspaceLayout, DockEdge, PanelKind, GroupAddr, PanelAddr,
)
from workspace.pane import (
    PaneLayout, Pane, PaneConfig, PaneKind, EdgeSide,
)
from workspace.workspace_test_json import (
    workspace_to_test_json, test_json_to_workspace,
    toolbar_structure_json, menu_structure_json,
    state_defaults_json, shortcut_structure_json,
)
from workspace_interpreter.effects import run_effects
from workspace_interpreter.state_store import StateStore

# Path to the shared test fixtures directory.
_FIXTURES = os.path.join(os.path.dirname(__file__), "..", "test_fixtures")


def _read_fixture(path: str) -> str:
    full = os.path.join(_FIXTURES, path)
    with open(full) as f:
        return f.read().strip()


def _assert_svg_parse(test: absltest.TestCase, name: str):
    svg = _read_fixture(f"svg/{name}.svg")
    expected = _read_fixture(f"expected/{name}.json")
    doc = svg_to_document(svg)
    actual = document_to_test_json(doc)
    if actual != expected:
        print(f"=== EXPECTED ({name}) ===")
        print(expected)
        print(f"=== ACTUAL ({name}) ===")
        print(actual)
    test.assertEqual(actual, expected, f"Cross-language test '{name}' failed")


class CrossLanguageTest(absltest.TestCase):
    # ---------------------------------------------------------------
    # SVG round-trip idempotence
    # ---------------------------------------------------------------

    def test_svg_roundtrip_all_fixtures(self):
        # Text fixtures are excluded because document_to_svg calls
        # doc.bounds() which uses QFontMetrics, requiring a running
        # QApplication.  The other three languages cover text round-trip.
        names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer",
            # Live element SVG codec (REFERENCE_GRAPH.md Phase 2a):
            # a reference round-trips as <use href="#id">; a compound
            # as <g data-jas-live="compound_shape" data-jas-operation=...>.
            "live_reference", "live_compound",
            # A compound with a stable id round-trips its id="..." attr.
            "live_compound_id",
            # Symbols P1: <defs> master + <use> instance round-trips through
            # SVG (SYMBOLS.md §5 / Fork S3) — defs masters import to symbols,
            # not layers, and re-export identically.
            "symbols_basic",
            # Symbols P4: the instance transform rides
            # data-jas-instance-transform on the <use> and round-trips through
            # SVG distinct from the render CTM (SYMBOLS.md §4 / Fork F2).
            "reference_instance_transform",
        ]
        for name in names:
            svg = _read_fixture(f"svg/{name}.svg")
            doc1 = svg_to_document(svg)
            json1 = document_to_test_json(doc1)
            svg2 = document_to_svg(doc1)
            doc2 = svg_to_document(svg2)
            json2 = document_to_test_json(doc2)
            self.assertEqual(json1, json2,
                f"SVG round-trip '{name}' failed: canonical JSON changed")

    # ---------------------------------------------------------------
    # JSON round-trip idempotence
    # ---------------------------------------------------------------

    def test_json_roundtrip_all_expected(self):
        names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document", "element_ids",
            # Live element framework (REFERENCE_GRAPH.md Phase 1a):
            # compound shape (operation + operands) and by-id reference
            # (kind + target) round-trip through the test_json live codec.
            "live_compound_roundtrip", "live_reference_roundtrip",
            # A compound with a stable id ("c1") round-trips its id field.
            "live_compound_id",
            # Symbols P1: the `symbols` array (a master) + the instance in
            # layers round-trips through test_json (SYMBOLS.md §10).
            "symbols_basic",
            # Symbols P4: a reference whose instance transform field is set
            # (the instance_transform key) round-trips through test_json
            # distinct from the render CTM (SYMBOLS.md §4 / Fork F2).
            "reference_instance_transform",
        ]
        for name in names:
            expected = _read_fixture(f"expected/{name}.json")
            doc = test_json_to_document(expected)
            actual = document_to_test_json(doc)
            self.assertEqual(actual, expected,
                f"JSON round-trip '{name}' failed: canonical JSON changed")

    # ---------------------------------------------------------------
    # Binary round-trip idempotence
    # ---------------------------------------------------------------

    def test_binary_roundtrip_all_expected(self):
        names = [
            "line_basic", "rect_basic", "rect_with_stroke",
            "circle_basic", "ellipse_basic",
            "polyline_basic", "polygon_basic", "path_all_commands",
            "text_basic", "text_path_basic",
            "text_with_tspans", "text_path_with_tspans",
            "group_nested", "transform_translate", "transform_rotate",
            "multi_layer", "complex_document",
            # Stable identity (binary v2): id+name now round-trip generically.
            "element_ids",
            # Live elements round-trip through binary (Phase 2b).
            "live_compound_roundtrip", "live_reference_roundtrip",
            # A compound with a stable id ("c1") round-trips its id field.
            "live_compound_id",
            # Symbols P1: the master store rides the trailing element array in
            # the binary document (SYMBOLS.md §5); JSON-compare round-trip.
            "symbols_basic",
            # Symbols P4: the instance transform packs at TAG_LIVE slot 9 and
            # round-trips through binary distinct from the render CTM
            # (SYMBOLS.md §4 / Fork F2).
            "reference_instance_transform",
        ]
        for name in names:
            expected = _read_fixture(f"expected/{name}.json")
            doc = test_json_to_document(expected)
            binary_data = document_to_binary(doc)
            doc2 = binary_to_document(binary_data)
            actual = document_to_test_json(doc2)
            self.assertEqual(actual, expected,
                f"Binary round-trip '{name}' failed: canonical JSON changed")

    # ---------------------------------------------------------------
    # SVG parse equivalence
    # ---------------------------------------------------------------

    def test_svg_parse_line_basic(self):
        _assert_svg_parse(self, "line_basic")

    def test_svg_parse_rect_basic(self):
        _assert_svg_parse(self, "rect_basic")

    def test_svg_parse_rect_with_stroke(self):
        _assert_svg_parse(self, "rect_with_stroke")

    def test_svg_parse_circle_basic(self):
        _assert_svg_parse(self, "circle_basic")

    def test_svg_parse_ellipse_basic(self):
        _assert_svg_parse(self, "ellipse_basic")

    def test_svg_parse_polyline_basic(self):
        _assert_svg_parse(self, "polyline_basic")

    def test_svg_parse_polygon_basic(self):
        _assert_svg_parse(self, "polygon_basic")

    def test_svg_parse_path_all_commands(self):
        _assert_svg_parse(self, "path_all_commands")

    def test_svg_parse_text_basic(self):
        _assert_svg_parse(self, "text_basic")

    def test_svg_parse_text_path_basic(self):
        _assert_svg_parse(self, "text_path_basic")

    def test_svg_parse_group_nested(self):
        _assert_svg_parse(self, "group_nested")

    def test_svg_parse_transform_translate(self):
        _assert_svg_parse(self, "transform_translate")

    def test_svg_parse_transform_rotate(self):
        _assert_svg_parse(self, "transform_rotate")

    def test_svg_parse_multi_layer(self):
        _assert_svg_parse(self, "multi_layer")

    def test_svg_parse_complex_document(self):
        _assert_svg_parse(self, "complex_document")

    def test_svg_parse_dup_id_import(self):
        # Two rects share id="dup". The unique-id invariant on import
        # (dedupe_element_ids) keeps the id on the first element in
        # pre-order and clears it on the later duplicate.
        _assert_svg_parse(self, "dup_id_import")

    def test_svg_parse_live_reference(self):
        # <use href="#r1"> imports as a live ReferenceElem whose target
        # is the href minus '#' (F-svg-use). REFERENCE_GRAPH.md Phase 2a.
        _assert_svg_parse(self, "live_reference")

    def test_svg_parse_live_compound(self):
        # <g data-jas-live="compound_shape" data-jas-operation=...>
        # imports as a CompoundShape (operands from children, operation
        # from data-jas-operation) rather than a plain Group.
        _assert_svg_parse(self, "live_compound")

    def test_svg_parse_live_compound_id(self):
        # A <g data-jas-live="compound_shape" ... id="c1"> imports as a
        # CompoundShape whose stable id is populated from the id attr,
        # matching Rust's common_attrs_no_name (id but no name).
        _assert_svg_parse(self, "live_compound_id")

    def test_svg_parse_symbols_basic(self):
        # The <defs> master (id="m1") imports into doc.symbols (NOT layers);
        # the <use href="#m1" id="i1"> imports as a live reference in the
        # layer. The canonical JSON shows the `symbols` array + the instance.
        # All apps parse it to the identical canonical JSON (SYMBOLS.md §10).
        _assert_svg_parse(self, "symbols_basic")

    def test_svg_parse_reference_instance_transform(self):
        # Symbols P4 (SYMBOLS.md §4 / Fork F2): a <use> carrying
        # data-jas-instance-transform="matrix(2,0,0,2,0,0)" imports as a
        # reference whose instance transform field is scale(2,2) (emitted as
        # instance_transform), while the render CTM (transform) stays null —
        # the two transforms are independent.
        _assert_svg_parse(self, "reference_instance_transform")

    # ---------------------------------------------------------------
    # Algorithm test vectors
    # ---------------------------------------------------------------

    def test_algorithm_hit_test_vectors(self):
        json_str = _read_fixture("algorithms/hit_test.json")
        tests = json.loads(json_str)
        for tc in tests:
            func_name = tc["function"]
            args = tc["args"]
            expected = tc["expected"]
            filled = tc.get("filled", False)
            name = tc["name"]

            if func_name == "point_in_rect":
                actual = point_in_rect(*args)
            elif func_name == "segments_intersect":
                actual = segments_intersect(*args)
            elif func_name == "segment_intersects_rect":
                actual = segment_intersects_rect(*args)
            elif func_name == "rects_intersect":
                actual = rects_intersect(*args)
            elif func_name == "circle_intersects_rect":
                actual = circle_intersects_rect(*args, filled=filled)
            elif func_name == "ellipse_intersects_rect":
                actual = ellipse_intersects_rect(*args, filled=filled)
            elif func_name == "point_in_polygon":
                poly = [tuple(p) for p in tc["polygon"]]
                actual = point_in_polygon(*args, poly=poly)
            else:
                self.fail(f"Unknown function: {func_name}")

            self.assertEqual(
                actual, expected,
                f"Hit test '{name}' failed: expected {expected}, got {actual}",
            )


    # ---------------------------------------------------------------
    # Operation equivalence tests
    # ---------------------------------------------------------------

    def _run_operation_fixture(self, fixture):
        json_str = _read_fixture(f"operations/{fixture}")
        tests = json.loads(json_str)

        for tc in tests:
            name = tc["name"]
            svg = _read_fixture(f"svg/{tc['setup_svg']}")
            expected = _read_fixture(f"operations/{tc['expected_json']}")

            doc = svg_to_document(svg)
            model = Model(document=doc)
            ctrl = Controller(model=model)

            # Two fixture shapes (OP_LOG.md §5): the journal-native `txns` form
            # (each transaction commits explicitly via begin_txn/commit_txn,
            # then a `history` directive of undo/redo positions the cursor;
            # snapshot/undo/redo are NOT ops here) and the legacy flat `ops`
            # form (one implicit outer transaction, so non-undoable ops like
            # select_rect are captured into the journal).
            if "txns" in tc:
                for txn in tc["txns"]:
                    model.begin_txn()
                    if "name" in txn:
                        model.name_txn(txn["name"])
                    for op in txn["ops"]:
                        self._apply_op(model, ctrl, op)
                    model.commit_txn()
                    # OP_LOG.md Increment 3a: a txn carrying a `label` stamps a
                    # named version point onto the just-committed transaction.
                    if "label" in txn:
                        model.label_version(txn["label"])
                for h in tc.get("history", []):
                    if h == "undo":
                        model.undo()
                    elif h == "redo":
                        model.redo()
                    else:
                        self.fail(f"Unknown history directive: {h}")
            else:
                model.begin_txn()
                for op in tc["ops"]:
                    self._apply_op(model, ctrl, op)
                model.commit_txn()

            actual = document_to_test_json(model.document)
            self.assertEqual(actual, expected,
                f"Operation test '{name}' failed")

            # checkpoint_equivalence gate (OP_LOG.md §6): the journal must
            # replay to the same document as the snapshot path.
            replayed = self._replay_journal(
                svg, model.journal, model.journal_head)
            self.assertEqual(replayed, actual,
                f"checkpoint_equivalence gate failed for '{name}': "
                "journal replay != snapshot path")

    def _replay_journal(self, svg, journal, head):
        doc = svg_to_document(svg)
        model = Model(document=doc)
        ctrl = Controller(model=model)
        for txn in journal[:head]:
            for op in txn.ops:
                self._apply_op(model, ctrl, op.params)
        return document_to_test_json(model.document)

    def _apply_op(self, model, ctrl, op):
        # Thin harness shim over the production dispatcher (OP_LOG.md §9,
        # Increment 3b-B): both the cross-language harness and the production
        # effect path go through the SAME op_apply module and the SAME record_op
        # site, so this lift is behavior-preserving (the operations fixtures stay
        # byte-green) and `targets` is recorded identically on both paths.
        # Promoting the dispatcher also hardened its param parsing so production
        # input can't raise. Mirrors the Rust harness apply_op shim.
        op_apply(model, op)

    def test_operation_select_and_move(self):
        self._run_operation_fixture("select_and_move.json")

    def test_operation_undo_redo_laws(self):
        self._run_operation_fixture("undo_redo_laws.json")

    def test_operation_controller_ops(self):
        self._run_operation_fixture("controller_ops.json")

    def test_operation_symbols_ops(self):
        # Symbols P2 operation fixtures (SYMBOLS.md §7): make_symbol,
        # place_instance, detach, redefine. Each setup parses through the P1
        # SVG <defs> codec, runs the op, and pins the canonical JSON all four
        # apps must reproduce.
        self._run_operation_fixture("symbols_ops.json")

    @staticmethod
    def _recorded_canonical_document():
        # The canonical recorded-live-element document (RECORDED_ELEMENTS.md):
        # a recorded element whose recipe copies its input "eye" and translates
        # the copy +50x. Built identically in every app's harness, so its
        # document_to_test_json serialization (the recipe + inputs) is the
        # cross-language pin.
        from document.document import Document
        from geometry.element import Layer, RecordedElem
        recipe = (
            PrimitiveOp(op="copy",
                        params={"from": ["eye"], "dx": 0.0, "dy": 0.0},
                        targets=[]),
            PrimitiveOp(op="translate",
                        params={"ids": ["$0"], "dx": 50.0, "dy": 0.0},
                        targets=[]),
        )
        rec = RecordedElem(ops=recipe, inputs=("eye",), id="rec")
        layer = Layer(name=None, children=(rec,))
        return Document(layers=(layer,), artboards=())

    def test_recorded_cross_language(self):
        # Cross-language pin (RECORDED_ELEMENTS.md §8): a recorded element's
        # recipe + inputs serialize byte-identically across the native apps.
        actual = document_to_test_json(self._recorded_canonical_document())
        expected = _read_fixture("operations/recorded_eye.json")
        if actual != expected:
            print("=== EXPECTED (recorded_eye) ===")
            print(expected)
            print("=== ACTUAL (recorded_eye) ===")
            print(actual)
        self.assertEqual(actual, expected,
            "recorded cross-language serialization mismatch")

    def test_operation_boolean_ops(self):
        # Boolean grouping (OP_LOG.md §10 item 3): boolean_union + post-op
        # simplify are one transaction; the gate pins that the journal replays
        # to the snapshot-path document.
        self._run_operation_fixture("boolean_ops.json")

    # ---------------------------------------------------------------
    # The 33-verb actions.yaml<->op_apply unification (OP_LOG.md §9
    # Phases P1-P7). Each shared fixture replays through the production
    # op_apply dispatcher and byte-matches the Rust golden via
    # document_to_test_json — the prime-directive cross-language pin.
    # ---------------------------------------------------------------

    def test_operation_print_config_setters(self):
        # P1: the eight print-config field setters (set_*_field) journal
        # RESOLVED literals through apply_print_config_field.
        self._run_operation_fixture("print_config_setters.json")

    def test_operation_artboard_set_field_batch(self):
        # P2: set_artboard_field / set_artboard_options_field (one op per
        # field call; type-mismatch skips journal nothing).
        self._run_operation_fixture("artboard_set_field_batch.json")

    def test_operation_artboard_reorder(self):
        # P2: move_artboards_up / move_artboards_down (swap-skipping-selected).
        self._run_operation_fixture("artboard_reorder.json")

    def test_operation_artboard_delete(self):
        # P2: delete_artboard_by_id (missing id is a journal-nothing no-op).
        self._run_operation_fixture("artboard_delete.json")

    def test_operation_artboard_create(self):
        # P3: create_artboard — VALUE-IN-OP id read verbatim, never minted.
        self._run_operation_fixture("artboard_create.json")

    def test_operation_artboard_duplicate(self):
        # P3: duplicate_artboard — VALUE-IN-OP new_id + resolved name literal.
        self._run_operation_fixture("artboard_duplicate.json")

    def test_operation_structural_delete_at(self):
        # P4: delete_at (path-keyed tree delete; absent path no-ops).
        self._run_operation_fixture("structural_delete_at.json")

    def test_operation_structural_delete_selection(self):
        # P4: delete_selection (reference-aware; empty selection no-ops).
        self._run_operation_fixture("structural_delete_selection.json")

    def test_operation_structural_insert_after(self):
        # P4: insert_after — carries the WHOLE element as value-in-op JSON.
        self._run_operation_fixture("structural_insert_after.json")

    def test_operation_structural_insert_at(self):
        # P4: insert_at — value-in-op element; empty parent_path => top-level.
        self._run_operation_fixture("structural_insert_at.json")

    def test_operation_wrap_in_group(self):
        # P5: wrap_in_group (multi-step replays as one op; optional id).
        self._run_operation_fixture("wrap_in_group.json")

    def test_operation_wrap_in_layer(self):
        # P5: wrap_in_layer — carries the RESOLVED name literal; optional id.
        self._run_operation_fixture("wrap_in_layer.json")

    def test_operation_unpack_group_at(self):
        # P5: unpack_group_at (non-Group / absent path no-ops).
        self._run_operation_fixture("unpack_group_at.json")

    def test_operation_set_attr_on_selection(self):
        # P6: set_attr_on_selection — stroke_brush / stroke_brush_overrides;
        # empty value clears, unknown attr skips.
        self._run_operation_fixture("set_attr_on_selection.json")

    def test_operation_transform_scale(self):
        # P7: scale_transform (resolved matrix; identity no-ops; strokes/corners).
        self._run_operation_fixture("transform_scale.json")

    def test_operation_transform_rotate(self):
        # P7: rotate_transform (resolved matrix; zero-angle no-ops).
        self._run_operation_fixture("transform_rotate.json")

    def test_operation_transform_shear(self):
        # P7: shear_transform (resolved matrix; zero-angle no-ops).
        self._run_operation_fixture("transform_shear.json")

    def test_operation_transform_copy(self):
        # P7: copy=true journals [copy_selection, <transform>] in one txn.
        self._run_operation_fixture("transform_copy.json")

    # ---------------------------------------------------------------
    # P7 — transform CONFIRM PRODUCTION ROUTE (OP_LOG.md §9 / §8).
    # Drives the REAL scale/rotate/shear_options_confirm actions from the
    # compiled bundle (journal:true) through run_effects and asserts exactly
    # the right op(s) are journaled with RESOLVED params, the live doc is
    # transformed, and checkpoint_equivalence holds. Mirrors the Swift
    # productionTransformConfirmJournalsOneOp / ...CopyJournalsTwoOps.
    # ---------------------------------------------------------------

    @staticmethod
    def _transform_production_model():
        # rect_with_id selection established (the production transform setup).
        svg = _read_fixture("svg/rect_with_id.svg")
        model = Model(document=svg_to_document(svg))
        model.begin_txn()
        op_apply(model, {"op": "select_rect", "x": 0.0, "y": 0.0,
                         "width": 96.0, "height": 96.0, "extend": False})
        model.commit_txn()
        return model

    @staticmethod
    def _run_transform_action(model, action, params):
        import os as _os
        from workspace_interpreter.loader import load_workspace
        from tools import yaml_tool_effects
        repo_root = _os.path.abspath(
            _os.path.join(_os.path.dirname(__file__), ".."))
        bundle = load_workspace(_os.path.join(repo_root, "workspace", "workspace.json"))
        action_def = bundle["actions"][action]
        effects = action_def["effects"]
        ctrl = Controller(model=model)
        pe = yaml_tool_effects.build(ctrl)
        store = StateStore()
        run_effects(effects, {"param": params}, store,
                    actions=bundle["actions"], platform_effects=pe,
                    model=model, action_name=action)

    def _assert_confirm_replay_equivalent(self, model):
        live = document_to_test_json(model.document)
        replay = Model(document=svg_to_document(_read_fixture("svg/rect_with_id.svg")))
        for txn in model.journal:
            for o in txn.ops:
                op_apply(replay, o.params)
        self.assertEqual(document_to_test_json(replay.document), live,
            "checkpoint_equivalence: production confirm replay != live document")

    def test_production_transform_confirm_journals_one_op(self):
        # (scale) uniform 200%, copy=false. 96x96 px -> 72x72 pt => center 36.
        model = self._transform_production_model()
        self._run_transform_action(model, "scale_options_confirm", {
            "uniform": True, "uniform_pct": 200.0,
            "horizontal_pct": 100.0, "vertical_pct": 100.0,
            "scale_strokes": True, "scale_corners": False,
            "preview": False, "copy": False,
        })
        txn = model.journal[-1]
        self.assertEqual([o.op for o in txn.ops], ["scale_transform"])
        p = txn.ops[0].params
        self.assertEqual(p["sx"], 2.0)
        self.assertEqual(p["sy"], 2.0)
        self.assertEqual(p["rx"], 36.0)
        self.assertEqual(p["ry"], 36.0)
        self.assertEqual(p["scale_strokes"], True)
        self.assertEqual(p["scale_corners"], False)
        self.assertEqual(txn.ops[0].targets, ["rect-1"])
        self.assertIsNotNone(model.document.get_element((0, 0)).transform)
        self._assert_confirm_replay_equivalent(model)

        # (rotate) 30 deg around the bounds center.
        model = self._transform_production_model()
        self._run_transform_action(model, "rotate_options_confirm",
            {"angle": 30.0, "preview": False, "copy": False})
        txn = model.journal[-1]
        self.assertEqual([o.op for o in txn.ops], ["rotate_transform"])
        p = txn.ops[0].params
        self.assertEqual(p["angle"], 30.0)
        self.assertEqual(p["rx"], 36.0)
        self.assertEqual(p["ry"], 36.0)
        self.assertEqual(txn.ops[0].targets, ["rect-1"])
        self._assert_confirm_replay_equivalent(model)

        # (shear) 20 deg horizontal around the bounds center.
        model = self._transform_production_model()
        self._run_transform_action(model, "shear_options_confirm",
            {"angle": 20.0, "axis": "horizontal", "axis_angle": 0.0,
             "preview": False, "copy": False})
        txn = model.journal[-1]
        self.assertEqual([o.op for o in txn.ops], ["shear_transform"])
        p = txn.ops[0].params
        self.assertEqual(p["angle"], 20.0)
        self.assertEqual(p["axis"], "horizontal")
        self.assertEqual(p["rx"], 36.0)
        self.assertEqual(p["ry"], 36.0)
        self.assertEqual(txn.ops[0].targets, ["rect-1"])
        self._assert_confirm_replay_equivalent(model)

    def test_production_transform_copy_journals_two_ops(self):
        # copy=true journals [copy_selection, scale_transform] in one txn.
        model = self._transform_production_model()
        self._run_transform_action(model, "scale_options_confirm", {
            "uniform": True, "uniform_pct": 200.0,
            "horizontal_pct": 100.0, "vertical_pct": 100.0,
            "scale_strokes": True, "scale_corners": False,
            "preview": False, "copy": True,
        })
        txn = model.journal[-1]
        self.assertEqual([o.op for o in txn.ops],
                         ["copy_selection", "scale_transform"])
        self._assert_confirm_replay_equivalent(model)

    # ---------------------------------------------------------------
    # Production op-capture cross-language fixture (OP_LOG.md §9,
    # Increment 3b-B). Drives the REAL effect runner
    # (workspace_interpreter.effects.run_effects with the jas
    # yaml_tool_effects platform map, a Model, and the action_name) — NOT the
    # hand-bracketed _apply_op operations path — against the SHARED
    # test_fixtures/production_capture/*.json goldens, byte-for-byte. That is
    # the whole point: it exercises the YAML->harness param translation (marquee
    # corners x1/y1/x2/y2/additive -> x/y/width/height/extend), batch ownership /
    # single named-transaction commit, and the lazy-begin drag-frame-hole fix.
    # ---------------------------------------------------------------

    @staticmethod
    def _production_journal_to_test_json(journal):
        # Production-capture JOURNAL serializer VARIANT (OP_LOG.md §10 item 4).
        # Distinct from _journal_to_test_json (which omits op params and pins
        # txn_id/lamport/parent/actor). The production golden pins the
        # PARAM-TRANSLATION result (the marquee corners normalize to
        # x/y/width/height/extend), so this variant emits per transaction `name`,
        # and per op `{op, params, targets}` with `params` sorted-key +
        # fixed-float canonicalized exactly like document_to_test_json (via
        # _canonical_value). The redundant top-level "op" key inside the recorded
        # params is STRIPPED (the verb already lives in the op-level `op` field).
        # txn_id/actor/parent/lamport are EXCLUDED (txn_id is a live-entropy seam,
        # the causal metadata has its own golden). Mirrors the Rust
        # production_journal_to_test_json.
        from geometry.test_json import _canonical_value

        def opt(s):
            return _canonical_value(s) if s is not None else "null"
        txns = []
        for t in journal:
            ops = []
            for o in t.ops:
                params = {k: v for k, v in o.params.items() if k != "op"}
                targets = ",".join(_canonical_value(x) for x in o.targets)
                ops.append(
                    f'{{"op":{_canonical_value(o.op)},'
                    f'"params":{_canonical_value(params)},'
                    f'"targets":[{targets}]}}')
            txns.append(f'{{"name":{opt(t.name)},"ops":[{",".join(ops)}]}}')
        return "[" + ",".join(txns) + "]"

    @staticmethod
    def _polygon_set_to_test_json(ps):
        # Canonical JSON of an evaluated PolygonSet (a list of rings, each a list
        # of (x, y) points), using the SAME fixed-float canonicalization as
        # document_to_test_json so the re-derived geometry golden is
        # byte-shareable across apps. Mirrors the Rust polygon_set_to_test_json.
        from geometry.test_json import _canonical_value
        rings = []
        for ring in ps:
            pts = [f'[{_canonical_value(x)},{_canonical_value(y)}]'
                   for (x, y) in ring]
            rings.append("[" + ",".join(pts) + "]")
        return "[" + ",".join(rings) + "]"

    @staticmethod
    def _production_model(fx):
        # Build the fresh Model a production-capture fixture's setup_svg defines.
        setup_svg = _read_fixture(fx["setup_svg"])
        return Model(document=svg_to_document(setup_svg))

    @staticmethod
    def _run_production_batches(fx, model):
        # Run every run_effects batch a production-capture fixture defines through
        # the REAL production interpreter, stamping the fixture's action_name.
        # Supports both fixture shapes:
        #   - effect_batch: [...]   — ONE run_effects call (the eye_demo
        #       select->copy->move demonstration, one named transaction).
        #   - frames: [[...], [...]] — MULTIPLE separate run_effects calls (the
        #       drag-frame-hole closure: frame 1 = snapshot+select+translate,
        #       frame 2 = a BARE translate with NO snapshot). Each frame is a
        #       distinct batch, so each commits its own named transaction — the
        #       one scenario the test-path operations corpus cannot reach.
        from tools import yaml_tool_effects
        action_name = fx.get("action_name")
        ctrl = Controller(model=model)
        pe = yaml_tool_effects.build(ctrl)
        store = StateStore()

        def run_batch(batch):
            run_effects(batch, {}, store, platform_effects=pe,
                        model=model, action_name=action_name)

        if "effect_batch" in fx:
            run_batch(list(fx["effect_batch"]))
        elif "frames" in fx:
            for frame in fx["frames"]:
                run_batch(list(frame))
        else:
            raise AssertionError(
                "production-capture fixture has neither effect_batch nor frames")

    def _rederive_recorded_output(self, fx, journal):
        # Re-derive the recorded element's output against the EDITED source and
        # return its canonical PolygonSet JSON. Lifts the LAST committed
        # transaction's op segment, runs capture_recipe to normalize it into an
        # input-addressed recipe, wraps it in a RecordedElem, then evaluate_with
        # it over a resolver that returns the EDITED source (the fixture's
        # recorded.edit_source applies set:{x:..} to the source SVG).
        #
        # NOTE — the SVG px->pt unit conversion (96/72 = x0.75) bakes into the
        # re-derived bbox: editing the source eye to x=100 (px) maps to x=75 (pt)
        # with w=10px->7.5pt; copy(dx=0)+translate(+50) -> the derived bbox spans
        # x in [125, 132.5] (pt). The derivative FOLLOWED the edit — that is the
        # whole point of liveness, and it is what this golden pins.
        from geometry.element import RecordedElem
        from geometry.live import capture_recipe, DEFAULT_PRECISION

        segment = journal[-1].ops
        recipe, inputs = capture_recipe(segment)
        recorded = RecordedElem(ops=tuple(recipe), inputs=tuple(inputs), id="rec")

        rec = fx["recorded"]
        edit = rec["edit_source"]
        edit_id = edit["id"]
        setup_svg = _read_fixture(fx["setup_svg"])
        new_x = int(edit["set"]["x"])
        edited_svg = setup_svg.replace('x="0" y="0"', f'x="{new_x}" y="0"')
        edited_doc = svg_to_document(edited_svg)
        # The edited source is layers[0].children[0].
        edited_el = edited_doc.get_element((0, 0))

        class _OneResolver:
            def resolve(self, ref):
                return edited_el if ref == edit_id else None

        ps = recorded.evaluate_with(DEFAULT_PRECISION, _OneResolver(), set())
        return self._polygon_set_to_test_json(ps)

    def _run_production_batch_fixture(self, fixture_path):
        # Reusable production-capture harness (OP_LOG.md §9, Increment 3b-B).
        # Loads the fixture, drives the REAL run_effects over setup_svg, then
        # asserts:
        #  (a) _production_journal_to_test_json == expected_journal_json;
        #  (b) checkpoint_equivalence (OP_LOG.md §6): replaying the journal ops
        #      via op_apply from setup_svg is byte-identical BOTH to
        #      expected_document_json AND to the live snapshot-path document;
        #  (c) the recorded re-derivation (when declared) == expected_output_json;
        #  (d) a SCOPED completeness assert: EVERY committed production
        #      transaction's ops is non-empty (the production path here MUST emit
        #      ops — NOT a global commit_txn invariant).
        fx = json.loads(_read_fixture(fixture_path))
        name = fx.get("name", fixture_path)

        # Drive the REAL production interpreter.
        model = self._production_model(fx)
        self._run_production_batches(fx, model)

        # (a) journal serialization == golden.
        actual_journal = self._production_journal_to_test_json(model.journal)
        expected_journal = _read_fixture(fx["expected_journal_json"])
        if actual_journal != expected_journal:
            print(f"=== EXPECTED journal ({name}) ===\n{expected_journal}")
            print(f"=== ACTUAL journal ({name}) ===\n{actual_journal}")
        self.assertEqual(actual_journal, expected_journal,
            f"production-capture journal JSON mismatch for '{name}'")

        # Snapshot-path document (the live result of run_effects).
        snapshot_doc = document_to_test_json(model.document)

        # (b) checkpoint_equivalence: replay the WHOLE journal via op_apply from
        # a fresh setup, byte-compare to BOTH the expected_document golden AND
        # the live snapshot-path document.
        replay = self._production_model(fx)
        for txn in model.journal:
            for op in txn.ops:
                op_apply(replay, op.params)
        replay_doc = document_to_test_json(replay.document)
        expected_doc = _read_fixture(fx["expected_document_json"])
        if replay_doc != snapshot_doc:
            print(f"=== checkpoint_equivalence GATE FAILED ({name}) ===")
            print(f"--- snapshot path ---\n{snapshot_doc}")
            print(f"--- journal replay ---\n{replay_doc}")
        self.assertEqual(replay_doc, snapshot_doc,
            f"checkpoint_equivalence: journal replay != snapshot path "
            f"for '{name}'")
        if replay_doc != expected_doc:
            print(f"=== EXPECTED doc ({name}) ===\n{expected_doc}")
            print(f"=== ACTUAL doc ({name}) ===\n{replay_doc}")
        self.assertEqual(replay_doc, expected_doc,
            f"production-capture document JSON mismatch for '{name}'")

        # (c) recorded re-derivation against the edited source == golden.
        if "recorded" in fx:
            actual_out = self._rederive_recorded_output(fx, model.journal)
            expected_out = _read_fixture(fx["recorded"]["expected_output_json"])
            if actual_out != expected_out:
                print(f"=== EXPECTED rederived ({name}) ===\n{expected_out}")
                print(f"=== ACTUAL rederived ({name}) ===\n{actual_out}")
            self.assertEqual(actual_out, expected_out,
                f"production-capture re-derivation mismatch for '{name}'")

        # (d) scoped completeness assert: every committed production transaction
        # emits ops (the production path here is NOT named-but-op-less).
        self.assertTrue(len(model.journal) >= 1,
            f"production batch committed at least one transaction ({name})")
        for i, txn in enumerate(model.journal):
            self.assertTrue(len(txn.ops) >= 1,
                f"production txn {i} emits ops (3b-B completeness, {name})")

    def test_production_capture_eye_demo(self):
        # Production op-capture eye demo (OP_LOG.md §9): marquee-select -> copy
        # -> move, driven through the REAL run_effects, pins the translated
        # journal, the checkpoint-equivalent document, and the live
        # re-derivation against the edited source.
        self._run_production_batch_fixture("production_capture/eye_demo.json")

    def test_production_capture_eye_demo_bare_frame(self):
        # Production op-capture drag-frame-hole closure (OP_LOG.md §9): two
        # SEPARATE run_effects batches — frame 1 (snapshot+select+translate) and
        # a BARE frame 2 (translate, NO snapshot) — both commit NAMED
        # transactions that journal their move_selection op. The one scenario the
        # test-path operations corpus structurally cannot reach.
        self._run_production_batch_fixture(
            "production_capture/eye_demo_bare_frame.json")

    @staticmethod
    def _journal_to_test_json(journal):
        # Canonical JSON of the Transaction journal (OP_LOG.md §10 item 4):
        # fixed (sorted) key order + deterministic txn-N ids -> byte-shareable.
        # Mirrors journal_to_test_json in the other apps' harnesses.
        def opt(s):
            return f'"{s}"' if s is not None else "null"
        txns = []
        for t in journal:
            ops = []
            for o in t.ops:
                targets = ",".join(f'"{x}"' for x in o.targets)
                ops.append(f'{{"op":"{o.op}","targets":[{targets}]}}')
            txns.append(
                f'{{"actor":"{t.actor}","label":{opt(t.label)},'
                f'"lamport":{t.lamport},"name":{opt(t.name)},'
                f'"ops":[{",".join(ops)}],"parent":{opt(t.parent)},'
                f'"txn_id":"{t.txn_id}"}}')
        return "[" + ",".join(txns) + "]"

    def test_journal_txn_metadata(self):
        # OP_LOG.md §10 item 4: the journal's causal/merge metadata serializes
        # byte-identically across apps (deterministic txn-N counter + parent).
        # OP_LOG.md Increment 3a adds txn_labels.json: a txn carrying a `label`
        # stamps a named version onto the committed transaction, which surfaces
        # in the serialized journal's `label` field.
        fixtures = ["txn_metadata.json", "txn_labels.json"]
        for fixture in fixtures:
            for tc in json.loads(_read_fixture(f"operations/{fixture}")):
                svg = _read_fixture(f"svg/{tc['setup_svg']}")
                model = Model(document=svg_to_document(svg))
                ctrl = Controller(model=model)
                for txn in tc["txns"]:
                    model.begin_txn()
                    if "name" in txn:
                        model.name_txn(txn["name"])
                    for op in txn["ops"]:
                        self._apply_op(model, ctrl, op)
                    model.commit_txn()
                    if "label" in txn:
                        model.label_version(txn["label"])
                actual = self._journal_to_test_json(model.journal)
                expected = _read_fixture(
                    f"operations/{tc['expected_journal_json']}").strip()
                self.assertEqual(actual, expected,
                    f"journal JSON mismatch for '{tc['name']}'")

    def test_assign_id_on_compound(self):
        # Regression for the reachable equivalence bug: assign_id does
        # replace(elem, id=id), which on a CompoundShape used to raise
        # TypeError (no id field) while Rust/OCaml stamped it fine. Now
        # CompoundShape carries a stable id, so stamping one (here onto a
        # previously id-less compound imported from SVG) must succeed and
        # the parsed id must reach the element. See REFERENCE_GRAPH.md §4.
        from geometry.element import CompoundShape
        doc = svg_to_document(_read_fixture("svg/live_compound.svg"))
        model = Model(document=doc)
        ctrl = Controller(model=model)
        path = (0, 0)
        compound = model.document.get_element(path)
        self.assertIsInstance(compound, CompoundShape)
        self.assertIsNone(compound.id)
        ctrl.assign_id(path, "c1")  # must not raise TypeError
        stamped = model.document.get_element(path)
        self.assertIsInstance(stamped, CompoundShape)
        self.assertEqual(stamped.id, "c1")

    # ---------------------------------------------------------------
    # Dependency index (REFERENCE_GRAPH.md §3)
    # ---------------------------------------------------------------

    def test_dependency_index_cross_language(self):
        # Cross-language pin: read the shared input document fixture, build
        # the derived dependency index, serialize it, and assert byte-equality
        # with the shared index fixture. All five apps run this same pair of
        # fixtures; passing means Python agrees on the canonical index shape.
        from document.dependency_index import (
            dependency_index, dependency_index_to_test_json,
        )
        # Parse the shared input document.
        input_json = _read_fixture("expected/dependency_index_input.json")
        doc = test_json_to_document(input_json)
        # Sanity: the parsed input must re-serialize to itself (the fixture is
        # canonical), so the index is computed over the same doc all apps see.
        self.assertEqual(
            document_to_test_json(doc), input_json,
            "dependency_index_input.json is not canonical: "
            "parse->serialize changed it")
        # Build + serialize the index, compare with the expected fixture.
        actual = dependency_index_to_test_json(dependency_index(doc))
        expected = _read_fixture("expected/dependency_index.json")
        if actual != expected:
            print("=== EXPECTED (dependency_index) ===")
            print(expected)
            print("=== ACTUAL (dependency_index) ===")
            print(actual)
        self.assertEqual(
            actual, expected,
            "dependency_index cross-language test failed: "
            "canonical JSON mismatch")

    def test_dependency_index_chain_cross_language(self):
        # Cross-language pin for the chain/diamond graph (REFERENCE_GRAPH.md §8
        # Phase 4a): read the shared input document, build the index, serialize
        # it, and assert byte-equality with the shared chain fixture. Exercises
        # multi-level topological ordering that the primary fixture cannot.
        from document.dependency_index import (
            dependency_index, dependency_index_to_test_json,
        )
        input_json = _read_fixture("expected/dependency_index_chain_input.json")
        doc = test_json_to_document(input_json)
        # Sanity: the parsed input must re-serialize to itself (it is canonical).
        self.assertEqual(
            document_to_test_json(doc), input_json,
            "dependency_index_chain_input.json is not canonical: "
            "parse->serialize changed it")
        actual = dependency_index_to_test_json(dependency_index(doc))
        expected = _read_fixture("expected/dependency_index_chain.json")
        if actual != expected:
            print("=== EXPECTED (dependency_index_chain) ===")
            print(expected)
            print("=== ACTUAL (dependency_index_chain) ===")
            print(actual)
        self.assertEqual(
            actual, expected,
            "dependency_index_chain cross-language test failed: "
            "canonical JSON mismatch")

    def test_orphaned_references_cross_language(self):
        # Cross-language pin (REFERENCE_GRAPH.md): parse the shared input
        # document, read the shared orphaned-references fixture, and for each
        # case assert that orphaned_references(doc, delete_paths) equals the
        # expected ids. All apps run this same pair of fixtures.
        from document.dependency_index import orphaned_references
        doc = test_json_to_document(
            _read_fixture("expected/dependency_index_input.json"))
        cases = json.loads(
            _read_fixture("expected/orphaned_references.json"))
        self.assertIsInstance(cases, list)
        for i, case in enumerate(cases):
            delete_paths = [list(p) for p in case["delete_paths"]]
            expected = list(case["orphaned"])
            actual = orphaned_references(doc, delete_paths)
            self.assertEqual(
                actual, expected,
                f"orphaned_references cross-language case {i} "
                f"({delete_paths}) mismatch: expected {expected}, "
                f"got {actual}")

    # ---------------------------------------------------------------
    # Workspace layout equivalence tests
    # ---------------------------------------------------------------

    def _assert_workspace_fixture(self, name: str, actual: str):
        expected = _read_fixture(f"expected/{name}.json")
        if actual != expected:
            print(f"=== EXPECTED ({name}) ===")
            print(expected)
            print(f"=== ACTUAL ({name}) ===")
            print(actual)
        self.assertEqual(actual, expected,
            f"Workspace test '{name}' failed: canonical JSON mismatch")

    def test_workspace_default_layout(self):
        layout = WorkspaceLayout.default_layout()
        actual = workspace_to_test_json(layout)
        self._assert_workspace_fixture("workspace_default", actual)

    def test_workspace_default_with_panes(self):
        layout = WorkspaceLayout.default_layout()
        layout.ensure_pane_layout(1200.0, 800.0)
        actual = workspace_to_test_json(layout)
        self._assert_workspace_fixture("workspace_default_with_panes", actual)

    def test_workspace_json_roundtrip(self):
        for name in ["workspace_default", "workspace_default_with_panes"]:
            fixture = _read_fixture(f"expected/{name}.json")
            parsed = test_json_to_workspace(fixture)
            reserialized = workspace_to_test_json(parsed)
            self.assertEqual(fixture, reserialized,
                f"Workspace JSON roundtrip failed for '{name}'")

    def test_toolbar_structure(self):
        actual = toolbar_structure_json()
        self._assert_workspace_fixture("toolbar_structure", actual)

    def test_menu_structure(self):
        actual = menu_structure_json()
        self._assert_workspace_fixture("menu_structure", actual)

    def test_state_defaults(self):
        actual = state_defaults_json()
        self._assert_workspace_fixture("state_defaults", actual)

    def test_shortcut_structure(self):
        actual = shortcut_structure_json()
        self._assert_workspace_fixture("shortcut_structure", actual)

    # ---------------------------------------------------------------
    # Workspace operation equivalence tests
    # ---------------------------------------------------------------

    def _parse_panel_kind(self, s: str) -> PanelKind:
        return {
            "color": PanelKind.COLOR,
            "swatches": PanelKind.SWATCHES,
            "stroke": PanelKind.STROKE,
            "properties": PanelKind.PROPERTIES,
        }.get(s, PanelKind.LAYERS)

    def _parse_pane_kind(self, s: str) -> PaneKind:
        return {
            "toolbar": PaneKind.TOOLBAR,
            "dock": PaneKind.DOCK,
        }.get(s, PaneKind.CANVAS)

    def _apply_workspace_op(self, layout: WorkspaceLayout, op: dict):
        name = op["op"]

        # Panel/dock operations
        if name == "toggle_group_collapsed":
            layout.toggle_group_collapsed(GroupAddr(
                dock_id=op["dock_id"], group_idx=op["group_idx"]))
        elif name == "set_active_panel":
            layout.set_active_panel(PanelAddr(
                group=GroupAddr(dock_id=op["dock_id"], group_idx=op["group_idx"]),
                panel_idx=op["panel_idx"]))
        elif name == "close_panel":
            layout.close_panel(PanelAddr(
                group=GroupAddr(dock_id=op["dock_id"], group_idx=op["group_idx"]),
                panel_idx=op["panel_idx"]))
        elif name == "show_panel":
            kind = self._parse_panel_kind(op["kind"])
            layout.show_panel(kind)
        elif name == "reorder_panel":
            layout.reorder_panel(
                GroupAddr(dock_id=op["dock_id"], group_idx=op["group_idx"]),
                op["from"], op["to"])
        elif name == "move_panel_to_group":
            layout.move_panel_to_group(
                PanelAddr(
                    group=GroupAddr(dock_id=op["from_dock_id"],
                                   group_idx=op["from_group_idx"]),
                    panel_idx=op["from_panel_idx"]),
                GroupAddr(dock_id=op["to_dock_id"],
                          group_idx=op["to_group_idx"]))
        elif name == "detach_group":
            layout.detach_group(
                GroupAddr(dock_id=op["dock_id"], group_idx=op["group_idx"]),
                op["x"], op["y"])
        elif name == "redock":
            layout.redock(op["dock_id"])
        # Pane operations
        elif name == "set_pane_position":
            layout.pane_layout.set_pane_position(
                op["pane_id"], op["x"], op["y"])
        elif name == "tile_panes":
            layout.pane_layout.tile_panes()
        elif name == "toggle_canvas_maximized":
            layout.pane_layout.toggle_canvas_maximized()
        elif name == "resize_pane":
            layout.pane_layout.resize_pane(
                op["pane_id"], op["width"], op["height"])
        elif name == "hide_pane":
            kind = self._parse_pane_kind(op["kind"])
            layout.pane_layout.hide_pane(kind)
        elif name == "show_pane":
            kind = self._parse_pane_kind(op["kind"])
            layout.pane_layout.show_pane(kind)
        elif name == "bring_pane_to_front":
            layout.pane_layout.bring_pane_to_front(op["pane_id"])
        else:
            self.fail(f"Unknown workspace op: {name}")

    def _run_workspace_operation_test(self, tc: dict) -> str:
        setup_name = tc["setup"]
        setup_json = _read_fixture(f"expected/{setup_name}")
        layout = test_json_to_workspace(setup_json)

        for op in tc["ops"]:
            self._apply_workspace_op(layout, op)

        return workspace_to_test_json(layout)

    def _assert_workspace_operation_test(self, tc: dict):
        name = tc["name"]
        expected_file = tc["expected_json"]
        expected = _read_fixture(f"workspace_operations/{expected_file}")
        actual = self._run_workspace_operation_test(tc)

        if actual != expected:
            print(f"=== EXPECTED ({name}) ===")
            print(expected)
            print(f"=== ACTUAL ({name}) ===")
            print(actual)
        self.assertEqual(actual, expected,
            f"Workspace operation test '{name}' failed: canonical JSON mismatch")

    def _run_workspace_operation_fixture(self, fixture: str):
        json_str = _read_fixture(fixture)
        tests = json.loads(json_str)
        for tc in tests:
            self._assert_workspace_operation_test(tc)

    def test_workspace_panel_ops(self):
        self._run_workspace_operation_fixture(
            "workspace_operations/panel_ops.json")

    def test_workspace_pane_ops(self):
        self._run_workspace_operation_fixture(
            "workspace_operations/pane_ops.json")

    # ---------------------------------------------------------------
    # Pane geometry algorithm test vectors
    # ---------------------------------------------------------------

    def test_algorithm_pane_geometry(self):
        json_str = _read_fixture("algorithms/pane_geometry.json")
        tests = json.loads(json_str)

        for tc in tests:
            name = tc["name"]
            func = tc["function"]
            args = tc["args"]
            expected = tc["expected"]

            if func == "pane_edge_coord":
                pane = Pane(
                    id=0,
                    kind=PaneKind.CANVAS,
                    config=PaneConfig.for_kind(PaneKind.CANVAS),
                    x=args["x"], y=args["y"],
                    width=args["width"], height=args["height"],
                )
                edge_map = {
                    "left": EdgeSide.LEFT,
                    "right": EdgeSide.RIGHT,
                    "top": EdgeSide.TOP,
                    "bottom": EdgeSide.BOTTOM,
                }
                edge = edge_map[args["edge"]]
                actual = PaneLayout.pane_edge_coord(pane, edge)
            else:
                self.fail(f"Unknown function: {func}")

            self.assertAlmostEqual(actual, expected, places=4,
                msg=f"Pane geometry '{name}' failed: expected {expected}, got {actual}")


if __name__ == "__main__":
    absltest.main()
