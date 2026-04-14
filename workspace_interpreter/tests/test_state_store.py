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


class TestDialogState:
    def test_init_dialog(self):
        store = StateStore()
        store.init_dialog("color_picker", {"h": 0, "s": 0, "color": "#ffffff"},
                          params={"target": "fill"})
        assert store.get_dialog_id() == "color_picker"
        assert store.get_dialog("h") == 0
        assert store.get_dialog("color") == "#ffffff"
        assert store.get_dialog_params() == {"target": "fill"}

    def test_get_set_dialog(self):
        store = StateStore()
        store.init_dialog("test", {"name": ""})
        store.set_dialog("name", "hello")
        assert store.get_dialog("name") == "hello"

    def test_get_dialog_missing_key_returns_none(self):
        store = StateStore()
        store.init_dialog("test", {"x": 1})
        assert store.get_dialog("nonexistent") is None

    def test_get_dialog_no_dialog_returns_none(self):
        store = StateStore()
        assert store.get_dialog("anything") is None
        assert store.get_dialog_id() is None
        assert store.get_dialog_params() is None

    def test_close_dialog(self):
        store = StateStore()
        store.init_dialog("test", {"x": 1}, params={"p": "v"})
        store.close_dialog()
        assert store.get_dialog_id() is None
        assert store.get_dialog("x") is None
        assert store.get_dialog_params() is None
        assert store.get_dialog_state() == {}

    def test_get_dialog_state_returns_copy(self):
        store = StateStore()
        store.init_dialog("test", {"a": 1, "b": 2})
        state = store.get_dialog_state()
        assert state == {"a": 1, "b": 2}
        state["a"] = 999  # mutating copy shouldn't affect store
        assert store.get_dialog("a") == 1

    def test_eval_context_includes_dialog(self):
        store = StateStore({"fill_color": "#ff0000"})
        store.init_dialog("test", {"h": 180, "s": 50})
        ctx = store.eval_context()
        assert ctx["state"]["fill_color"] == "#ff0000"
        assert ctx["dialog"]["h"] == 180
        assert ctx["dialog"]["s"] == 50

    def test_eval_context_includes_dialog_params(self):
        store = StateStore()
        store.init_dialog("test", {"x": 1}, params={"target": "fill"})
        ctx = store.eval_context()
        assert ctx["param"]["target"] == "fill"

    def test_eval_context_extra_param_overrides_dialog_params(self):
        """Extra context param takes precedence over dialog params."""
        store = StateStore()
        store.init_dialog("test", {"x": 1}, params={"target": "fill"})
        ctx = store.eval_context({"param": {"target": "stroke"}})
        assert ctx["param"]["target"] == "stroke"

    def test_dialog_absent_when_closed(self):
        store = StateStore({"x": 1})
        ctx = store.eval_context()
        assert "dialog" not in ctx

    def test_dialog_and_panel_coexist(self):
        """Dialog and panel namespaces are independent."""
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.set_active_panel("color")
        store.init_dialog("picker", {"h": 270})
        ctx = store.eval_context()
        assert ctx["panel"]["mode"] == "hsb"
        assert ctx["dialog"]["h"] == 270

    def test_init_dialog_replaces_previous(self):
        store = StateStore()
        store.init_dialog("first", {"x": 1})
        store.init_dialog("second", {"y": 2})
        assert store.get_dialog_id() == "second"
        assert store.get_dialog("x") is None
        assert store.get_dialog("y") == 2
