"""Phase 3 semantics fixtures: let:, foreach, HOFs, path type.

Per PHASE3.md §4 and §6. Tests here must pass in all 4 languages;
this file is the Python reference.
"""

import pytest

from workspace_interpreter.state_store import StateStore
from workspace_interpreter.effects import run_effects
from workspace_interpreter.expr import evaluate
from workspace_interpreter.expr_types import Value, ValueType


# ══════════════════════════════════════════════════════════════════
# let: effect
# ══════════════════════════════════════════════════════════════════


class TestLetEffect:
    def test_let_binds_for_subsequent_effect(self):
        store = StateStore({"x": 0})
        run_effects([
            {"let": {"n": "5"}},
            {"set": {"x": "n"}},
        ], {}, store)
        assert store.get("x") == 5

    def test_let_multiple_bindings_in_one_block(self):
        store = StateStore({"total": 0})
        run_effects([
            {"let": {"a": "3", "b": "7"}},
            {"set": {"total": "a + b"}},
        ], {}, store)
        assert store.get("total") == 10

    def test_let_later_binding_sees_earlier_in_same_block(self):
        store = StateStore({"x": 0})
        run_effects([
            {"let": {"a": "5", "b": "a * 2"}},
            {"set": {"x": "b"}},
        ], {}, store)
        assert store.get("x") == 10

    def test_let_shadows_outer_scope(self):
        store = StateStore({"x": 0})
        run_effects([
            {"let": {"v": "1"}},
            {"let": {"v": "2"}},   # shadows
            {"set": {"x": "v"}},
        ], {}, store)
        assert store.get("x") == 2

    def test_let_does_not_leak_across_sibling_lists(self):
        """A let inside a then: branch doesn't leak to the next effect."""
        store = StateStore({"result": 0})
        run_effects([
            {"if": {
                "condition": "true",
                "then": [{"let": {"tmp": "42"}}],
            }},
            # tmp is out of scope here; expr returns null
            {"set": {"result": "if tmp == null then -1 else tmp"}},
        ], {}, store)
        assert store.get("result") == -1


# ══════════════════════════════════════════════════════════════════
# Closure-capture test (PHASE3.md §4.4)
# ══════════════════════════════════════════════════════════════════


class TestClosureCapture:
    def test_closure_captures_shadowed_binding(self):
        """§4.4: a closure made under an outer let sees its x, not the inner let's x."""
        store = StateStore({"direct": 0, "through_closure": 0})
        run_effects([
            {"let": {"x": "1"}},
            {"let": {"f": "fun _ -> x"}},             # f captures x=1
            {"let": {"x": "2"}},                       # shadows x
            {"set": {"direct": "x"}},                  # sees 2
            {"set": {"through_closure": "f(null)"}},   # sees 1 (captured)
        ], {}, store)
        assert store.get("direct") == 2
        assert store.get("through_closure") == 1


# ══════════════════════════════════════════════════════════════════
# foreach effect (PHASE3.md §5.3)
# ══════════════════════════════════════════════════════════════════


