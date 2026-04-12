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
from geometry.svg import document_to_svg, svg_to_document
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
            "multi_layer", "complex_document",
        ]
        for name in names:
            expected = _read_fixture(f"expected/{name}.json")
            doc = test_json_to_document(expected)
            actual = document_to_test_json(doc)
            self.assertEqual(actual, expected,
                f"JSON round-trip '{name}' failed: canonical JSON changed")

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

            for op in tc["ops"]:
                op_name = op["op"]
                if op_name == "select_rect":
                    ctrl.select_rect(
                        op["x"], op["y"], op["width"], op["height"],
                        extend=op.get("extend", False))
                elif op_name == "move_selection":
                    ctrl.move_selection(op["dx"], op["dy"])
                elif op_name == "copy_selection":
                    ctrl.copy_selection(op["dx"], op["dy"])
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

            actual = document_to_test_json(model.document)
            self.assertEqual(actual, expected,
                f"Operation test '{name}' failed")

    def test_operation_select_and_move(self):
        self._run_operation_fixture("select_and_move.json")

    def test_operation_undo_redo_laws(self):
        self._run_operation_fixture("undo_redo_laws.json")

    def test_operation_controller_ops(self):
        self._run_operation_fixture("controller_ops.json")

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
