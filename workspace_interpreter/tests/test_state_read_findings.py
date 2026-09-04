"""Behavioural pins for the thirteen state-read findings the declaration gate
(``scripts/check_state_reads.py``) found on main.

WHY THIS FILE EXISTS, and why the gate is not enough on its own
--------------------------------------------------------------
``check_state_reads.py`` refuses a string that does not parse and names an
undeclared read. That is a REFUSAL about the source text; it is not a statement
about what the app does. Every one of the thirteen findings was, at runtime, a
SILENT null: ``expr.evaluate`` catches the ParseError, logs at WARNING and
returns ``Value.null()`` (``expr.py:44-51``), and ``_eval_path`` returns
``Value.null()`` for an unresolved namespace with no fallback search
(``expr_eval.py:103-110``). A check mark that never appears, a dialog setter
that drops the write, and a preview swatch bound to null all render as a
perfectly ordinary UI.

So each test here drives the REAL ``workspace/`` sources through the reference
interpreter's own seams and asserts the USER-VISIBLE answer:

  * ``TestBrushCategoryCheckMarks`` — the six ``checked_when`` predicates, through
    ``menu_state`` (the same ``evaluate(...).to_bool()`` path every port bakes).
    On main all six evaluate False for every input, including inputs where the
    category IS in the filter; that is the defect, and each test below drives
    BOTH directions so a predicate that is constant in either direction reds.
  * ``TestSwatchPreviewColorBind`` — the preview swatch's ``bind.color``.
  * ``TestBlobBrushVariationWidgets`` — the three variation widgets, which on
    main were ``include:`` nodes that ``loader.resolve_includes`` never reaches
    (it runs only on ``data["layout"]``) and so never rendered at all.
  * ``TestNoDynamicDataPaths`` — the class of defect behind
    ``sort_brushes_by_name``: a ``${...}`` inside an effect payload, which
    ``loader.substitute_params`` never runs on.

The artboard reference-point setters (findings 7-8) are pinned next to their
existing getter test, in ``test_artboards_effects.py``.

THE FORMS USED IN THE REPAIRS are all forms the grammar already had, so every
port's behaviour changes identically by construction and no port gained an
operator:

  * ``any(list, fun x -> x == v)`` — membership. Python
    ``expr_eval._eval_func`` ("Higher-order functions (Phase 3 6.1)"), Rust
    ``expr_eval.rs`` ``"any" | "all" | "map" | "filter"``, Swift
    ``ExprEval.swift`` ``case "any", "all", "map", "filter"``. Already used by
    ``workspace/actions.yaml`` and already pinned by the cross-language corpus
    ``workspace/tests/expressions.yaml``.
  * ``<-`` — the grammar's only assignment token (``TokenKind.LARROW``); ``:=``
    is not a token in any port's lexer.
  * ``template:`` + ``params:`` — expanded by ``loader.resolve_templates``,
    which ``load_workspace`` DOES run on ``dialogs``/``panels`` content.
"""
from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_parser import parse
from workspace_interpreter.loader import load_workspace
from workspace_interpreter.menu_state import menu_state

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

CATEGORIES = ["calligraphic", "scatter", "art", "pattern", "bristle"]


@pytest.fixture(scope="module")
def ws():
    return load_workspace(os.path.join(REPO_ROOT, "workspace"))


def _brushes_menu(ws) -> list:
    return ws["panels"]["brushes_panel_content"]["menu"]


def _checked_for(menu: list, action: str, ctx: dict, params: dict | None = None):
    """The evaluated ``checked`` of the one menu item with this action (and
    params), through ``menu_state`` -- the shared chrome seam every port bakes.

    Raises if the item is not found, so a renamed action cannot turn this test
    into a vacuous pass.
    """
    rows = menu_state([{"items": menu}], ctx)
    hits = [
        r for r, item in zip(rows, [i for i in menu if isinstance(i, dict)])
        if r["action"] == action and (params is None or item.get("params") == params)
    ]
    assert len(hits) == 1, f"expected exactly one {action} {params} item, got {len(hits)}"
    return hits[0]["checked"]