class TestForeachEffect:
    def test_foreach_iterates_over_list(self):
        store = StateStore({"sum": 0})
        run_effects([
            {"foreach": {"source": "[1, 2, 3]", "as": "n"},
             "do": [{"set": {"sum": "state.sum + n"}}]},
        ], {}, store)
        assert store.get("sum") == 6

    def test_foreach_empty_list_does_nothing(self):
        store = StateStore({"touched": False})
        run_effects([
            {"foreach": {"source": "[]", "as": "x"},
             "do": [{"set": {"touched": "true"}}]},
        ], {}, store)
        assert store.get("touched") is False

    def test_foreach_binding_does_not_leak_after_loop(self):
        store = StateStore({"result": 0})
        run_effects([
            {"foreach": {"source": "[10, 20]", "as": "x"},
             "do": []},
            # x is out of scope; null fallback = -1
            {"set": {"result": "if x == null then -1 else x"}},
        ], {}, store)
        assert store.get("result") == -1

    def test_foreach_iteration_local_scope(self):
        """A let inside one iteration's do: doesn't leak to the next iteration."""
        store = StateStore({"witness": "init"})
        run_effects([
            {"foreach": {"source": "[1, 2]", "as": "x"},
             "do": [
                 # If 'leaked' leaked from iter 1, iter 2 would see 'leak';
                 # with iteration-local scope, iter 2 sees null → 'ok'.
                 # Overwrite witness each iteration so final value tells
                 # us what iter 2 observed.
                 {"set": {"witness": 'if leaked == null then "ok" else "leak"'}},
                 {"let": {"leaked": "'v'"}},   # try to leak
             ]},
        ], {}, store)
        assert store.get("witness") == "ok"

    def test_foreach_closure_captures_iteration_value(self):
        """§4.5: a closure made per iteration captures THAT iteration's x."""
        store = StateStore({"first": 0, "second": 0, "third": 0})
        run_effects([
            {"foreach": {"source": "[10, 20, 30]", "as": "x"},
             "do": [
                 {"set": {"first":  "if x == 10 then __apply__(fun _ -> x, null) else state.first"}},
                 {"set": {"second": "if x == 20 then __apply__(fun _ -> x, null) else state.second"}},
                 {"set": {"third":  "if x == 30 then __apply__(fun _ -> x, null) else state.third"}},
             ]},
        ], {}, store)
        assert store.get("first") == 10
        assert store.get("second") == 20
        assert store.get("third") == 30


# ══════════════════════════════════════════════════════════════════
# Higher-order functions on lists (PHASE3.md §6.1)
# ══════════════════════════════════════════════════════════════════


class TestHOFs:
    def test_any_true_when_predicate_matches_any(self):
        r = evaluate("any([1, 2, 3], fun n -> n > 2)", {})
        assert r.type == ValueType.BOOL and r.value is True

    def test_any_false_when_no_match(self):
        r = evaluate("any([1, 2, 3], fun n -> n > 10)", {})
        assert r.type == ValueType.BOOL and r.value is False

    def test_any_empty_list_is_false(self):
        r = evaluate("any([], fun n -> true)", {})
        assert r.type == ValueType.BOOL and r.value is False

    def test_all_true_when_every_matches(self):
        r = evaluate("all([2, 4, 6], fun n -> n * 2 == n + n)", {})
        assert r.type == ValueType.BOOL and r.value is True

    def test_all_false_when_one_fails(self):
        r = evaluate("all([2, 4, 5], fun n -> n * 2 == n + n)", {})
        # all integers satisfy n*2 == n+n, should be true
        assert r.value is True
        r2 = evaluate("all([2, 4, 5], fun n -> n > 3)", {})
        assert r2.value is False

    def test_all_empty_list_is_true(self):
        r = evaluate("all([], fun n -> false)", {})
        assert r.type == ValueType.BOOL and r.value is True

    def test_map_transforms_each_element(self):
        r = evaluate("map([1, 2, 3], fun n -> n * 10)", {})
        assert r.type == ValueType.LIST
        assert r.value == [10, 20, 30]

    def test_map_empty_list(self):
        r = evaluate("map([], fun n -> n)", {})
        assert r.type == ValueType.LIST and r.value == []

    def test_filter_keeps_matching(self):
        r = evaluate("filter([1, 2, 3, 4, 5], fun n -> n > 2)", {})
        assert r.type == ValueType.LIST
        assert r.value == [3, 4, 5]

    def test_filter_empty_when_none_match(self):
        r = evaluate("filter([1, 2, 3], fun n -> n > 10)", {})
        assert r.value == []

    def test_hof_with_captured_variable(self):
        r = evaluate("filter([1, 2, 3, 4], fun n -> n > threshold)",
                     {"threshold": 2})
        assert r.value == [3, 4]


