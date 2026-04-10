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
from geometry.test_json import document_to_test_json

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

    def test_operation_select_and_move(self):
        json_str = _read_fixture("operations/select_and_move.json")
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
                elif op_name == "delete_selection":
                    model.document = model.document.delete_selection()
                elif op_name == "snapshot":
                    model.snapshot()
                elif op_name == "undo":
                    model.undo()
                elif op_name == "redo":
                    model.redo()
                else:
                    self.fail(f"Unknown op: {op_name}")

            actual = document_to_test_json(model.document)
            self.assertEqual(
                actual, expected,
                f"Operation test '{name}' failed",
            )


    def test_operation_undo_redo_laws(self):
        json_str = _read_fixture("operations/undo_redo_laws.json")
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
                elif op_name == "delete_selection":
                    model.document = model.document.delete_selection()
                elif op_name == "snapshot":
                    model.snapshot()
                elif op_name == "undo":
                    model.undo()
                elif op_name == "redo":
                    model.redo()

            actual = document_to_test_json(model.document)
            self.assertEqual(actual, expected,
                f"Operation test '{name}' failed")


if __name__ == "__main__":
    absltest.main()