# ══════════════════════════════════════════════════════════════════
# Findings 1-6: `panel.category_filter contains "..."` x5 and
# `preferences... contains panel.selected_library`
# ══════════════════════════════════════════════════════════════════


class TestBrushCategoryCheckMarks:
    """workspace/panels/brushes.yaml:167,172,177,182,187,192.

    ``contains`` is not an operator in ANY port: it is absent from
    ``expr_lexer._KEYWORDS``, from ``jas_dioxus/src/interpreter/expr_lexer.rs``
    and from ``JasSwift/Sources/Interpreter/ExprEval.swift``. The five category
    predicates and the persistent-library predicate therefore raised ParseError,
    which ``expr.evaluate`` swallows into ``Value.null()`` -> ``to_bool()`` ->
    False. All six check marks were unreachable.
    """

    def _ctx(self, filter_value: list, selected="default_brushes",
             persistent=("default_brushes",)) -> dict:
        return {
            "panel": {
                "category_filter": list(filter_value),
                "selected_library": selected,
            },
            "preferences": {"brushes": {"persistent_libraries": list(persistent)}},
        }

    @pytest.mark.parametrize("category", CATEGORIES)
    def test_check_mark_appears_when_category_is_in_the_filter(self, ws, category):
        menu = _brushes_menu(ws)
        ctx = self._ctx(CATEGORIES)
        assert _checked_for(menu, "toggle_brush_category", ctx, {"type": category}) is True

    @pytest.mark.parametrize("category", CATEGORIES)
    def test_check_mark_clears_when_category_is_removed_from_the_filter(self, ws, category):
        """The other direction: a predicate that is constantly True is as wrong
        as one that is constantly False, and only this arm can see it."""
        menu = _brushes_menu(ws)
        ctx = self._ctx([c for c in CATEGORIES if c != category])
        assert _checked_for(menu, "toggle_brush_category", ctx, {"type": category}) is False

    def test_each_category_predicate_reads_its_own_category(self, ws):
        """With exactly ONE category in the filter, exactly ONE check mark is
        lit. Pins that the five predicates are distinct -- five copies of the
        same expression would pass both arms above and fail here."""
        menu = _brushes_menu(ws)
        for category in CATEGORIES:
            ctx = self._ctx([category])
            lit = [
                c for c in CATEGORIES
                if _checked_for(menu, "toggle_brush_category", ctx, {"type": c})
            ]
            assert lit == [category], f"filter=[{category}] lit {lit}"

    def test_persistent_library_check_mark_follows_the_selected_library(self, ws):
        menu = _brushes_menu(ws)
        on = self._ctx(CATEGORIES, selected="my_lib", persistent=("default_brushes", "my_lib"))
        off = self._ctx(CATEGORIES, selected="my_lib", persistent=("default_brushes",))
        assert _checked_for(menu, "toggle_brush_library_persistent", on) is True
        assert _checked_for(menu, "toggle_brush_library_persistent", off) is False

    def test_empty_filter_lights_nothing(self, ws):
        menu = _brushes_menu(ws)
        ctx = self._ctx([])
        for category in CATEGORIES:
            assert _checked_for(menu, "toggle_brush_category", ctx, {"type": category}) is False

    def test_predicates_parse_at_all(self, ws):
        """The finding as the gate states it, kept separate from the behaviour
        arms so a regression names its own cause."""
        menu = _brushes_menu(ws)
        for item in menu:
            if isinstance(item, dict) and "checked_when" in item:
                parse(item["checked_when"])  # raises ParseError on the old form


# ══════════════════════════════════════════════════════════════════
# Finding 9: `bind.color: "#dialog.hex"`
# ══════════════════════════════════════════════════════════════════


def _find_by_id(node, wanted):
    if isinstance(node, dict):
        if node.get("id") == wanted:
            return node
        for key in ("content", "children"):
            found = _find_by_id(node.get(key), wanted)
            if found is not None:
                return found
    elif isinstance(node, list):
        for child in node:
            found = _find_by_id(child, wanted)
            if found is not None:
                return found
    return None