# ══════════════════════════════════════════════════════════════════
# Path value type (PHASE3.md §6.2)
# ══════════════════════════════════════════════════════════════════


class TestPathType:
    def test_path_constructor_from_ints(self):
        r = evaluate("path(0, 2, 1)", {})
        assert r.type == ValueType.PATH
        assert r.value == (0, 2, 1)

    def test_path_constructor_empty(self):
        r = evaluate("path()", {})
        assert r.type == ValueType.PATH
        assert r.value == ()

    def test_path_depth(self):
        r = evaluate("path(0, 2, 1).depth", {})
        assert r.value == 3

    def test_path_depth_of_root(self):
        r = evaluate("path().depth", {})
        assert r.value == 0

    def test_path_parent(self):
        r = evaluate("path(0, 2, 1).parent", {})
        assert r.type == ValueType.PATH
        assert r.value == (0, 2)

    def test_path_parent_of_root_is_null(self):
        r = evaluate("path().parent", {})
        assert r.type == ValueType.NULL

    def test_path_id(self):
        r = evaluate("path(0, 2, 1).id", {})
        assert r.type == ValueType.STRING
        assert r.value == "0.2.1"

    def test_path_id_of_root(self):
        r = evaluate("path().id", {})
        assert r.value == ""

    def test_path_indices(self):
        r = evaluate("path(0, 2, 1).indices", {})
        assert r.type == ValueType.LIST
        assert r.value == [0, 2, 1]

    def test_path_equality(self):
        r = evaluate("path(0, 2) == path(0, 2)", {})
        assert r.value is True
        r2 = evaluate("path(0, 2) == path(0, 3)", {})
        assert r2.value is False

    def test_path_not_equal_to_list(self):
        """Paths are a distinct type from lists, even with same indices."""
        r = evaluate("path(0, 2) == [0, 2]", {})
        assert r.value is False

    def test_path_child(self):
        r = evaluate("path_child(path(0, 2), 5)", {})
        assert r.type == ValueType.PATH
        assert r.value == (0, 2, 5)

    def test_path_from_id(self):
        r = evaluate("path_from_id('0.2.1')", {})
        assert r.type == ValueType.PATH
        assert r.value == (0, 2, 1)

    def test_path_from_id_root(self):
        r = evaluate("path_from_id('')", {})
        assert r.type == ValueType.PATH
        assert r.value == ()

    def test_path_from_id_malformed_is_null(self):
        r = evaluate("path_from_id('not-a-path')", {})
        assert r.type == ValueType.NULL


# ══════════════════════════════════════════════════════════════════
# snapshot effect (PHASE3.md §5.2)
# ══════════════════════════════════════════════════════════════════


def _make_doc(layers):
    """Build a minimal document tree. Layers is a list of dicts like
    {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}}."""
    return {"layers": layers}


