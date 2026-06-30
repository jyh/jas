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
    state_defaults_json, shortcut_structure_json,
)
from workspace.layout_apply import layout_apply
from workspace_interpreter.panel_layout import layout_panel
from workspace_interpreter.widget_tree import widget_tree
from workspace_interpreter.menu_state import menu_state
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
            # CONCEPTS.md 3b: a Generated concept-instance (concept id + params)
            # round-trips byte-identically to the Rust-authored golden — the
            # cross-language pin for the generated kind.
            "generated_polygon",
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
            # CONCEPTS.md 3b: a Generated concept-instance round-trips through
            # the binary codec (concept slot 8, params-json slot 9).
            "generated_polygon",
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
    # Gesture equivalence corpus (CROSS_LANGUAGE_TESTING.md §3a; mirrors
    # the Operation equivalence corpus above, but drives the CanvasTool
    # seam — raw pointer events through a YamlTool — instead of op_apply).
    # A gesture fixture replays a sequence of pointer events against a
    # tool built from the workspace spec and serializes the resulting
    # document via document_to_test_json, byte-comparing against the
    # Rust-authored golden under test_fixtures/gestures/.
    #
    # Identity-view convention: the Model loads with the default
    # (identity) view, so the event x/y ARE document coordinates
    # (_pointer_payload computes doc_x == x when zoom == 0 and
    # view_offset == 0). shift/alt default to false; `dragging` defaults
    # to false on move events.
    #
    # Self-bracketing: each tool that mutates the document does its own
    # `doc.snapshot` (rect.yaml's on_mouseup), so the gesture runner does
    # NOT wrap events in begin_txn/commit_txn — unlike the operation
    # runner, which owns the transaction bracket. Mirrors the Rust
    # run_gesture_model / assert_gesture_test / gesture_corpus.
    # ---------------------------------------------------------------

    # The gesture fixture files under test_fixtures/gestures/.
    # Inc-1 was just the rectangle-draw gesture; inc-2 adds the five
    # remaining draw tools (line, ellipse, rounded_rect, polygon, star).
    # Order mirrors the Rust GESTURE_FIXTURES list so the corpus stays
    # comparable.
    _GESTURE_FIXTURES = [
        "draw_rect.json",
        "draw_line.json",
        "draw_ellipse.json",
        "draw_rounded_rect.json",
        "draw_polygon.json",
        "draw_star.json",
        # Selection-family (§5 rec 4): a click-select drives the selection
        # tool's doc-space hit_test (which element is under the point) — the
        # cross-app hit-test parity gate. Click center of rect0 -> path [0,0].
        "select_click.json",
        # Marquee-select (§5 rec 4): press on EMPTY space (hit_test==null)
        # enters marquee mode; mouseup commits doc.select_in_rect over the
        # normalized marquee bounds. Drag encloses both rects -> [0,0]+[0,1].
        "select_marquee.json",
        # Blob Brush paint with an app-level fill precondition (the
        # hollow-blob regression gate). The case sets `app_state`:
        # {fill_color:#ff0000, blob_brush_size:10}, which the runner
        # routes through the production app-state -> tool-store bridge
        # (StateStore.seed_globals_from via ToolContext.app_state) before
        # the gesture — exactly as the canvas does. The committed Path
        # MUST carry fill=red; before the bridge existed the blob
        # committed fill=null (hollow). Pins the white/null fill contract
        # cross-language. See BLOB_BRUSH_TOOL.md.
        "blob_paint_fill.json",
        # Paintbrush paint with app-level options (the paintbrush_*
        # disconnect gate). app_state sets paintbrush_fidelity:3 (=>
        # fit_error 5.0, a SMOOTHED fit) + paintbrush_fill_new_strokes:true
        # + fill_color, routed through the production app-state -> tool-store
        # bridge (StateStore.seed_globals_from via ToolContext.app_state).
        # The committed Path must be filled blue AND smoothed; before the
        # paintbrush_* keys were bridged the live tool used fit_error=0 (no
        # smoothing) and dropped the fill. See PAINTBRUSH_TOOL.md.
        "paintbrush_paint_fill.json",
    ]

    @staticmethod
    def _build_gesture_tool(tool_id: str):
        # Build the YamlTool for tool_id from the compiled workspace
        # bundle (the same bundle the running app loads), so the corpus
        # tracks the bundle in CI. Mirrors the Rust build_gesture_tool.
        from tools.yaml_tool import YamlTool
        repo_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), ".."))
        with open(os.path.join(repo_root, "workspace", "workspace.json")) as f:
            data = json.load(f)
        spec = data.get("tools", {}).get(tool_id)
        assert spec is not None, f"workspace declares no tool '{tool_id}'"
        tool = YamlTool.from_workspace_tool(spec)
        assert tool is not None, f"tool spec '{tool_id}' failed to parse"
        return tool

    def _run_gesture_model(self, tc):
        # Load the setup SVG into a Model under the default identity view,
        # build the tool from the workspace spec, activate it, then
        # dispatch each event through the CanvasTool seam. Mirrors the
        # Rust run_gesture_model.
        from tools.tool import ToolContext
        setup_svg = _read_fixture(f"svg/{tc['setup_svg']}")
        model = Model(document=svg_to_document(setup_svg))
        ctrl = Controller(model=model)
        # Optional `app_state` precondition (the blob_paint_fill gate):
        # build a throwaway global state store from the case's app-level
        # values (fill_color, blob_brush_*) and thread it through the
        # ToolContext.app_state seam so the YamlTool runs the SAME
        # production bridge (StateStore.seed_globals_from in _dispatch)
        # the canvas uses. A blob paint without this would commit
        # fill=None (hollow). Cases without app_state pass None — the
        # tool then reads its own seeded white-fill default.
        app_state = None
        case_app_state = tc.get("app_state")
        if isinstance(case_app_state, dict):
            app_state = StateStore(dict(case_app_state))
        # The rect gesture uses no hit-testing; pass inert callbacks so
        # ToolContext stays a faithful (live-document) headless seam.
        ctx = ToolContext(
            model=model,
            controller=ctrl,
            hit_test_selection=lambda x, y: False,
            hit_test_handle=lambda x, y: None,
            hit_test_text=lambda x, y: None,
            hit_test_path_curve=lambda x, y: None,
            request_update=lambda: None,
            app_state=app_state,
        )
        tool = self._build_gesture_tool(tc["tool"])
        tool.activate(ctx)
        for ev in tc["events"]:
            x = float(ev["x"])
            y = float(ev["y"])
            # shift/alt default false; dragging defaults false.
            shift = bool(ev.get("shift", False))
            alt = bool(ev.get("alt", False))
            kind = ev["kind"]
            if kind == "press":
                tool.on_press(ctx, x, y, shift, alt)
            elif kind == "move":
                dragging = bool(ev.get("dragging", False))
                tool.on_move(ctx, x, y, shift, alt, dragging)
            elif kind == "release":
                tool.on_release(ctx, x, y, shift, alt)
            else:
                self.fail(f"unknown gesture event kind: {kind!r}")
        return model

    def _assert_gesture_test(self, tc):
        # Replay the gesture and byte-compare the canonical document JSON
        # against the pinned golden, dumping EXPECTED/ACTUAL on mismatch.
        # Mirrors the Rust assert_gesture_test.
        name = tc["name"]
        expected = _read_fixture(f"gestures/{tc['expected_json']}")
        actual = document_to_test_json(self._run_gesture_model(tc).document)
        if actual != expected:
            print(f"=== EXPECTED ({name}) ===")
            print(expected)
            print(f"=== ACTUAL ({name}) ===")
            print(actual)
        self.assertEqual(actual, expected,
            f"Gesture test '{name}' failed: canonical JSON mismatch")

    def test_gesture_corpus(self):
        # Inc-1 = draw_rect: a press/move/release drives the rect YamlTool
        # to add a rect (10,20)-(110,70) over circle_basic.svg; the result
        # must byte-match the Rust golden.
        for fixture in self._GESTURE_FIXTURES:
            for tc in json.loads(_read_fixture(f"gestures/{fixture}")):
                self._assert_gesture_test(tc)

    def test_gesture_alt_at_press_copy_is_one_undo_step(self):
        # ALT-COPY undo through the production CanvasTool seam — the PATH A
        # (Alt held AT press, drag-to-duplicate) analog of the Rust
        # gesture_alt_mid_drag_copy_is_one_undo_step. This is the alt-copy
        # gesture the Python seam CAN drive end-to-end: the first mousemove
        # journals copy_selection (selection.yaml on_mousemove branch A,
        # alt_held set at press), and the subsequent mousemove frames journal
        # move_selection deltas that the NEW commit_txn Branch A coalescer folds
        # into the copy op's own dx/dy. The whole press->move->move->release
        # gesture is therefore exactly ONE undo step: copy_selection(dx:44).
        #
        # PATH B (Alt pressed MID-drag, the Rust test's exact path) is now
        # ALSO driveable end-to-end: CanvasTool.on_move carries `alt`
        # (signature `on_move(ctx, x, y, shift, alt, dragging)` — production
        # canvas.py and the gesture harness both thread alt on move events),
        # matching Rust's `on_move(model, x, y, shift, alt, dragging)`. See
        # test_gesture_alt_mid_drag_copy_is_one_undo_step below.
        #
        # Oracle: the document the gesture must undo back to — captured by
        # driving ONLY the selecting press (selects, commits nothing), so it
        # includes the post-select selection the first-move snapshot saw.
        before_drag = document_to_test_json(self._run_gesture_model({
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [{"kind": "press", "x": 36, "y": 36}],
        }).document)

        tc = {
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [
                {"kind": "press",   "x": 36, "y": 36, "alt": True},
                {"kind": "move",    "x": 50, "y": 36, "dragging": True,
                 "alt": True},
                {"kind": "move",    "x": 60, "y": 36, "dragging": True,
                 "alt": True},
                {"kind": "move",    "x": 80, "y": 36, "dragging": True,
                 "alt": True},
                {"kind": "release", "x": 80, "y": 36, "alt": True},
            ],
        }

        model = self._run_gesture_model(tc)
        after = document_to_test_json(model.document)
        self.assertNotEqual(after, before_drag,
            "the alt-drag must have produced a copy")
        self.assertTrue(model.can_undo,
            "the gesture committed an undoable transaction")
        self.assertEqual(model.journal_head, 1,
            "alt-at-press drag-to-duplicate must be exactly ONE undo step "
            "(commit_txn Branch A folds the trailing moves into the copy)")
        self.assertEqual(model.journal[-1].ops[-1].op, "copy_selection",
            "the single undo step is the copy")

        model.undo()
        self.assertEqual(document_to_test_json(model.document), before_drag,
            "one undo must restore the original and remove the copy")
        self.assertFalse(model.can_undo,
            "after one undo the journal cursor is back at the origin "
            "(lock-step)")
        self.assertEqual(model.journal_head, 0, "cursor back at origin")

    def test_gesture_alt_mid_drag_copy_is_one_undo_step(self):
        # PATH B — Alt pressed MID-drag (the user's exact gesture, and the
        # Rust gesture_alt_mid_drag_copy_is_one_undo_step analog): drag the
        # original, THEN hold Option, then keep dragging the copy, then
        # release. Now driveable end-to-end because CanvasTool.on_move carries
        # `alt` through the seam (production canvas.py + this harness), so the
        # mid-drag alt move reaches selection.yaml's mid-drag copy branch and
        # journals copy_selection. The per-frame drag coalescer refuses to
        # bridge across the copy and Rule 2
        # (_drop_round_tripped_move_before_copy) drops the pre-copy
        # round-tripped move, so the whole select->drag->alt->move->release
        # gesture collapses to exactly ONE undo step.
        #
        # Oracle: the document the gesture must undo back to — captured by
        # driving ONLY the selecting press (selects, commits nothing), so it
        # includes the post-select selection the first-move snapshot saw.
        before_drag = document_to_test_json(self._run_gesture_model({
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [{"kind": "press", "x": 36, "y": 36}],
        }).document)

        tc = {
            "setup_svg": "two_rects.svg",
            "tool": "selection",
            "events": [
                {"kind": "press",   "x": 36, "y": 36},
                {"kind": "move",    "x": 50, "y": 36, "dragging": True},
                {"kind": "move",    "x": 60, "y": 36, "dragging": True},
                {"kind": "move",    "x": 60, "y": 36, "dragging": True,
                 "alt": True},
                {"kind": "move",    "x": 80, "y": 36, "dragging": True,
                 "alt": True},
                {"kind": "release", "x": 80, "y": 36, "alt": True},
            ],
        }

        model = self._run_gesture_model(tc)
        after = document_to_test_json(model.document)
        self.assertNotEqual(after, before_drag,
            "the alt-drag must have produced a copy")
        self.assertTrue(model.can_undo,
            "the gesture committed an undoable transaction")
        self.assertEqual(model.journal_head, 1,
            "select->drag->alt->move->release must be exactly ONE undo step")
        self.assertEqual(model.journal[-1].ops[-1].op, "copy_selection",
            "the single undo step is the copy")

        model.undo()
        self.assertEqual(document_to_test_json(model.document), before_drag,
            "one undo must restore the original and remove the copy")
        self.assertFalse(model.can_undo,
            "after one undo the journal cursor is back at the origin "
            "(lock-step)")
        self.assertEqual(model.journal_head, 0, "cursor back at origin")

    # ---------------------------------------------------------------
    # ACTION equivalence corpus (CROSS_LANGUAGE_TESTING.md §3b; sibling
    # to the GESTURE corpus above and the OPERATIONS corpus below).
    # Where the gesture corpus drives the CanvasTool seam (press / move /
    # release) and the operation corpus drives op_apply directly, this
    # corpus drives the ACTION seam: the panel/menu/dialog `action` verbs
    # the live UI dispatches, which RESOLVE to ops/effects.
    #
    # Production seam (this app): the live layers panel routes the
    # `toggle_all_layers_visibility` verb through
    # ``panels.panel_menu._dispatch_yaml_layers_action`` (panel_menu.py
    # cmd-routing branch, ~line 702 — the SAME headless-safe dispatcher
    # production_route_journal_test drives). That dispatcher is the
    # Python analog of Rust's generic ``dispatch_action``: it looks the
    # action up in the compiled workspace bundle, builds the
    # ``active_document`` eval context, registers the snapshot + doc.set
    # platform handlers, and runs the action's ``effects`` through
    # ``run_effects`` (passing ``model`` + ``action_name`` so the runner
    # OWNS and NAMES the undo transaction). We drive THAT path, not a
    # test-only shortcut, so passing here proves the real production
    # route. Mirrors the Rust ``run_action_model`` / ``assert_action_test``
    # / ``action_corpus``.
    #
    # Fixture format (test_fixtures/actions/<name>.json) — a JSON array
    # of cases, each:
    #   {
    #     "name":        "<case id>",
    #     "setup_svg":   "<file under test_fixtures/svg/>",
    #     "actions":     [ {"action": "<action_id>",
    #                       "params": { <resolved literals> }}, ... ],
    #     "expected_json": "<file under test_fixtures/actions/>"
    #   }
    # Each entry in `actions` is dispatched in order through the
    # production dispatcher; the FINAL document is serialized with
    # document_to_test_json and byte-compared to the pinned golden —
    # identical to the gesture corpus's assertion shape.
    #
    # SELECTION SETUP: an action that operates on the selection expresses
    # it as a LEADING select_* action in the same `actions` list — a verb
    # the UI itself dispatches — so setup stays on the production dispatch
    # path and inside the journaled-state model (selection is serialized
    # Document state, OP_LOG.md §7). The first seeded case
    # (`toggle_all_layers_visibility`) needs NO selection: it folds over
    # ALL top-level layers, so its `actions` list is a single verb with
    # empty params.
    #
    # TRANSACTION BRACKETING: actions self-bracket. A document-mutating
    # action opens its undo transaction via the `snapshot` effect (which
    # `_dispatch_yaml_layers_action` maps to `model.begin_txn`) and
    # `run_effects` commits it once at the end (naming it with the action
    # verb). So — exactly like the gesture runner, and UNLIKE the
    # operation runner which owns the bracket — the action runner does
    # NOT wrap dispatch in begin_txn/commit_txn.
    # ---------------------------------------------------------------

    # The action fixture files under test_fixtures/actions/. Inc-2
    # (foundation) seeds the simplest faithful document-affecting action:
    # the layers-panel "toggle all layers visibility" verb. Order mirrors
    # the Rust ACTION_FIXTURES list so the corpus stays comparable.
    _ACTION_FIXTURES = [
        "toggle_all_layers_visibility.json",
        "toggle_all_layers_lock.json",
        "toggle_all_layers_outline.json",
        "new_layer.json",
        "make_compound_shape.json",
        "align.json",
        "boolean.json",
        "new_artboard.json",
        "new_symbol.json",
        "place_instance.json",
        "place_concept_instance.json",
        "menu_object_ops.json",
    ]

    @staticmethod
    def _dispatch_action(action_name: str, params: dict, model,
                         selected_master=None, selected_concept=None):
        # Drive ONE action through THIS app's production dispatcher (the
        # Python analog of Rust's generic dispatch_action). The live
        # layers panel routes its menu verbs through
        # _dispatch_yaml_layers_action, which owns + names + commits the
        # undo transaction the action's `snapshot` effect opens. Mirrors
        # the per-step body of the Rust run_action_model loop.
        #
        # SYMBOLS.md §7 — the symbol-mutating verbs (new_symbol /
        # place_instance) are pure-native intercepts whose YAML action is a
        # `log` stub, so the generic layers dispatcher never reaches them.
        # The live app carries the panel-selected master across actions on
        # AppState.symbols_selected; this harness has no app-state, so a
        # mutable holder (`selected_master`, a one-element list threaded
        # from _run_action_model) plays that role: new_symbol resolves +
        # stores the new master id, place_instance reads it back as the
        # apply_place_instance master PARAM. Mirrors the Rust dispatch_action
        # symbols intercept threading st.symbols_selected across the steps.
        if action_name == "new_symbol":
            from jas.panels.symbols_apply import apply_new_symbol
            mid = apply_new_symbol(model)
            if selected_master is not None and mid:
                selected_master[0] = mid
            return
        if action_name == "place_instance":
            from jas.panels.symbols_apply import apply_place_instance
            apply_place_instance(
                model, selected_master[0] if selected_master else None)
            return
        # CONCEPTS.md §6 — the concept-mutating verb (place_concept_instance)
        # is a pure-native intercept whose YAML action is a `log` stub, exactly
        # like the symbol verbs above. The live app carries the panel-selected
        # concept across actions on AppState.concepts_selected; this harness has
        # no app-state, so the mutable `selected_concept` holder plays that role:
        # concepts_panel_select stores the selected concept id, and
        # place_concept_instance reads it back as the apply_place_concept_instance
        # concept_id PARAM. Mirrors the Rust dispatch_action concepts intercept.
        if action_name == "concepts_panel_select":
            cid = params.get("concept_id") if params else None
            if selected_concept is not None and cid:
                selected_concept[0] = cid
            return
        if action_name == "place_concept_instance":
            from jas.panels.concepts_apply import apply_place_concept_instance
            apply_place_concept_instance(
                model, selected_concept[0] if selected_concept else None)
            return
        # Object / Edit menu model-pure verbs are bespoke-native: their
        # actions.yaml entries are `log` stubs (the real behavior lives in
        # menu.menu — see _on_menu_action), so the generic layers dispatcher
        # would no-op them. Route them to the SAME native handlers the menu
        # invokes, so the action corpus gates their cross-app document
        # mutation. Mirrors the symbols / concepts intercepts above.
        _MENU_NATIVE_HANDLERS = {
            "select_all": "_select_all",
            "group": "_group_selection",
            "ungroup": "_ungroup_selection",
            "ungroup_all": "_ungroup_all",
            "lock": "_lock_selection",
            "unlock_all": "_unlock_all",
            "hide_selection": "_hide_selection",
            "show_all": "_show_all",
            "make_instance": "_link_to_selection",
        }
        if action_name in _MENU_NATIVE_HANDLERS:
            import menu.menu as _menu_mod
            getattr(_menu_mod, _MENU_NATIVE_HANDLERS[action_name])(model)
            return

        from panels.panel_menu import _dispatch_yaml_layers_action
        _dispatch_yaml_layers_action(action_name, model, params=params)

    def _run_action_model(self, tc):
        # Load the setup SVG into a Model, then dispatch each `actions[i]`
        # through the production dispatcher in order, passing the case's
        # resolved params (defaulting to empty). Returns the Model so
        # future cases that need more than the document (panel selection,
        # journal/txn-name assertions) can reach it. Mirrors the Rust
        # run_action_model, which returns the whole AppState.
        setup_svg = _read_fixture(f"svg/{tc['setup_svg']}")
        model = Model(document=svg_to_document(setup_svg))
        # Seed a canvas selection if the case declares one (a list of element
        # paths, e.g. [[0,0],[0,1]]). Selection-dependent verbs (compound shape,
        # align, boolean) consume model.document.selection, which `select_all`
        # cannot set through the shared YAML dispatch (it is a native `log:`
        # intercept). Use the non-undoable writer so the seed is not part of the
        # action's undo step. Mirrors run_action_model in the other three apps.
        if tc.get("selection"):
            import dataclasses
            from document.document import ElementSelection
            sel = frozenset(
                ElementSelection.all(tuple(p)) for p in tc["selection"])
            model.set_document_unbracketed(
                dataclasses.replace(model.document, selection=sel))
        # Install a fresh deterministic id source (a per-char counter
        # returning 0,1,2,... on successive calls) so verbs that mint ids
        # (e.g. new_artboard) produce reproducible, golden-pinned ids:
        # the first 8 draws give chars [0..7] = "01234567". A fresh
        # counter per call resets to 0; cleared in finally so production
        # entropy is restored and other tests are unaffected. Mirrors the
        # Rust harness id-source convention.
        from document.artboard import set_test_id_rng
        _ctr = [0]
        def _counter():
            v = _ctr[0]
            _ctr[0] += 1
            return v
        set_test_id_rng(_counter)
        # Mutable holder mirroring the live app's AppState.symbols_selected:
        # carries the panel-selected symbol master across the action sequence
        # so a later place_instance targets the master an earlier new_symbol
        # promoted (the harness has no app-state otherwise). See
        # _dispatch_action for the per-verb symbol intercept.
        selected_master = [None]
        # Parallel holder for the panel-selected concept (CONCEPTS.md §6),
        # mirroring the live app's AppState.concepts_selected: carries the
        # selected concept across the action sequence so a later
        # place_concept_instance targets the concept an earlier
        # concepts_panel_select picked. See _dispatch_action.
        selected_concept = [None]
        try:
            for step in tc["actions"]:
                action = step["action"]
                params = step.get("params", {}) or {}
                self._dispatch_action(action, params, model,
                                      selected_master=selected_master,
                                      selected_concept=selected_concept)
        finally:
            set_test_id_rng(None)
        return model

    def _assert_action_test(self, tc):
        # Replay the action sequence and byte-compare the canonical
        # document JSON against the pinned golden, dumping EXPECTED/ACTUAL
        # on mismatch. Mirrors the Rust assert_action_test.
        name = tc["name"]
        expected = _read_fixture(f"actions/{tc['expected_json']}")
        actual = document_to_test_json(self._run_action_model(tc).document)
        if actual != expected:
            print(f"=== EXPECTED ({name}) ===")
            print(expected)
            print(f"=== ACTUAL ({name}) ===")
            print(actual)
        self.assertEqual(actual, expected,
            f"Action test '{name}' failed: canonical JSON mismatch")

    def test_action_corpus(self):
        # Inc-2 = toggle_all_layers_visibility: a single no-param verb
        # over multi_layer.svg flips both top-level layers from the
        # implicit "preview" default to "invisible" via the action's
        # foreach + doc.set effects; the result must byte-match the
        # Rust-authored golden.
        for fixture in self._ACTION_FIXTURES:
            for tc in json.loads(_read_fixture(f"actions/{fixture}")):
                self._assert_action_test(tc)

    # ---------------------------------------------------------------
    # KEY-RESOLUTION corpus (TESTING_STRATEGY.md §5 rec 3)
    # ---------------------------------------------------------------
    # Sibling to the GESTURE and ACTION corpora above. Where those drive
    # the canvas-tool seam (press/move/release) and the dispatch_action
    # seam, this corpus pins the PURE key->action RESOLUTION step:
    # resolve_key(chord) maps a normalized, framework-neutral key chord
    # {key, ctrl, shift, alt, meta} to the bundle `shortcuts` table's
    # {action, params} (or null). The framework event -> chord BINDING
    # stays on the manual floor (§5); only resolution is byte-gated here.
    #
    # Unlike the gesture/action corpora the output is NOT a document — it
    # is the resolved command itself, so there is no setup_svg and no
    # dispatch. Each fixture group lists `cases` (a name + chord); the
    # runner resolves every chord against the once-loaded bundle
    # `shortcuts` array and emits a CANONICAL JSON array of {name, result}
    # (sorted object keys, compact separators) compared to the
    # Rust-generated golden. The canonicalization (json.dumps with
    # sort_keys + compact separators) sorts object keys so the byte
    # comparison is order-independent and identical across the four apps.
    # Mirrors the Rust run_key_test / assert_key_test / key_corpus.
    # ---------------------------------------------------------------

    # Key-resolution fixture files under test_fixtures/keys/. Order
    # mirrors the Rust KEY_FIXTURES list so the corpus stays comparable.
    _KEY_FIXTURES = [
        "key_resolution.json",
    ]

    @staticmethod
    def _canon_key_json(obj) -> str:
        # Canonical serializer for the key corpus: object keys in sorted
        # order, arrays in document order, COMPACT (no spaces), standard
        # JSON string escaping. json.dumps with sort_keys + the (',', ':')
        # separators reproduces the Rust canon_value byte-for-byte
        # (nested params sort too because sort_keys recurses). ensure_ascii
        # is left at its default (True), matching serde_json's ASCII
        # escaping for the resolved-command strings in this table.
        return json.dumps(obj, separators=(",", ":"), sort_keys=True)

    @staticmethod
    def _run_key_test(group: dict) -> str:
        # Resolve every chord in a fixture group against the once-loaded
        # bundle `shortcuts` table and return the canonical result array.
        # Mirrors the Rust run_key_test: load the bundle shortcuts once,
        # resolve each case's chord, wrap as {action, params} | null.
        from workspace.key_resolver import make_chord, resolve_key_in
        from panels.yaml_menu import get_workspace_data
        ws = get_workspace_data() or {}
        shortcuts = ws.get("shortcuts")
        if not isinstance(shortcuts, list):
            shortcuts = []
        arr = []
        for case in group["cases"]:
            ch = case["chord"]
            chord = make_chord(
                ch["key"],
                bool(ch.get("ctrl", False)),
                bool(ch.get("shift", False)),
                bool(ch.get("alt", False)),
                bool(ch.get("meta", False)),
            )
            cmd = resolve_key_in(chord, shortcuts)
            # null when unmapped, else {action, params}.
            arr.append({"name": case["name"], "result": cmd})
        return CrossLanguageTest._canon_key_json(arr)

    def _assert_key_test(self, group: dict):
        # Replay a key fixture group and byte-compare the canonical result
        # array against the pinned golden, dumping EXPECTED/ACTUAL on
        # mismatch. Mirrors the Rust assert_key_test.
        name = group["name"]
        expected = _read_fixture(f"keys/{group['expected_json']}")
        actual = self._run_key_test(group)
        if actual != expected:
            print(f"=== EXPECTED ({name}) ===")
            print(expected)
            print(f"=== ACTUAL ({name}) ===")
            print(actual)
        self.assertEqual(actual, expected,
            f"Key test '{name}' failed: canonical JSON mismatch")

    def test_key_corpus(self):
        # The pure key->action resolver pinned cross-language: each chord
        # in key_resolution.json resolves against the bundle `shortcuts`
        # table to {action, params} | null; the canonical result array
        # must byte-match the Rust-authored golden.
        for fixture in self._KEY_FIXTURES:
            for group in json.loads(_read_fixture(f"keys/{fixture}")):
                self._assert_key_test(group)

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

    def test_operation_id_primary_move(self):
        # OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary op-addressing flip. The
        # fixture carries TWO cases on the SAME ``eye.svg`` pointing at the SAME
        # golden:
        #   - ``selrel_move_eye``    : [select_rect, move_selection]   (sel-rel)
        #   - ``id_primary_move_eye``: [select_by_ids, move_by_ids]    (id-primary)
        # Both must produce a BYTE-IDENTICAL document AND selection (the golden is
        # shared), which proves the id-primary verbs replay to the same
        # document+selection as the selection-relative pair — the byte-gate
        # reconciliation. The unchanged checkpoint_equivalence gate (run per case
        # by ``_run_operation_fixture``) additionally proves each journals a
        # replay-safe segment. The id-primary verb reads its operand ids from its
        # OWN params, so snapshot and replay apply identical operands (the §7
        # determinism rule).
        self._run_operation_fixture("id_primary_move.json")

    def test_operation_id_primary_copy(self):
        # OP_LOG.md §5 Fork 4 / 3c-1 — the id-primary copy verb. Same shared-golden
        # shape as ``test_operation_id_primary_move``: [select_rect,
        # copy_selection] and [select_by_ids, copy_by_ids] produce a byte-identical
        # document (the copy is born id-less on BOTH paths) AND selection.
        self._run_operation_fixture("id_primary_copy.json")

    def test_id_primary_move_reads_operand_from_params_not_selection(self):
        # 3c-1 determinism check (OP_LOG.md §7): an id-primary op reads its operand
        # ids from its OWN params, NEVER from ``doc.selection``, so it applies the
        # SAME operands regardless of the ambient selection. Drive
        # ``move_by_ids{["eye"]}`` with a DELIBERATELY WRONG ambient selection (the
        # whole layer pre-selected) and confirm the result still equals the shared
        # golden — i.e. the op ignored the ambient selection and moved exactly the
        # operand named in its params.
        from document.document import ElementSelection
        setup_svg = _read_fixture("svg/eye.svg")
        model = Model(document=svg_to_document(setup_svg))
        ctrl = Controller(model=model)
        # Poison the ambient selection with an unrelated path — an op that inferred
        # its operand from doc.selection would act on the wrong thing.
        ctrl.set_selection(frozenset({ElementSelection.all((0,))}))
        model.begin_txn()
        op_apply(model, {"op": "select_by_ids", "ids": ["eye"]})
        op_apply(model, {"op": "move_by_ids", "ids": ["eye"], "dx": 50, "dy": 0})
        model.commit_txn()
        actual = document_to_test_json(model.document)
        expected = _read_fixture("operations/id_primary_move_eye.json")
        self.assertEqual(actual, expected,
            "id-primary move read its operand from params, not the ambient "
            "selection")

        # Snapshot==replay even though the snapshot ran with a poisoned ambient
        # selection: the journaled ops carry their own operands, so a fresh replay
        # (no ambient selection) reproduces the document byte-identically.
        replayed = self._replay_journal(
            setup_svg, model.journal, model.journal_head)
        self.assertEqual(replayed, actual,
            "id-primary op applies identical operands on snapshot and replay")

    def test_id_primary_capture_recipe_rederives_on_source_edit(self):
        # 3c-1 EYE-DEMO RE-DERIVATION PIN (the load-bearing payoff): run a FAITHFUL
        # id-primary journal segment [select_by_ids, copy_by_ids] through the SHARED
        # dispatcher (so it is a real, byte-gated, replayable journal segment),
        # normalize the committed segment to a RecordedElem via the now-pass-through
        # capture_recipe, edit the SOURCE input, re-derive, and confirm the output
        # TRACKS the edited source. The recipe survives source edits with NO
        # selection dependency — the operand ids came from the op params
        # (from:["eye"]), never from a select op's resolved selection. Reuses the
        # existing eye-demo golden (eye_demo_rederived.json): copy_by_ids{dx:50}
        # captures to copy{dx:50}, whose re-derivation against the edited source
        # (eye->x=100 px) is byte-identical to the selection-relative demo's
        # copy(0)+translate(50) net offset.
        from geometry.element import RecordedElem
        from geometry.live import capture_recipe, DEFAULT_PRECISION

        # A faithful id-primary demonstration: select the eye, copy it +50. This is
        # a REAL journal segment op_apply replays byte-identically (it is the
        # id_primary_copy fixture's id-primary case).
        setup_svg = _read_fixture("svg/eye.svg")
        model = Model(document=svg_to_document(setup_svg))
        model.begin_txn()
        model.name_txn("id-primary demo")
        op_apply(model, {"op": "select_by_ids", "ids": ["eye"]})
        op_apply(model, {"op": "copy_by_ids", "from": ["eye"], "dx": 50, "dy": 0})
        model.commit_txn()

        # capture_recipe is a PASS-THROUGH over the id-primary segment: it reads the
        # operand id from the op's ``from`` PARAM (no selection dependency —
        # select_by_ids' targets are NOT consulted).
        segment = model.journal[-1].ops
        # Guard: the captured segment is purely id-primary (proves the brittle
        # selection-relative bridge is NOT on this path).
        for op in segment:
            self.assertIn(op.op, ("select_by_ids", "copy_by_ids"),
                f"segment is id-primary, got {op.op}")
        recipe, inputs = capture_recipe(segment)
        self.assertEqual(inputs, ["eye"])
        self.assertEqual(len(recipe), 1)
        self.assertEqual(recipe[0].op, "copy")
        self.assertEqual(recipe[0].params["from"], ["eye"])

        # Wrap + re-derive against the EDITED source (eye moved to x=100 px).
        recorded = RecordedElem(
            ops=tuple(recipe), inputs=tuple(inputs), id="rec")
        edited_svg = setup_svg.replace('x="0" y="0"', 'x="100" y="0"')
        edited_el = svg_to_document(edited_svg).get_element((0, 0))

        class _OneResolver:
            def resolve(self, ref):
                return edited_el if ref == "eye" else None

        ps = recorded.evaluate_with(DEFAULT_PRECISION, _OneResolver(), set())
        actual = self._polygon_set_to_test_json(ps)
        # The re-derived output tracks the edited source — the SAME golden the
        # selection-relative eye demo pins (the net offset is identical).
        expected = _read_fixture("production_capture/eye_demo_rederived.json")
        self.assertEqual(actual, expected,
            "the id-primary recipe re-derived against the edited source, no "
            "selection dependency")

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

    # ---------------------------------------------------------------
    # Per-frame drag coalescing (OP_LOG.md §9 follow-up). A live drag commits
    # ONE transaction PER FRAME (selection.yaml fires doc.snapshot only on the
    # first mousemove; each on_mousemove is its own run_effects batch that
    # begin_txns + commits), so a drag of N frames lands as N consecutive
    # single-op move transactions in the journal — and N undo steps.
    # Model.commit_txn coalesces ADJACENT same-gesture move transactions
    # (move_selection / move_by_ids) into ONE summed-delta translate, collapsing
    # the N undo steps into one. The txns-form below commits each frame
    # SEPARATELY, so the SECOND commit triggers coalescing into the first.
    # Mirrors the Rust drag_coalesce* tests.
    # ---------------------------------------------------------------

    @staticmethod
    def _last_op_delta(txn):
        # The dx/dy of a journal transaction's LAST op (the move being summed).
        op = txn.ops[-1]

        def num(v):
            return float(v) if isinstance(v, (int, float)) else 0.0
        return (num(op.params.get("dx", 0.0)), num(op.params.get("dy", 0.0)))

    def _assert_drag_coalesce(self, tc):
        # Drive a coalescing fixture (txns-form, each frame committed separately)
        # and assert the post-coalesce journal shape + undo-step lock-step:
        #  - the journal collapsed to `expect_journal_txns` transactions;
        #  - the tip txn's op list is `expect_journal_ops` long (when declared);
        #  - the tip txn's last move op carries the SUMMED delta (when declared);
        #  - the undo stack and journal cursor are in lock-step
        #    (journal_head == expect_undo_steps), and undoing exactly that many
        #    times drains both back to the origin (can_undo False,
        #    journal_head == 0) — i.e. ONE undo reverts a whole coalesced drag.
        name = tc["name"]
        svg = _read_fixture(f"svg/{tc['setup_svg']}")
        doc = svg_to_document(svg)
        model = Model(document=doc)
        ctrl = Controller(model=model)
        for txn in tc["txns"]:
            model.begin_txn()
            if "name" in txn:
                model.name_txn(txn["name"])
            for op in txn["ops"]:
                self._apply_op(model, ctrl, op)
            model.commit_txn()

        expect_txns = tc["expect_journal_txns"]
        self.assertEqual(len(model.journal), expect_txns,
            f"[{name}] journal txn count")

        if "expect_journal_ops" in tc:
            tip = model.journal[-1]
            self.assertEqual(len(tip.ops), tc["expect_journal_ops"],
                f"[{name}] tip txn op count")
        if "expect_last_move_dx" in tc:
            dx = float(tc["expect_last_move_dx"])
            dy = float(tc.get("expect_last_move_dy", 0.0))
            gdx, gdy = self._last_op_delta(model.journal[-1])
            self.assertEqual((gdx, gdy), (dx, dy),
                f"[{name}] summed delta")

        # Undo-step lock-step: journal cursor == undo depth == declared steps.
        steps = tc["expect_undo_steps"]
        self.assertEqual(model.journal_head, steps,
            f"[{name}] journal_head (== undo steps)")
        for i in range(steps):
            self.assertTrue(model.can_undo, f"[{name}] expected to undo step {i}")
            model.undo()
        self.assertFalse(model.can_undo,
            f"[{name}] after {steps} undos the undo stack must be empty")
        self.assertEqual(model.journal_head, 0,
            f"[{name}] after {steps} undos the journal cursor must be at origin")

    def test_drag_coalesce(self):
        # (a)/(c)-twin coalescing pins + (c)-via-name/copy break pins, driven
        # from the shared drag_coalesce.json fixture (txns-form, cross-language).
        tests = json.loads(_read_fixture("operations/drag_coalesce.json"))
        for tc in tests:
            self._assert_drag_coalesce(tc)

    def test_drag_coalesce_net_zero(self):
        # (b) NET-ZERO whole-drag: a same-name same-target run that sums to (0,0)
        # AND round-trips the document leaves NO journal entry and NO undo step.
        # The selection is pre-established OUT OF BAND (non-undoable select_rect,
        # journaling nothing) so the two move frames are the ONLY journaled
        # transactions — and after the net-zero drop the journal is genuinely
        # EMPTY and the document is byte-identical to pre-drag.
        setup = _read_fixture("svg/eye.svg")
        model = Model(document=svg_to_document(setup))
        ctrl = Controller(model=model)

        # Pre-select the eye out of band (no journal entry, no undo step).
        ctrl.select_rect(-5.0, -5.0, 55.0, 55.0, extend=False)
        pre_drag = document_to_test_json(model.document)
        self.assertEqual(len(model.journal), 0,
            "out-of-band select must not journal")
        self.assertFalse(model.can_undo,
            "out-of-band select must not push an undo step")

        # Frame 1: move dx:5 (commits one txn into the empty journal).
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": 5, "dy": 0})
        model.commit_txn()
        self.assertEqual(len(model.journal), 1, "frame 1 journals one txn")
        self.assertTrue(model.can_undo, "frame 1 pushes one undo step")

        # Frame 2: move dx:-5 (same name, same target) -> net (0,0) round-trip.
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": -5, "dy": 0})
        model.commit_txn()

        self.assertEqual(len(model.journal), 0,
            "net-zero whole-drag must leave NO journal entry")
        self.assertEqual(model.journal_head, 0,
            "net-zero whole-drag leaves cursor at origin")
        self.assertFalse(model.can_undo,
            "net-zero whole-drag must leave NO undo step")
        self.assertEqual(document_to_test_json(model.document), pre_drag,
            "net-zero whole-drag must restore the pre-drag document byte-for-byte")

    def test_drag_coalesce_target_break(self):
        # (c) TARGET break (predicate c proper): two ADJACENT single-op move
        # frames whose target sets differ do NOT coalesce. The selection is
        # changed OUT OF BAND between the frames (so each frame is a single-op
        # move txn, isolating the target-mismatch predicate from the op-count
        # predicate), proving the run breaks and stays TWO distinct undo steps.
        from document.document import ElementSelection
        setup = _read_fixture("svg/two_ided_rects.svg")
        model = Model(document=svg_to_document(setup))
        ctrl = Controller(model=model)

        # Select element "a" (path [0,0]) out of band.
        ctrl.set_selection(frozenset({ElementSelection.all((0, 0))}))

        # Frame 1: move "a".
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": 5, "dy": 0})
        model.commit_txn()
        self.assertEqual(len(model.journal), 1)
        self.assertEqual(model.journal[0].ops[0].targets, ["a"],
            "frame 1 targets element a")

        # Change selection to "b" (path [0,1]) out of band — a DIFFERENT target.
        ctrl.set_selection(frozenset({ElementSelection.all((0, 1))}))

        # Frame 2: a single-op move on "b". Same name, same verb, but the
        # target set differs ([a] vs [b]) -> predicate (c) fails -> NO coalesce.
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": 7, "dy": 0})
        model.commit_txn()

        self.assertEqual(len(model.journal), 2,
            "different target must NOT coalesce -> two distinct txns")
        self.assertEqual(model.journal[1].ops[0].targets, ["b"],
            "frame 2 targets element b")
        self.assertEqual(model.journal_head, 2,
            "two distinct undo steps (lock-step)")
        dx0, _ = self._last_op_delta(model.journal[0])
        dx1, _ = self._last_op_delta(model.journal[1])
        self.assertEqual((dx0, dx1), (5.0, 7.0),
            "deltas stay separate (5 and 7), not summed")

    def test_drag_coalesce_post_undo_no_merge(self):
        # (guard) TIP guard (journal_head == len(op_journal)): a coalescable move
        # frame committed AFTER an undo — when the journal cursor sits BEHIND the
        # tip (journal_head < len) — must NOT merge into the about-to-be-truncated
        # redo tail. It must take the normal truncate/append path: the redo tail
        # is discarded and the new frame lands as its OWN txn with its OWN delta
        # (never summed into the stale tail). The sole signal for the TIP guard.
        from document.document import ElementSelection
        setup = _read_fixture("svg/two_ided_rects.svg")
        model = Model(document=svg_to_document(setup))
        ctrl = Controller(model=model)

        # Select element "a" (path [0,0]) out of band (no journal entry).
        ctrl.set_selection(frozenset({ElementSelection.all((0, 0))}))

        # Frame 1: a coalescable move (dx:5). Commits one txn at the tip.
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": 5, "dy": 0})
        model.commit_txn()
        self.assertEqual(len(model.journal), 1, "frame 1 journals one txn")
        self.assertEqual(model.journal_head, 1, "cursor at the tip after frame 1")

        # Undo frame 1: cursor moves BEHIND the tip (journal_head 0 < len 1) and
        # a redo entry is staged. This is the guard's scenario.
        model.undo()
        self.assertEqual(model.journal_head, 0,
            "undo moved the cursor behind the tip")
        self.assertEqual(len(model.journal), 1,
            "the undone txn is still the redo tail")
        self.assertTrue(model.can_redo, "frame 1 is available to redo")

        # Frame 2: a SAME name / SAME target / SAME verb coalescable move (dx:11)
        # — every predicate (a)-(e) holds EXCEPT the TIP guard, which fails
        # (journal_head 0 != len 1). So it must NOT coalesce: the normal path
        # truncates the redo tail and appends frame 2 as its own txn.
        model.begin_txn()
        model.name_txn("selection on_mousemove")
        self._apply_op(model, ctrl, {"op": "move_selection", "dx": 11, "dy": 0})
        model.commit_txn()

        # Normal truncate/append ran: redo tail discarded, frame 2 appended.
        self.assertEqual(len(model.journal), 1,
            "post-undo frame must truncate+append, NOT merge into the redo tail")
        self.assertEqual(model.journal_head, 1,
            "cursor advanced to the new tip (lock-step)")
        self.assertFalse(model.can_redo, "a new edit discards the redo tail")
        # The decisive guard signal: the surviving txn carries frame 2's delta
        # ALONE (11), never frame 1's (5) summed in (16). A regressed guard would
        # have merged into the stale tail and produced 16.
        dx, _ = self._last_op_delta(model.journal[0])
        self.assertEqual(dx, 11.0,
            "surviving txn carries frame 2's delta alone (11), not summed (16) "
            "— proves the TIP guard blocked the merge")
        # And undoing the single surviving step drains the journal in lock-step.
        model.undo()
        self.assertEqual(model.journal_head, 0,
            "one undo drains the single post-undo step")
        self.assertFalse(model.can_undo, "no further undo steps")

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

    def test_state_defaults(self):
        actual = state_defaults_json()
        self._assert_workspace_fixture("state_defaults", actual)

    def test_shortcut_structure(self):
        actual = shortcut_structure_json()
        self._assert_workspace_fixture("shortcut_structure", actual)

    # ---------------------------------------------------------------
    # Workspace operation equivalence tests
    # ---------------------------------------------------------------

    def _apply_workspace_op(self, layout: WorkspaceLayout, op: dict):
        # Thin shim over the RUNTIME layout dispatcher (3d-2). Production and
        # the harness share ONE dispatcher + ONE per-verb mutation body. The
        # corpus fixtures byte-gate the runtime dispatcher through this path.
        layout_apply(layout, op)

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
    # 3d-2 runtime dispatcher: production-route + no-panic tests
    # ---------------------------------------------------------------

    def test_production_route_through_layout_apply(self):
        """A REAL production layout handler (the per-panel hamburger-menu
        ``close_panel`` in panels.panel_menu.panel_dispatch) routes through the
        runtime ``layout_apply`` dispatcher: the resulting workspace
        serialization matches replaying the same op through the dispatcher
        directly, AND the dirty signal (needs_save) flips."""
        from panels.panel_menu import panel_dispatch

        setup_json = _read_fixture("expected/workspace_default.json")

        # Drive the production handler. panel_dispatch builds op_close_panel(addr)
        # and calls layout_apply, which invokes layout.close_panel (bumps).
        prod = test_json_to_workspace(setup_json)
        self.assertFalse(prod.needs_save(),
                         "fresh layout must start clean")
        addr = PanelAddr(group=GroupAddr(dock_id=0, group_idx=0), panel_idx=0)
        panel_dispatch(PanelKind.COLOR, "close_panel", addr, prod)

        # The dirty signal must have fired at the routed production site.
        self.assertTrue(prod.needs_save(),
                        "production close_panel must mark the layout dirty")

        # Replaying the same op straight through the runtime dispatcher must
        # produce a byte-identical serialization -- proving the production path
        # and the harness path share ONE mutation body.
        direct = test_json_to_workspace(setup_json)
        layout_apply(direct, {
            "op": "close_panel", "dock_id": 0, "group_idx": 0, "panel_idx": 0,
        })
        self.assertEqual(workspace_to_test_json(prod),
                         workspace_to_test_json(direct),
                         "production route must equal direct dispatch")

    def test_layout_apply_no_panic_on_malformed(self):
        """The runtime dispatcher tolerates malformed / garbage ops without
        raising -- production input is never trusted (the document op_apply
        discipline). Missing op, non-string op, unknown verb, wrong-typed
        params, and a missing required kind must all SKIP. A well-formed op on
        a fresh layout must still mutate (sanity) -- confirming the dispatcher
        is live, not inert."""
        setup_json = _read_fixture("expected/workspace_default.json")
        layout = test_json_to_workspace(setup_json)
        layout.ensure_pane_layout(1200.0, 800.0)
        baseline = workspace_to_test_json(layout)

        # None of these must raise; each is a skip (or a defaulted no-target).
        malformed = [
            {},                                       # no "op"
            {"op": 42},                               # "op" not a string
            {"op": None},                             # "op" null
            {"op": "totally_unknown_verb"},           # unknown verb
            {"op": "show_panel"},                     # missing required "kind"
            {"op": "show_panel", "kind": 7},          # "kind" wrong type
            {"op": "hide_pane"},                      # missing required "kind"
            {"op": "hide_pane", "kind": None},        # null kind
            {"op": "set_pane_position", "pane_id": "x"},  # garbage param
            {"op": "resize_pane", "pane_id": "no", "width": [], "height": {}},
            {"op": "redock", "dock_id": "nope"},      # bad number
        ]
        for op in malformed:
            layout_apply(layout, op)  # must not raise

        # `baseline` documents the malformed loop ran against a real, paned
        # layout; reference it so the binding is not dead.
        self.assertTrue(baseline)

        # A WELL-FORMED op must still mutate on a fresh layout -- the dispatcher
        # is live, not a no-op shell masking a broken route.
        fresh = test_json_to_workspace(setup_json)
        before = workspace_to_test_json(fresh)
        layout_apply(fresh, {
            "op": "toggle_group_collapsed", "dock_id": 0, "group_idx": 0})
        after = workspace_to_test_json(fresh)
        self.assertNotEqual(before, after,
            "a well-formed op must still mutate -- dispatcher is live")

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

    # ---------------------------------------------------------------
    # Panel widget-layout (Path B) algorithm test vectors
    # ---------------------------------------------------------------

    def test_algorithm_panel_layout(self):
        json_str = _read_fixture("algorithms/panel_layout.json")
        tests = json.loads(json_str)
        bundle_path = os.path.join(
            os.path.dirname(__file__), "..", "workspace", "workspace.json")
        with open(bundle_path) as f:
            panels = json.load(f)["panels"]

        for tc in tests:
            name = tc["name"]
            func = tc["function"]
            args = tc["args"]
            expected = tc["expected"]
            if func != "layout_panel":
                self.fail(f"Unknown function: {func}")
            actual = layout_panel(
                panels[args["panel"]], args["avail_w"],
                args.get("avail_h", 0), args.get("ctx", {}))
            self.assertEqual(actual, expected,
                msg=f"Panel layout '{name}' mismatch")

    # ---------------------------------------------------------------
    # Panel widget-TREE snapshot (TESTING_STRATEGY.md §4) test vectors
    # ---------------------------------------------------------------
    # Structural sibling of the panel-layout corpus above: where that pins
    # per-widget RECTS, this pins per-widget STRUCTURAL records (type / id /
    # kind / col / visible / dyn_visible / bind-keys / style-keys), so the
    # panel widget tree itself is a cross-app byte-gate. Closes the
    # widget-missing / wrong-kind-or-placeholder / wrongly-hidden classes as
    # data. Reuses the exact panels + pinned ctx from panel_layout.json so a
    # foreach source resolves to the same expansion count in both corpora.

    def test_algorithm_widget_tree(self):
        json_str = _read_fixture("algorithms/panel_widget_tree.json")
        tests = json.loads(json_str)
        bundle_path = os.path.join(
            os.path.dirname(__file__), "..", "workspace", "workspace.json")
        with open(bundle_path) as f:
            panels = json.load(f)["panels"]

        for tc in tests:
            name = tc["name"]
            func = tc["function"]
            args = tc["args"]
            expected = tc["expected"]
            if func != "widget_tree":
                self.fail(f"Unknown function: {func}")
            actual = widget_tree(panels[args["panel"]], args.get("ctx", {}))
            self.assertEqual(actual, expected,
                msg=f"Panel widget tree '{name}' mismatch")

    # ---------------------------------------------------------------
    # Menu enabled/checked evaluation (TESTING_STRATEGY.md chrome seam)
    # ---------------------------------------------------------------
    # The bundle / live-widget gates pin the menu's STRUCTURE; this pins its
    # DYNAMIC state. Each case seeds a menu context (state.tab_count,
    # active_document.*, workspace.has_saved_layout, panels.*, panes.*) and
    # byte-compares the per-item {enabled, checked} every app must compute by
    # evaluating the bundle's enabled_when / checked_when through the shared
    # expression evaluator. Closes the "grays out / checks differently across
    # apps" class as data.

    def test_algorithm_menu_state(self):
        json_str = _read_fixture("algorithms/menu_state.json")
        tests = json.loads(json_str)
        bundle_path = os.path.join(
            os.path.dirname(__file__), "..", "workspace", "workspace.json")
        with open(bundle_path) as f:
            menubar = json.load(f)["menubar"]

        for tc in tests:
            name = tc["name"]
            func = tc["function"]
            args = tc["args"]
            expected = tc["expected"]
            if func != "menu_state":
                self.fail(f"Unknown function: {func}")
            actual = menu_state(menubar, args.get("ctx", {}))
            self.assertEqual(actual, expected,
                msg=f"Menu state '{name}' mismatch")


if __name__ == "__main__":
    absltest.main()