class TestSwatchPreviewColorBind:
    """workspace/dialogs/swatch_options.yaml:215.

    ``#dialog.hex`` lexes as a COLOR literal: the lexer takes ``#`` plus the
    following hex digits, ``#d`` is one digit, and it emits an ERROR token. The
    two active ports each carry a renderer-level special case for the literal
    string ``"#dialog.hex"`` (``renderer.rs::swatch_color_bind``,
    ``ColorSwatchFace.swift::swatchColorBind``) that strips the ``#`` before
    evaluating -- so the widget painted, but ONLY because two ports hand-coded
    around a string that is not an expression. The repair uses the sibling
    preview swatch's form (``color_picker.yaml:182``: ``color: "dialog.color"``),
    which is the same colour by construction (``hex`` is
    ``get: "hex(color)"``) and needs no special case anywhere.
    """

    def test_preview_bind_is_an_expression_that_yields_the_working_colour(self, ws):
        dialog = ws["dialogs"]["swatch_options"]
        node = _find_by_id(dialog["content"], "so_color_preview")
        assert node is not None, "so_color_preview vanished from swatch_options"
        expr = node["bind"]["color"]
        result = evaluate(expr, {"dialog": {"color": "#336699", "hex": "336699"}})
        assert result.type.name != "NULL", f"{expr!r} evaluated to null"
        assert str(result.value).lower().lstrip("#") == "336699"

    def test_preview_bind_tracks_a_colour_change(self, ws):
        """A bind that returned a constant would pass the arm above."""
        dialog = ws["dialogs"]["swatch_options"]
        expr = _find_by_id(dialog["content"], "so_color_preview")["bind"]["color"]
        a = evaluate(expr, {"dialog": {"color": "#336699", "hex": "336699"}}).value
        b = evaluate(expr, {"dialog": {"color": "#ff0000", "hex": "ff0000"}}).value
        assert str(a).lower() != str(b).lower()

    def test_every_colour_bind_in_the_dialog_parses(self, ws):
        dialog = ws["dialogs"]["swatch_options"]

        def walk(node):
            if isinstance(node, dict):
                bind = node.get("bind")
                if isinstance(bind, dict) and isinstance(bind.get("color"), str):
                    parse(bind["color"])
                for key in ("content", "children"):
                    walk(node.get(key))
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(dialog["content"])


# ══════════════════════════════════════════════════════════════════
# Findings 11-13: the three undeclared `dialog.*_mode` reads on
# `- include: variation_widget` nodes
# ══════════════════════════════════════════════════════════════════