class TestSnapshotEffect:
    def test_snapshot_captures_tree(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects([{"snapshot": None}], {}, store)
        assert len(store.snapshots()) == 1
        # Mutating the live tree doesn't affect the snapshot
        doc["layers"][0]["common"]["visibility"] = "invisible"
        assert store.snapshots()[0]["layers"][0]["common"]["visibility"] == "visible"

    def test_snapshot_noop_when_no_document(self):
        store = StateStore()
        run_effects([{"snapshot": None}], {}, store)
        assert store.snapshots() == []


# ══════════════════════════════════════════════════════════════════
# doc.set effect (PHASE3.md §5.4)
# ══════════════════════════════════════════════════════════════════


class TestAsReturnBinding:
    """PHASE3.md §5.5: effects that return values can bind via as:"""

    def test_doc_delete_at_returns_deleted_element(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
            {"kind": "Layer", "name": "B", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.delete_at": "path(0)", "as": "removed"},
            {"set": {"deleted_name": "removed.name"}},
        ], {}, store, diagnostics=[])
        # Layer B shifted to index 0, A removed
        assert len(doc["layers"]) == 1
        assert doc["layers"][0]["name"] == "B"
        assert store.get("deleted_name") == "A"


class TestDocDeleteAtEffect:
    """PHASE3.md §5.5: doc.delete_at primitive."""

    def test_delete_top_level_layer(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A"},
            {"kind": "Layer", "name": "B"},
            {"kind": "Layer", "name": "C"},
        ])
        store = StateStore(document=doc)
        run_effects([{"doc.delete_at": "path(1)"}], {}, store, diagnostics=[])
        names = [l["name"] for l in doc["layers"]]
        assert names == ["A", "C"]

    def test_delete_reverse_order_via_foreach(self):
        """Deleting [0,1,2] in reverse order keeps indices valid."""
        doc = _make_doc([
            {"kind": "Layer", "name": "A"},
            {"kind": "Layer", "name": "B"},
            {"kind": "Layer", "name": "C"},
            {"kind": "Layer", "name": "D"},
        ])
        store = StateStore(document=doc)
        # Use an explicit reverse-sorted path list
        run_effects([
            {"foreach": {"source": "[path(2), path(0)]", "as": "p"},
             "do": [{"doc.delete_at": "p"}]},
        ], {}, store, diagnostics=[])
        names = [l["name"] for l in doc["layers"]]
        assert names == ["B", "D"]

    def test_delete_invalid_path_is_noop(self):
        doc = _make_doc([{"kind": "Layer", "name": "A"}])
        store = StateStore(document=doc)
        run_effects([{"doc.delete_at": "path(5)"}], {}, store, diagnostics=[])
        assert len(doc["layers"]) == 1


class TestDocCloneAtEffect:
    def test_clone_at_returns_copy(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.clone_at": "path(0)", "as": "clone"},
            {"set": {"cloned_name": "clone.name"}},
        ], {}, store, diagnostics=[])
        # Original layer untouched
        assert len(doc["layers"]) == 1
        assert doc["layers"][0]["name"] == "A"
        assert store.get("cloned_name") == "A"

    def test_clone_is_deep_copy(self):
        """Inserting the clone and mutating it does not affect the original."""
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.clone_at": "path(0)", "as": "clone"},
            {"doc.insert_after": {"path": "path(0)", "element": "clone"}},
            {"doc.set": {"path": "path(1)",
                         "fields": {"common.visibility": "'invisible'"}}},
        ], {}, store, diagnostics=[])
        # Inserted clone at idx 1; mutated that; original at idx 0 untouched
        assert doc["layers"][0]["common"]["visibility"] == "visible"
        assert doc["layers"][1]["common"]["visibility"] == "invisible"


class TestDocInsertAfterEffect:
    def test_insert_after_top_level(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A"},
            {"kind": "Layer", "name": "C"},
        ])
        store = StateStore(document=doc)
        new_layer = {"kind": "Layer", "name": "B"}
        run_effects([
            {"doc.insert_after": {"path": "path(0)", "element": new_layer}},
        ], {}, store, diagnostics=[])
        names = [l["name"] for l in doc["layers"]]
        assert names == ["A", "B", "C"]

    def test_duplicate_via_clone_and_insert_after(self):
        """End-to-end: duplicate layer 0 at position 1."""
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "preview"}},
            {"kind": "Layer", "name": "B"},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.clone_at": "path(0)", "as": "clone"},
            {"doc.insert_after": {"path": "path(0)", "element": "clone"}},
        ], {}, store, diagnostics=[])
        names = [l["name"] for l in doc["layers"]]
        assert names == ["A", "A", "B"]


