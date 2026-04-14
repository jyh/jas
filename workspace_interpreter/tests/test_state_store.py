"""Tests for the reactive state store."""

import pytest

from workspace_interpreter.state_store import StateStore


class TestGlobalState:
    def test_get_set(self):
        store = StateStore()
        store.set("x", 5)
        assert store.get("x") == 5

    def test_get_missing_returns_none(self):
        store = StateStore()
        assert store.get("missing") is None

    def test_init_from_defaults(self):
        store = StateStore({"x": 10, "y": "hello"})
        assert store.get("x") == 10
        assert store.get("y") == "hello"

    def test_subscribe_notified_on_change(self):
        store = StateStore({"x": 0})
        changes = []
        store.subscribe(["x"], lambda key, val: changes.append((key, val)))
        store.set("x", 42)
        assert changes == [("x", 42)]

    def test_subscribe_not_notified_for_other_keys(self):
        store = StateStore({"x": 0, "y": 0})
        changes = []
        store.subscribe(["x"], lambda key, val: changes.append((key, val)))
        store.set("y", 99)
        assert changes == []

    def test_subscribe_wildcard(self):
        store = StateStore({"a": 1, "b": 2})
        changes = []
        store.subscribe(None, lambda key, val: changes.append(key))
        store.set("a", 10)
        store.set("b", 20)
        assert changes == ["a", "b"]

    def test_no_notification_when_value_unchanged(self):
        store = StateStore({"x": 5})
        changes = []
        store.subscribe(["x"], lambda key, val: changes.append(key))
        store.set("x", 5)
        assert changes == []

    def test_get_all(self):
        store = StateStore({"a": 1, "b": 2})
        assert store.get_all() == {"a": 1, "b": 2}


class TestPanelState:
    def test_init_panel(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb", "h": 0})
        assert store.get_panel("color", "mode") == "hsb"
        assert store.get_panel("color", "h") == 0

    def test_set_panel(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.set_panel("color", "mode", "rgb")
        assert store.get_panel("color", "mode") == "rgb"

    def test_panel_scoping(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.init_panel("swatches", {"mode": "grid"})
        assert store.get_panel("color", "mode") == "hsb"
        assert store.get_panel("swatches", "mode") == "grid"

    def test_set_active_panel(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.init_panel("swatches", {"size": "small"})
        store.set_active_panel("color")
        assert store.get_active_panel_state() == {"mode": "hsb"}
        store.set_active_panel("swatches")
        assert store.get_active_panel_state() == {"size": "small"}

    def test_get_panel_missing_returns_none(self):
        store = StateStore()
        assert store.get_panel("nonexistent", "x") is None

    def test_destroy_panel(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.destroy_panel("color")
        assert store.get_panel("color", "mode") is None

    def test_panel_state_persists_across_activation(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.set_panel("color", "mode", "rgb")
        store.set_active_panel("color")
        assert store.get_panel("color", "mode") == "rgb"
        store.set_active_panel(None)
        store.set_active_panel("color")
        assert store.get_panel("color", "mode") == "rgb"

    def test_subscribe_panel_changes(self):
        store = StateStore()
        store.init_panel("color", {"h": 0})
        changes = []
        store.subscribe_panel("color", lambda key, val: changes.append((key, val)))
        store.set_panel("color", "h", 180)
        assert changes == [("h", 180)]


class TestContextForEval:
    def test_eval_context(self):
        store = StateStore({"fill_color": "#ff0000"})
        store.init_panel("color", {"mode": "hsb"})
        store.set_active_panel("color")
        ctx = store.eval_context()
        assert ctx["state"]["fill_color"] == "#ff0000"
        assert ctx["panel"]["mode"] == "hsb"

    def test_eval_context_no_active_panel(self):
        store = StateStore({"x": 1})
        ctx = store.eval_context()
        assert ctx["state"]["x"] == 1
        assert ctx["panel"] == {}


class TestListPush:
    def test_push_to_front(self):
        store = StateStore()
        store.init_panel("color", {"recent": ["a", "b", "c"]})
        store.list_push("color", "recent", "d")
        assert store.get_panel("color", "recent") == ["d", "a", "b", "c"]

    def test_push_unique(self):
        store = StateStore()
        store.init_panel("color", {"recent": ["a", "b", "c"]})
        store.list_push("color", "recent", "b", unique=True)
        assert store.get_panel("color", "recent") == ["b", "a", "c"]

    def test_push_max_length(self):
        store = StateStore()
        store.init_panel("color", {"recent": ["a", "b", "c"]})
        store.list_push("color", "recent", "d", max_length=3)
        assert store.get_panel("color", "recent") == ["d", "a", "b"]

    def test_push_unique_and_max_length(self):
        store = StateStore()
        store.init_panel("color", {"recent": ["#aa", "#bb", "#cc"]})
        store.list_push("color", "recent", "#bb", unique=True, max_length=3)
        assert store.get_panel("color", "recent") == ["#bb", "#aa", "#cc"]
