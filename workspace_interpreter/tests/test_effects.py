"""Tests for the effects interpreter."""

import pytest

from workspace_interpreter.state_store import StateStore
from workspace_interpreter.effects import run_effects


class TestSetEffect:
    def test_set_single(self):
        store = StateStore({"x": 0})
        run_effects([{"set": {"x": "5"}}], {}, store)
        assert store.get("x") == 5

    def test_set_string_value(self):
        store = StateStore({"name": ""})
        run_effects([{"set": {"name": '"hello"'}}], {}, store)
        assert store.get("name") == "hello"

    def test_set_from_expression(self):
        store = StateStore({"a": 10, "b": 0})
        run_effects([{"set": {"b": "state.a"}}], {}, store)
        assert store.get("b") == 10

    def test_set_color(self):
        store = StateStore({"fill_color": None})
        run_effects([{"set": {"fill_color": "#ff0000"}}], {}, store)
        assert store.get("fill_color") == "#ff0000"

    def test_set_null(self):
        store = StateStore({"x": 5})
        run_effects([{"set": {"x": "null"}}], {}, store)
        assert store.get("x") is None


class TestToggleEffect:
    def test_toggle_true_to_false(self):
        store = StateStore({"flag": True})
        run_effects([{"toggle": "flag"}], {}, store)
        assert store.get("flag") is False

    def test_toggle_false_to_true(self):
        store = StateStore({"flag": False})
        run_effects([{"toggle": "flag"}], {}, store)
        assert store.get("flag") is True


class TestSwapEffect:
    def test_swap(self):
        store = StateStore({"a": "#ff0000", "b": "#00ff00"})
        run_effects([{"swap": ["a", "b"]}], {}, store)
        assert store.get("a") == "#00ff00"
        assert store.get("b") == "#ff0000"


class TestIncrementDecrement:
    def test_increment(self):
        store = StateStore({"count": 5})
        run_effects([{"increment": {"key": "count", "by": 3}}], {}, store)
        assert store.get("count") == 8

    def test_decrement(self):
        store = StateStore({"count": 5})
        run_effects([{"decrement": {"key": "count", "by": 2}}], {}, store)
        assert store.get("count") == 3

    def test_increment_default_by_1(self):
        store = StateStore({"count": 0})
        run_effects([{"increment": {"key": "count"}}], {}, store)
        assert store.get("count") == 1


class TestIfEffect:
    def test_if_true_branch(self):
        store = StateStore({"flag": True, "result": ""})
        run_effects([{
            "if": {
                "condition": "state.flag",
                "then": [{"set": {"result": '"yes"'}}],
                "else": [{"set": {"result": '"no"'}}],
            }
        }], {}, store)
        assert store.get("result") == "yes"

    def test_if_false_branch(self):
        store = StateStore({"flag": False, "result": ""})
        run_effects([{
            "if": {
                "condition": "state.flag",
                "then": [{"set": {"result": '"yes"'}}],
                "else": [{"set": {"result": '"no"'}}],
            }
        }], {}, store)
        assert store.get("result") == "no"

    def test_if_no_else(self):
        store = StateStore({"flag": False, "result": "unchanged"})
        run_effects([{
            "if": {
                "condition": "state.flag",
                "then": [{"set": {"result": '"changed"'}}],
            }
        }], {}, store)
        assert store.get("result") == "unchanged"


class TestSetPanelState:
    def test_set_panel_state(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.set_active_panel("color")
        run_effects([{
            "set_panel_state": {"key": "mode", "value": '"rgb"'}
        }], {}, store)
        assert store.get_panel("color", "mode") == "rgb"


class TestListPushEffect:
    def test_list_push(self):
        store = StateStore()
        store.init_panel("color", {"recent": ["a", "b"]})
        store.set_active_panel("color")
        run_effects([{
            "list_push": {
                "target": "panel.recent",
                "value": '"c"',
                "unique": True,
                "max_length": 10,
            }
        }], {}, store)
        assert store.get_panel("color", "recent") == ["c", "a", "b"]


class TestDispatchEffect:
    def test_dispatch_runs_action_effects(self):
        store = StateStore({"x": 0})
        actions = {
            "set_x_to_42": {
                "effects": [{"set": {"x": "42"}}]
            }
        }
        run_effects([{"dispatch": "set_x_to_42"}], {}, store, actions=actions)
        assert store.get("x") == 42


class TestMultipleEffects:
    def test_sequential_effects(self):
        store = StateStore({"a": 0, "b": 0})
        run_effects([
            {"set": {"a": "10"}},
            {"set": {"b": "state.a"}},
        ], {}, store)
        assert store.get("a") == 10
        assert store.get("b") == 10
