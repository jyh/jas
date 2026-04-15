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


class TestOpenDialogEffect:
    """Tests for the open_dialog effect."""

    SIMPLE_DIALOG = {
        "simple": {
            "summary": "Simple",
            "modal": True,
            "state": {
                "name": {"type": "string", "default": ""},
            },
            "content": {"type": "container"},
        }
    }

    COLOR_PICKER_DIALOG = {
        "color_picker": {
            "summary": "Select Color",
            "modal": True,
            "params": {
                "target": {"type": "enum", "values": ["fill", "stroke"]},
            },
            "state": {
                "h": {"type": "number", "default": 0},
                "s": {"type": "number", "default": 0},
                "b": {"type": "number", "default": 100},
                "color": {"type": "color", "default": "#ffffff"},
            },
            "init": {
                "color": 'if param.target == "fill" then state.fill_color else state.stroke_color',
                "h": "hsb_h(dialog.color)",
                "s": "hsb_s(dialog.color)",
                "b": "hsb_b(dialog.color)",
            },
            "content": {"type": "container"},
        }
    }

    def test_open_dialog_sets_defaults(self):
        store = StateStore()
        run_effects(
            [{"open_dialog": {"id": "simple"}}],
            {}, store, dialogs=self.SIMPLE_DIALOG,
        )
        assert store.get_dialog_id() == "simple"
        assert store.get_dialog("name") == ""

    def test_open_dialog_with_params(self):
        store = StateStore({"fill_color": "#ff0000", "stroke_color": "#0000ff"})
        run_effects(
            [{"open_dialog": {"id": "color_picker",
                              "params": {"target": '"fill"'}}}],
            {}, store, dialogs=self.COLOR_PICKER_DIALOG,
        )
        assert store.get_dialog_id() == "color_picker"
        assert store.get_dialog("color") == "#ff0000"

    def test_open_dialog_runs_init(self):
        store = StateStore({"fill_color": "#00ff00", "stroke_color": "#0000ff"})
        run_effects(
            [{"open_dialog": {"id": "color_picker",
                              "params": {"target": '"fill"'}}}],
            {}, store, dialogs=self.COLOR_PICKER_DIALOG,
        )
        # hsb_h("#00ff00") = 120
        assert store.get_dialog("h") == 120
        assert store.get_dialog("s") == 100
        assert store.get_dialog("b") == 100

    def test_open_dialog_init_references_dialog_state(self):
        """Init expressions that reference dialog.* (e.g. h: hsb_h(dialog.color))."""
        store = StateStore({"fill_color": "#ff0000", "stroke_color": "#0000ff"})
        run_effects(
            [{"open_dialog": {"id": "color_picker",
                              "params": {"target": '"stroke"'}}}],
            {}, store, dialogs=self.COLOR_PICKER_DIALOG,
        )
        # dialog.color should be stroke_color = #0000ff
        assert store.get_dialog("color") == "#0000ff"
        # hsb_h("#0000ff") = 240
        assert store.get_dialog("h") == 240

    def test_open_dialog_param_expression_resolved(self):
        """Param values can be expressions referencing state."""
        store = StateStore({"fill_color": "#ff0000", "stroke_color": "#0000ff"})
        run_effects(
            [{"open_dialog": {"id": "color_picker",
                              "params": {"target": '"fill"'}}}],
            {}, store, dialogs=self.COLOR_PICKER_DIALOG,
        )
        assert store.get_dialog_params() == {"target": "fill"}

    def test_open_dialog_no_state_section(self):
        """Dialog with no state section should still open."""
        dialogs = {
            "confirm": {
                "summary": "Confirm",
                "modal": True,
                "content": {"type": "container"},
            }
        }
        store = StateStore()
        run_effects(
            [{"open_dialog": {"id": "confirm"}}],
            {}, store, dialogs=dialogs,
        )
        assert store.get_dialog_id() == "confirm"


class TestCloseDialogEffect:
    def test_close_dialog_clears_state(self):
        store = StateStore()
        store.init_dialog("test", {"x": 1}, params={"p": "v"})
        run_effects([{"close_dialog": None}], {}, store)
        assert store.get_dialog_id() is None
        assert store.get_dialog("x") is None

    def test_close_dialog_with_id(self):
        store = StateStore()
        store.init_dialog("test", {"x": 1})
        run_effects([{"close_dialog": "test"}], {}, store)
        assert store.get_dialog_id() is None

    def test_open_then_close(self):
        dialogs = {
            "simple": {
                "summary": "S",
                "state": {"name": {"type": "string", "default": ""}},
                "content": {"type": "container"},
            }
        }
        store = StateStore()
        run_effects([{"open_dialog": {"id": "simple"}}], {}, store, dialogs=dialogs)
        assert store.get_dialog_id() == "simple"
        run_effects([{"close_dialog": None}], {}, store)
        assert store.get_dialog_id() is None
        assert store.get_dialog_state() == {}


class TestDialogWithGlobalEffects:
    """Test that dialog effects work alongside global effects (set, etc.)."""

    def test_set_from_dialog_state(self):
        """An effect sequence that opens a dialog, then sets global state from dialog."""
        dialogs = {
            "picker": {
                "summary": "Pick",
                "state": {"color": {"type": "color", "default": "#aabbcc"}},
                "content": {"type": "container"},
            }
        }
        store = StateStore({"fill_color": None})
        # Open dialog
        run_effects([{"open_dialog": {"id": "picker"}}], {}, store, dialogs=dialogs)
        assert store.get_dialog("color") == "#aabbcc"
        # Set global state from dialog state
        run_effects([{"set": {"fill_color": "dialog.color"}}], {}, store)
        assert store.get("fill_color") == "#aabbcc"
