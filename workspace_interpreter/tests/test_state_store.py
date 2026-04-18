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


class TestDialogPreviewSnapshot:
    """capture_dialog_snapshot copies the current value of every state
    key referenced by a dialog's preview_targets. Phase 0 supports
    only top-level state keys; deep paths (containing a dot) are
    silently skipped and will land alongside their first real
    consumer in Phase 8/9."""

    def test_dialog_snapshot_capture_and_get(self):
        store = StateStore({"left_indent": 12, "right_indent": 0})
        store.capture_dialog_snapshot({
            "dlg_left": "left_indent",
            "dlg_right": "right_indent",
        })
        snap = store.get_dialog_snapshot()
        assert snap == {"left_indent": 12, "right_indent": 0}
        assert store.has_dialog_snapshot()

    def test_dialog_snapshot_clear_drops_it(self):
        store = StateStore({"x": 1})
        store.capture_dialog_snapshot({"k": "x"})
        assert store.has_dialog_snapshot()
        store.clear_dialog_snapshot()
        assert not store.has_dialog_snapshot()
        assert store.get_dialog_snapshot() is None

    def test_dialog_snapshot_skips_deep_paths_for_phase0(self):
        store = StateStore({"flat": 1})
        store.capture_dialog_snapshot({
            "a": "flat",
            "b": "selection.deep.path",
        })
        snap = store.get_dialog_snapshot()
        assert "flat" in snap
        assert "selection.deep.path" not in snap


class TestDialogProperties:
    """Tests for get/set reactive properties on dialog state."""

    def test_get_property(self):
        """Variable with get expr computes value from sibling state."""
        store = StateStore()
        store.init_dialog("test", {"x": 10}, props={
            "doubled": {"get": "x * 2"},
        })
        assert store.get_dialog("x") == 10
        assert store.get_dialog("doubled") == 20

    def test_get_uses_current_state(self):
        """Getter re-evaluates when underlying state changes."""
        store = StateStore()
        store.init_dialog("test", {"x": 5}, props={
            "doubled": {"get": "x * 2"},
        })
        assert store.get_dialog("doubled") == 10
        store.set_dialog("x", 20)
        assert store.get_dialog("doubled") == 40

    def test_set_property(self):
        """Variable with set expr runs lambda and updates targets."""
        store = StateStore()
        store.init_dialog("test", {"color": "#ff0000"}, props={
            "r": {
                "get": "rgb_r(color)",
                "set": "fun v -> color <- rgb(v, rgb_g(color), rgb_b(color))",
            },
        })
        assert store.get_dialog("r") == 255
        store.set_dialog("r", 0)
        assert store.get_dialog("color") == "#000000"  # was #ff0000 (r=255,g=0,b=0), set r=0
        assert store.get_dialog("r") == 0

    def test_derived_chain(self):
        """Set h → updates color → reading r recomputes from new color."""
        store = StateStore()
        store.init_dialog("test", {"color": "#ff0000"}, props={
            "h": {
                "get": "hsb_h(color)",
                "set": "fun v -> color <- hsb(v, hsb_s(color), hsb_b(color))",
            },
            "r": {"get": "rgb_r(color)"},
            "c": {"get": "cmyk_c(color)"},
        })
        assert store.get_dialog("h") == 0  # red = hue 0
        store.set_dialog("h", 120)  # green
        color = store.get_dialog("color")
        assert color == "#00ff00"
        assert store.get_dialog("r") == 0
        assert store.get_dialog("c") == 100  # CMYK cyan for green

    def test_plain_var_no_props(self):
        """Variables without get/set behave as before."""
        store = StateStore()
        store.init_dialog("test", {"x": 5}, props={})
        assert store.get_dialog("x") == 5
        store.set_dialog("x", 10)
        assert store.get_dialog("x") == 10

    def test_get_only_readonly(self):
        """Variable with get but no set ignores writes."""
        store = StateStore()
        store.init_dialog("test", {"color": "#ff0000"}, props={
            "r": {"get": "rgb_r(color)"},
        })
        assert store.get_dialog("r") == 255
        store.set_dialog("r", 0)  # should be ignored
        assert store.get_dialog("r") == 255  # unchanged

    def test_set_with_let(self):
        """Setter using let for local bindings."""
        store = StateStore()
        store.init_dialog("test", {"color": "#ff0000"}, props={
            "bl": {
                "get": "rgb_b(color)",
                "set": "fun v -> let r = rgb_r(color) in let g = rgb_g(color) in color <- rgb(r, g, v)",
            },
        })
        store.set_dialog("bl", 128)
        # Original was #ff0000 (r=255, g=0, b=0), set bl=128
        assert store.get_dialog("color") == "#ff0080"