class TestBlobBrushVariationWidgets:
    """workspace/dialogs/blob_brush_tool_options.yaml:150,171,191.

    Three ``- include: variation_widget`` nodes. ``include:`` takes a FILE PATH
    and is resolved by ``loader.resolve_includes``, which ``load_workspace``
    calls only on ``data["layout"]`` -- never on dialogs. The nodes were never
    expanded and never rendered, and their param names (``base_bind`` /
    ``mode_bind``) were not the template's (``base_path`` / ``mode_path``).

    ``variation_widget`` is a TEMPLATE, and ``load_workspace`` DOES run
    ``resolve_templates`` over every dialog's ``content`` (``loader.py:174-181``)
    -- so the repair needs no interpreter change and no port change: the
    compiled ``workspace.json`` the active ports read carries the expansion.
    """

    WIDGETS = [
        ("bbo_size", "size", "size_variation"),
        ("bbo_angle", "angle", "angle_variation"),
        ("bbo_roundness", "roundness", "roundness_variation"),
    ]
    LABELS = {"bbo_size": "Size", "bbo_angle": "Angle", "bbo_roundness": "Roundness"}

    def _template_rows(self, ws) -> list[dict]:
        rows: list[dict] = []

        def walk(node):
            if isinstance(node, dict):
                if node.get("_template") == "variation_widget":
                    rows.append(node)
                for key in ("content", "children"):
                    walk(node.get(key))
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(ws["dialogs"]["blob_brush_tool_options"]["content"])
        return rows

    def test_three_rows_expanded_each_carrying_its_own_label(self, ws):
        """The template's first child is its label slot (``style.width: 80``).
        Leaving it at its ``""`` default while the row keeps a separate label
        column renders an 80px empty gutter -- a real layout defect that every
        other arm here would pass straight over."""
        rows = self._template_rows(ws)
        assert len(rows) == 3, f"expected 3 variation widgets, found {len(rows)}"
        for row in rows:
            first = row["children"][0]
            prefix = row["children"][1]["id"].rsplit("_", 1)[0]
            assert first["content"] == self.LABELS[prefix], (
                f"{prefix}'s label slot holds {first['content']!r}")

    def test_each_row_disables_under_an_active_calligraphic_brush(self, ws):
        """The row-level ``bind.disabled`` the pre-repair ``include:`` node
        carried as a sibling key. It never ran -- the node never expanded."""
        for row in self._template_rows(ws):
            dis = row["bind"]["disabled"]
            assert evaluate(dis, {"state": {"stroke_brush": None}}).to_bool() is False

    def test_no_unexpanded_include_nodes_survive(self, ws):
        dialog = ws["dialogs"]["blob_brush_tool_options"]

        def walk(node, path="content"):
            if isinstance(node, dict):
                assert "include" not in node, (
                    f"{path} is still an `include:` node; resolve_includes never "
                    f"runs on dialogs, so it renders nothing")
                for key in ("content", "children"):
                    walk(node.get(key), f"{path}/{key}")
            elif isinstance(node, list):
                for i, child in enumerate(node):
                    walk(child, f"{path}[{i}]")

        walk(dialog["content"])

    @pytest.mark.parametrize("prefix,base_key,var_key", WIDGETS)
    def test_widget_expands_into_its_base_and_mode_controls(self, ws, prefix, base_key, var_key):
        dialog = ws["dialogs"]["blob_brush_tool_options"]
        base = _find_by_id(dialog["content"], f"{prefix}_base")
        mode = _find_by_id(dialog["content"], f"{prefix}_mode")
        assert base is not None, f"{prefix}_base never rendered"
        assert mode is not None, f"{prefix}_mode never rendered"
        assert base["bind"]["value"] == f"dialog.{base_key}"
        assert mode["bind"]["value"] == f"dialog.{var_key}.mode"

    @pytest.mark.parametrize("prefix,base_key,var_key", WIDGETS)
    def test_random_bounds_appear_only_in_random_mode(self, ws, prefix, base_key, var_key):
        dialog = ws["dialogs"]["blob_brush_tool_options"]
        for suffix in ("min", "max"):
            node = _find_by_id(dialog["content"], f"{prefix}_{suffix}")
            assert node is not None, f"{prefix}_{suffix} never rendered"
            vis = node["bind"]["visible"]
            assert evaluate(vis, {"dialog": {var_key: {"mode": "random"}}}).to_bool() is True
            assert evaluate(vis, {"dialog": {var_key: {"mode": "fixed"}}}).to_bool() is False

    @pytest.mark.parametrize("prefix,base_key,var_key", WIDGETS)
    def test_base_control_goes_inert_in_a_live_input_mode(self, ws, prefix, base_key, var_key):
        dialog = ws["dialogs"]["blob_brush_tool_options"]
        dis = _find_by_id(dialog["content"], f"{prefix}_base")["bind"]["disabled"]
        assert evaluate(dis, {"dialog": {var_key: {"mode": "pressure"}}}).to_bool() is True
        assert evaluate(dis, {"dialog": {var_key: {"mode": "fixed"}}}).to_bool() is False

    @pytest.mark.parametrize("prefix,base_key,var_key", WIDGETS)
    def test_the_variation_key_is_declared(self, ws, prefix, base_key, var_key):
        """The finding itself: the read had no declaration, so ``open_dialog``
        seeded nothing and every read was ``Value.null()``."""
        state = ws["dialogs"]["blob_brush_tool_options"]["state"]
        assert var_key in state, f"dialog.{var_key} is read but never declared"
        assert state[var_key]["default"]["mode"] == "fixed"

    def test_every_dialog_read_in_this_dialog_is_declared(self, ws):
        """A scoped restatement of the gate's own rule, so a NEW undeclared read
        in this dialog reds here too and not only in CI."""
        dialog = ws["dialogs"]["blob_brush_tool_options"]
        declared = set(dialog.get("state", {})) | set(dialog.get("init", {}))
        seen: set[str] = set()

        def walk(node):
            if isinstance(node, dict):
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for child in node:
                    walk(child)
            elif isinstance(node, str) and "dialog." in node:
                for token in node.replace("(", " ").replace(")", " ").split():
                    if token.startswith("dialog."):
                        seen.add(token.split(".")[1].strip("\"',"))

        walk(dialog["content"])
        assert seen, "found no dialog.* reads at all -- the walk is vacuous"
        assert seen <= declared, f"undeclared: {sorted(seen - declared)}"