class TestDocSetEffect:
    def test_doc_set_writes_dotted_field(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible", "locked": False}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.set": {
                "path": "path(0)",
                "fields": {"common.visibility": "'invisible'"},
            }},
        ], {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "invisible"
        # Sibling fields untouched
        assert doc["layers"][0]["common"]["locked"] is False
        assert doc["layers"][0]["name"] == "A"

    def test_doc_set_multiple_fields(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible", "locked": False}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.set": {
                "path": "path(0)",
                "fields": {
                    "common.visibility": "'outline'",
                    "common.locked": "true",
                    "name": "'Renamed'",
                },
            }},
        ], {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "outline"
        assert doc["layers"][0]["common"]["locked"] is True
        assert doc["layers"][0]["name"] == "Renamed"

    def test_doc_set_creates_nested_dict_if_missing(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A"},   # no common dict
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.set": {
                "path": "path(0)",
                "fields": {"common.visibility": "'invisible'"},
            }},
        ], {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "invisible"

    def test_doc_set_invalid_path_is_noop(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.set": {
                "path": "path(5)",  # out of range
                "fields": {"common.visibility": "'invisible'"},
            }},
        ], {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "visible"


# ══════════════════════════════════════════════════════════════════
# active_document computed properties (PHASE3.md §7.2)
# ══════════════════════════════════════════════════════════════════


class TestDocCreateLayerEffect:
    """PHASE3.md sub-tollgate 2: doc.create_layer factory primitive."""

    def test_create_layer_then_insert_at(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "preview"}},
        ])
        store = StateStore(document=doc)
        run_effects([
            {"doc.create_layer": {"name": "'Layer 2'"}, "as": "new_layer"},
            {"doc.insert_at": {"parent_path": "path()",
                                "index": "1", "element": "new_layer"}},
        ], {}, store, diagnostics=[])
        assert len(doc["layers"]) == 2
        assert doc["layers"][1]["name"] == "Layer 2"
        assert doc["layers"][1]["kind"] == "Layer"

    def test_create_layer_default_fields(self):
        doc = _make_doc([])
        store = StateStore(document=doc)
        run_effects([
            {"doc.create_layer": {"name": "'Solo'"}, "as": "l"},
            {"doc.insert_at": {"parent_path": "path()",
                                "index": "0", "element": "l"}},
        ], {}, store, diagnostics=[])
        layer = doc["layers"][0]
        assert layer["kind"] == "Layer"
        assert layer["name"] == "Solo"
        assert layer.get("common", {}).get("visibility") == "preview"
        assert layer.get("common", {}).get("locked") is False
        assert layer.get("children") == []


class TestNewLayerAction:
    """End-to-end: new_layer YAML action."""

    def _load_action(self, name):
        import yaml as yl
        path = os.path.join(os.path.dirname(__file__), "..", "..",
                            "workspace", "actions.yaml")
        with open(path) as f:
            return yl.safe_load(f)["actions"][name]

    def test_new_layer_no_selection_appends(self):
        import os as _os
        global os
        os = _os
        effects = self._load_action("new_layer")["effects"]
        doc = _make_doc([
            {"kind": "Layer", "name": "Layer 1"},
        ])
        store = StateStore(document=doc)
        store.init_panel("layers", {"layers_panel_selection": []})
        store.set_active_panel("layers")
        run_effects(effects, {}, store, diagnostics=[])
        assert len(doc["layers"]) == 2
        # Auto-generated name skips "Layer 1"
        assert doc["layers"][1]["name"] == "Layer 2"

    def test_new_layer_with_selection_inserts_above(self):
        import os as _os
        global os
        os = _os
        effects = self._load_action("new_layer")["effects"]
        doc = _make_doc([
            {"kind": "Layer", "name": "Layer 1"},
            {"kind": "Layer", "name": "Layer 2"},
            {"kind": "Layer", "name": "Layer 3"},
        ])
        store = StateStore(document=doc)
        # Select layer at index 1 (middle)
        store.init_panel("layers", {
            "layers_panel_selection": [{"__path__": [1]}],
        })
        store.set_active_panel("layers")
        run_effects(effects, {}, store, diagnostics=[])
        assert len(doc["layers"]) == 4
        # Insert at index 1+1 = 2
        # Names taken: {Layer 1, Layer 2, Layer 3}, next unused: Layer 4
        assert doc["layers"][2]["name"] == "Layer 4"
        # Old Layer 3 shifted to index 3
        assert doc["layers"][3]["name"] == "Layer 3"


