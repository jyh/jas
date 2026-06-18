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
from document.controller import Controller
from document.model import Model
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
                        model.record_op(PrimitiveOp(op=op["op"], params=op))
                    model.commit_txn()
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
                    model.record_op(PrimitiveOp(op=op["op"], params=op))
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
        op_name = op["op"]
        if op_name == "select_rect":
            ctrl.select_rect(
                op["x"], op["y"], op["width"], op["height"],
                extend=op.get("extend", False))
        elif op_name == "move_selection":
            ctrl.move_selection(op["dx"], op["dy"])
        elif op_name == "copy_selection":
            ctrl.copy_selection(op["dx"], op["dy"])
        elif op_name == "assign_id":
            ctrl.assign_id(tuple(op["path"]), op["id"])
        elif op_name == "create_reference":
            ctrl.create_reference(
                tuple(op["target_path"]),
                op["target_id"], op["ref_id"])
        # Symbols P2 operations (SYMBOLS.md §7). Value-in-op: the ids
        # and paths are read literally from the fixture payload,
        # exactly like the create_reference arm.
        elif op_name == "make_symbol":
            ctrl.make_symbol(
                tuple(op["path"]), op["master_id"], op["ref_id"])
        elif op_name == "place_instance":
            ctrl.place_instance(op["master_id"], op["ref_id"])
        elif op_name == "detach":
            ctrl.detach(tuple(op["path"]))
        elif op_name == "redefine":
            ctrl.redefine(
                op["master_id"], tuple(op["path"]), op["ref_id"])
        elif op_name == "delete_symbol":
            ctrl.delete_symbol(op["master_id"])
        # Symbols P4 (SYMBOLS.md §4 / Fork F2). Value-in-op: the
        # instance transform is carried in the payload as {a,b,c,d,e,f}
        # (the same matrix shape parsed elsewhere) and applied verbatim.
        elif op_name == "set_instance_transform":
            from geometry.element import Transform
            t = op["transform"]
            ctrl.set_instance_transform(
                tuple(op["path"]),
                Transform(a=t["a"], b=t["b"], c=t["c"],
                          d=t["d"], e=t["e"], f=t["f"]))
        elif op_name == "delete_selection":
            model.document = model.document.delete_selection()
        elif op_name == "lock_selection":
            ctrl.lock_selection()
        elif op_name == "unlock_all":
            ctrl.unlock_all()
        elif op_name == "hide_selection":
            ctrl.hide_selection()
        elif op_name == "show_all":
            ctrl.show_all()
        elif op_name == "snapshot":
            model.snapshot()
        elif op_name == "undo":
            model.undo()
        elif op_name == "redo":
            model.redo()
        else:
            self.fail(f"Unknown op: {op_name}")

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