# ══════════════════════════════════════════════════════════════════
# Finding 10: `${...}` inside an effect payload
# ══════════════════════════════════════════════════════════════════


class TestNoDynamicDataPaths:
    """workspace/actions.yaml:3839 was
    ``data.brush_libraries.${panel.selected_library}.brushes``.

    ``${...}`` is ``loader.substitute_params``, which runs on template expansion
    and layout includes -- never on an effect payload. No port has any mechanism
    for a dynamic data path: every ``data.*`` effect in
    ``jas_flask/static/js/engine/effects.mjs`` reads ``spec.path`` as a LITERAL
    dotted path through ``_readDataPath``, and the Python / Rust / Swift ports
    implement no ``data.*`` effect at all. So this asserts the CLASS is gone
    rather than that one site changed.
    """

    def test_no_effect_payload_carries_a_param_substitution(self, ws):
        offenders = []

        def walk(node, path):
            if isinstance(node, dict):
                for key, value in node.items():
                    walk(value, f"{path}/{key}")
            elif isinstance(node, list):
                for i, child in enumerate(node):
                    walk(child, f"{path}[{i}]")
            elif isinstance(node, str) and "${" in node:
                offenders.append((path, node))

        count = 0
        for name, action in ws["actions"].items():
            for i, effect in enumerate(action.get("effects", []) or []):
                walk(effect, f"{name}/effects[{i}]")
                count += 1
        assert count > 0, "walked no effects at all -- the scan is vacuous"
        assert offenders == [], f"${{...}} never runs on an effect payload: {offenders}"

    def test_sort_brushes_by_name_declares_no_effect_it_cannot_perform(self, ws):
        """The decision recorded as a test: the action is a LOG-ONLY stub, in the
        same shape as its four sibling unimplemented brushes actions
        (``select_all_unused_brushes``, ``toggle_brush_category``,
        ``toggle_brush_library_persistent``, ``save_brush_library``), because no
        port can address ``panel.selected_library``'s brush list from an effect
        payload. Its ``description`` carries the intended behaviour and says so.
        """
        action = ws["actions"]["sort_brushes_by_name"]
        assert action["effects"] == [{"log": "sort_brushes_by_name"}]
        assert "not yet implemented" in action["description"].lower()


# ══════════════════════════════════════════════════════════════════
# The compiled bundle carries every repair
# ══════════════════════════════════════════════════════════════════


def test_compiled_bundle_matches_the_repaired_sources(ws):
    """The ports read ``workspace/workspace.json``, not the YAML. A repair that
    lives only in the sources is a repair no port receives.
    """
    with open(os.path.join(REPO_ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        bundle = json.load(f)
    assert bundle["panels"]["brushes_panel_content"]["menu"] == \
        ws["panels"]["brushes_panel_content"]["menu"]
    assert bundle["dialogs"]["blob_brush_tool_options"] == ws["dialogs"]["blob_brush_tool_options"]
    assert bundle["dialogs"]["swatch_options"] == ws["dialogs"]["swatch_options"]
    assert bundle["actions"]["sort_brushes_by_name"] == ws["actions"]["sort_brushes_by_name"]