class TestActiveDocumentRollups:
    def test_top_level_layers(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
            {"kind": "Layer", "name": "B", "common": {"visibility": "invisible"}},
            {"kind": "Group", "name": "G"},   # not a Layer — excluded
        ])
        store = StateStore(document=doc)
        ctx = store.eval_context()
        assert "top_level_layers" in ctx["active_document"]
        layers = ctx["active_document"]["top_level_layers"]
        assert len(layers) == 2
        assert layers[0]["name"] == "A"
        assert layers[1]["name"] == "B"

    def test_top_level_layer_paths(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A"},
            {"kind": "Group", "name": "G"},
            {"kind": "Layer", "name": "B"},
        ])
        store = StateStore(document=doc)
        # Paths: A is at index 0, B is at index 2
        ctx = store.eval_context()
        paths = ctx["active_document"]["top_level_layer_paths"]
        # paths should be a list of PATH-typed values; check through expression
        r = evaluate("active_document.top_level_layer_paths.length", ctx)
        assert r.value == 2

    def test_any_on_top_level_layers(self):
        """Integration: HOF over top_level_layers reads live fields."""
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
            {"kind": "Layer", "name": "B", "common": {"visibility": "invisible"}},
        ])
        store = StateStore(document=doc)
        ctx = store.eval_context()
        r = evaluate(
            "any(active_document.top_level_layers, "
            "fun l -> l.common.visibility == 'visible')",
            ctx,
        )
        assert r.value is True


# ══════════════════════════════════════════════════════════════════
# End-to-end: the toggle_all_layers_visibility YAML from PHASE3.md §2
# ══════════════════════════════════════════════════════════════════


class TestToggleAllLayersVisibility:
    EFFECTS = [
        {"let": {
            "target": "if any(active_document.top_level_layers, "
                      "fun l -> l.common.visibility != 'invisible') "
                      "then 'invisible' else 'preview'",
        }},
        {"snapshot": None},
        {"foreach": {"source": "active_document.top_level_layer_paths", "as": "p"},
         "do": [
             {"doc.set": {"path": "p", "fields": {"common.visibility": "target"}}},
         ]},
    ]

    def test_toggle_when_any_visible_all_become_invisible(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
            {"kind": "Layer", "name": "B", "common": {"visibility": "invisible"}},
        ])
        store = StateStore(document=doc)
        run_effects(self.EFFECTS, {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "invisible"
        assert doc["layers"][1]["common"]["visibility"] == "invisible"
        assert len(store.snapshots()) == 1

    def test_toggle_when_all_invisible_all_become_preview(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "invisible"}},
            {"kind": "Layer", "name": "B", "common": {"visibility": "invisible"}},
        ])
        store = StateStore(document=doc)
        run_effects(self.EFFECTS, {}, store)
        assert doc["layers"][0]["common"]["visibility"] == "preview"
        assert doc["layers"][1]["common"]["visibility"] == "preview"

    def test_toggle_skips_non_layer_elements(self):
        doc = _make_doc([
            {"kind": "Layer", "name": "A", "common": {"visibility": "visible"}},
            {"kind": "Group", "name": "G", "common": {"visibility": "visible"}},
        ])
        store = StateStore(document=doc)
        run_effects(self.EFFECTS, {}, store)
        # Layer toggled
        assert doc["layers"][0]["common"]["visibility"] == "invisible"
        # Group was not in top_level_layer_paths, left alone
        assert doc["layers"][1]["common"]["visibility"] == "visible"
