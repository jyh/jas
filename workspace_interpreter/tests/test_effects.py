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

    # Phase 1 — scope-routed set targets.

    def test_set_routes_tool_scope(self):
        store = StateStore()
        store.init_tool("selection", {"mode": "idle"})
        run_effects([{"set": {"tool.selection.mode": "'marquee'"}}], {}, store)
        assert store.get_tool("selection", "mode") == "marquee"

    def test_set_strips_leading_dollar(self):
        store = StateStore()
        store.init_tool("rect", {})
        run_effects([{"set": {"$tool.rect.mode": "'drawing'"}}], {}, store)
        assert store.get_tool("rect", "mode") == "drawing"

    def test_set_routes_state_scope(self):
        store = StateStore({"foo": 0})
        run_effects([{"set": {"state.foo": "7"}}], {}, store)
        assert store.get("foo") == 7

    def test_bare_key_writes_global(self):
        store = StateStore({"bar": 0})
        run_effects([{"set": {"bar": "9"}}], {}, store)
        assert store.get("bar") == 9

    def test_set_routes_panel_scope(self):
        store = StateStore()
        store.init_panel("color", {"mode": "hsb"})
        store.set_active_panel("color")
        run_effects([{"set": {"panel.mode": "'rgb'"}}], {}, store)
        assert store.get_panel("color", "mode") == "rgb"

    def test_set_tool_auto_creates_namespace_via_effect(self):
        store = StateStore()
        run_effects([{"set": {"tool.new_tool.flag": "true"}}], {}, store)
        assert store.has_tool("new_tool")
        assert store.get_tool("new_tool", "flag") is True


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


class TestStrokeDashedCheckboxToggle:
    """Spec pin for the Stroke panel's Dashed-Line checkbox (and the
    identically-shaped Link-scales / Flip-profile toggles). The canonical
    authoring pattern is a paired write:

        - set_panel_state: { key: <field>,  value: "not panel.<field>" }
        - set:            { stroke_<field>: "not state.stroke_<field>" }

    `set_panel_state` toggles the PANEL scope (drives the widget's
    `checked` binding); `set` toggles the GLOBAL scope (drives the
    apply-to-selection subscription). The two scopes are independent and
    each read is the pre-click value, so both flip in lockstep — the
    checkbox must toggle BOTH ways, not latch on. This is the executable
    meaning the active ports (Rust/Swift) must conform to: their panel
    eval-context must expose the live `state.stroke_dashed` so the
    `not state.stroke_dashed` read is the current value, not a stale
    default. See DASH_ALIGN.md / stroke.yaml Row 5."""

    _EFFECTS = [
        {"set_panel_state": {"key": "dashed", "value": "not panel.dashed"}},
        {"set": {"stroke_dashed": "not state.stroke_dashed"}},
    ]

    def _store(self):
        store = StateStore({"stroke_dashed": False})
        store.init_panel("stroke_panel_content", {"dashed": False})
        store.set_active_panel("stroke_panel_content")
        return store

    def test_first_click_turns_dashing_on(self):
        store = self._store()
        run_effects(self._EFFECTS, {}, store)
        assert store.get_panel("stroke_panel_content", "dashed") is True
        assert store.get("stroke_dashed") is True

    def test_second_click_turns_dashing_off(self):
        # The regression: the checkbox must be un-checkable. A second
        # click has to clear both scopes back to False.
        store = self._store()
        run_effects(self._EFFECTS, {}, store)  # on
        run_effects(self._EFFECTS, {}, store)  # off
        assert store.get_panel("stroke_panel_content", "dashed") is False
        assert store.get("stroke_dashed") is False


class TestLinkedArrowheadScaleMirror:
    """Spec pin for the Stroke panel's linked arrowhead-scale mirror
    (stroke.yaml Row 8). The two scale combo boxes carry a `commit`
    behavior that, WHEN `panel.link_arrowhead_scale` is true, writes the
    edited scale's value onto the OTHER scale — both the panel scope
    (drives the widget) and the global scope (drives apply-to-selection):

        - event: commit
          effects:
            - if:
                condition: "panel.link_arrowhead_scale"
                then:
                  - set_panel_state: { key: end_arrowhead_scale,
                                       value: "panel.start_arrowhead_scale" }
                  - set: { stroke_end_arrowhead_scale:
                             "panel.start_arrowhead_scale" }

    The native two-way bind already wrote the EDITED scale (panel +
    global) before the behavior runs, so the mirror reads the just-
    committed `panel.<edited>_arrowhead_scale` and copies it across. When
    unlinked the guard is false and the other scale is untouched — the
    two scales stay independent (the default). This is the executable
    meaning both active ports must conform to (Rust runs it via the
    combo commit-behavior hook; Swift is pending — see residuals)."""

    # The START combo's commit behavior effects (mirror onto END).
    _START_MIRROR = [
        {"if": {
            "condition": "panel.link_arrowhead_scale",
            "then": [
                {"set_panel_state": {"key": "end_arrowhead_scale",
                                     "value": "panel.start_arrowhead_scale"}},
                {"set": {"stroke_end_arrowhead_scale":
                         "panel.start_arrowhead_scale"}},
            ],
        }},
    ]
    # The END combo's commit behavior effects (mirror onto START).
    _END_MIRROR = [
        {"if": {
            "condition": "panel.link_arrowhead_scale",
            "then": [
                {"set_panel_state": {"key": "start_arrowhead_scale",
                                     "value": "panel.end_arrowhead_scale"}},
                {"set": {"stroke_start_arrowhead_scale":
                         "panel.end_arrowhead_scale"}},
            ],
        }},
    ]

    def _store(self, linked):
        # Globals seeded at the default 100; panel scope mirrors them.
        store = StateStore({
            "stroke_start_arrowhead_scale": 100,
            "stroke_end_arrowhead_scale": 100,
        })
        store.init_panel("stroke_panel_content", {
            "start_arrowhead_scale": 100,
            "end_arrowhead_scale": 100,
            "link_arrowhead_scale": linked,
        })
        store.set_active_panel("stroke_panel_content")
        return store

    def _commit(self, store, field, value):
        # Simulate the native two-way bind: the edited scale lands in
        # both the panel and the global scope before the mirror runs.
        store.set_panel("stroke_panel_content", field, value)
        store.set(f"stroke_{field}", value)

    def test_linked_start_edit_moves_both(self):
        store = self._store(linked=True)
        self._commit(store, "start_arrowhead_scale", 200)
        run_effects(self._START_MIRROR, {}, store)
        assert store.get_panel("stroke_panel_content", "end_arrowhead_scale") == 200
        assert store.get("stroke_end_arrowhead_scale") == 200
        # The edited scale is unchanged.
        assert store.get_panel("stroke_panel_content", "start_arrowhead_scale") == 200
        assert store.get("stroke_start_arrowhead_scale") == 200

    def test_linked_end_edit_moves_both(self):
        store = self._store(linked=True)
        self._commit(store, "end_arrowhead_scale", 75)
        run_effects(self._END_MIRROR, {}, store)
        assert store.get_panel("stroke_panel_content", "start_arrowhead_scale") == 75
        assert store.get("stroke_start_arrowhead_scale") == 75

    def test_unlinked_start_edit_is_independent(self):
        store = self._store(linked=False)
        self._commit(store, "start_arrowhead_scale", 200)
        run_effects(self._START_MIRROR, {}, store)
        # The other scale stays at its own value.
        assert store.get_panel("stroke_panel_content", "end_arrowhead_scale") == 100
        assert store.get("stroke_end_arrowhead_scale") == 100


class TestLinkedArrowheadScaleBundle:
    """The mirror above is authored in the shipped bundle, not just in
    the test — both scale combos must carry the `commit` behavior so the
    ports actually run it. Red before the stroke.yaml edit, green after."""

    def _panel(self, workspace_path):
        from workspace_interpreter.loader import load_workspace, find_element_by_id
        data = load_workspace(workspace_path)
        return data["panels"]["stroke_panel_content"], find_element_by_id

    def _mirror_target(self, widget):
        # The single if-guarded then-branch's set_panel_state key names
        # the OTHER scale the widget mirrors onto.
        assert widget is not None
        behavior = widget.get("behavior") or []
        commit = [b for b in behavior if b.get("event") == "commit"]
        assert commit, "scale combo must carry a commit behavior"
        effects = commit[0].get("effects") or []
        guard = effects[0]["if"]
        assert guard["condition"] == "panel.link_arrowhead_scale"
        then = guard["then"]
        return then[0]["set_panel_state"]["key"]

    def test_start_combo_mirrors_onto_end(self, workspace_path):
        panel, find = self._panel(workspace_path)
        w = find(panel, "stk_start_arrowhead_scale")
        assert self._mirror_target(w) == "end_arrowhead_scale"

    def test_end_combo_mirrors_onto_start(self, workspace_path):
        panel, find = self._panel(workspace_path)
        w = find(panel, "stk_end_arrowhead_scale")
        assert self._mirror_target(w) == "start_arrowhead_scale"


class TestStrokeSyncDoesNotClobberLinkFlag:
    """Regression pin (LINKSCALE feature 2): the selection -> panel
    refresh (`sync_stroke_panel_from_selection`) mirrors only the baked
    stroke WEIGHT / cap / join into the panel. It must NOT touch the
    UI-only `link_arrowhead_scale` flag — otherwise editing a scale
    (which re-runs the refresh) would drop the chain highlight. The
    reference never wrote the flag; this locks that in."""

    def test_sync_leaves_link_flag_untouched(self):
        from workspace_interpreter.effects import sync_stroke_panel_from_selection

        class _Stroke:
            width = 3.0
            linecap = None
            linejoin = None

        class _Doc:
            selection = []

        class _Model:
            document = _Doc()
            default_stroke = _Stroke()

        store = StateStore()
        store.init_panel("stroke_panel_content", {"link_arrowhead_scale": True})
        store.set_active_panel("stroke_panel_content")
        sync_stroke_panel_from_selection(store, _Model())
        assert store.get_panel(
            "stroke_panel_content", "link_arrowhead_scale") is True


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


class TestListPopEffect:
    def test_pop_removes_last_element(self):
        store = StateStore()
        store.init_panel("layers", {"isolation_stack": [{"id": "a"}, {"id": "b"}]})
        store.set_active_panel("layers")
        run_effects([{"pop": "panel.isolation_stack"}], {}, store)
        assert store.get_panel("layers", "isolation_stack") == [{"id": "a"}]

    def test_pop_empty_list_is_noop(self):
        store = StateStore()
        store.init_panel("layers", {"isolation_stack": []})
        store.set_active_panel("layers")
        run_effects([{"pop": "panel.isolation_stack"}], {}, store)
        assert store.get_panel("layers", "isolation_stack") == []

    def test_pop_single_element_leaves_empty(self):
        store = StateStore()
        store.init_panel("layers", {"isolation_stack": [{"id": "x"}]})
        store.set_active_panel("layers")
        run_effects([{"pop": "panel.isolation_stack"}], {}, store)
        assert store.get_panel("layers", "isolation_stack") == []

    def test_pop_global_list(self):
        store = StateStore({"my_stack": [1, 2, 3]})
        run_effects([{"pop": "my_stack"}], {}, store)
        assert store.get("my_stack") == [1, 2]


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


class TestDialogPreviewSnapshot:
    """open_dialog captures a snapshot of every state key referenced by
    the dialog's preview_targets. close_dialog restores from the
    snapshot unless first cleared by clear_dialog_snapshot (which OK
    actions emit in Phase 8/9). Phase 0 supports only top-level state
    keys; deep paths defer to Phase 8/9."""

    def test_open_dialog_captures_preview_snapshot(self):
        dialogs = {
            "para_indent": {
                "summary": "Indents",
                "state": {
                    "left": {"type": "number", "default": 0},
                    "right": {"type": "number", "default": 0},
                },
                "preview_targets": {
                    "left": "left_indent",
                    "right": "right_indent",
                },
                "content": {"type": "container"},
            }
        }
        store = StateStore({"left_indent": 12, "right_indent": 0})
        run_effects([{"open_dialog": {"id": "para_indent"}}], {}, store, dialogs=dialogs)
        snap = store.get_dialog_snapshot()
        assert snap == {"left_indent": 12, "right_indent": 0}

    def test_open_dialog_without_preview_targets_no_snapshot(self):
        dialogs = {
            "plain": {
                "summary": "Plain",
                "state": {"name": {"type": "string", "default": ""}},
                "content": {"type": "container"},
            }
        }
        store = StateStore()
        run_effects([{"open_dialog": {"id": "plain"}}], {}, store, dialogs=dialogs)
        assert not store.has_dialog_snapshot()

    def test_close_dialog_restores_from_snapshot(self):
        dialogs = {
            "para_indent": {
                "summary": "Indents",
                "state": {"left": {"type": "number", "default": 0}},
                "preview_targets": {"left": "left_indent"},
                "content": {"type": "container"},
            }
        }
        store = StateStore({"left_indent": 12})
        run_effects([{"open_dialog": {"id": "para_indent"}}], {}, store, dialogs=dialogs)
        # Simulate Preview live-applying an edit
        store.set("left_indent", 99)
        # Cancel restores
        run_effects([{"close_dialog": None}], {}, store)
        assert store.get("left_indent") == 12
        assert store.get_dialog_id() is None
        assert not store.has_dialog_snapshot()

    def test_clear_dialog_snapshot_prevents_restore(self):
        dialogs = {
            "para_indent": {
                "summary": "Indents",
                "state": {"left": {"type": "number", "default": 0}},
                "preview_targets": {"left": "left_indent"},
                "content": {"type": "container"},
            }
        }
        store = StateStore({"left_indent": 12})
        run_effects([{"open_dialog": {"id": "para_indent"}}], {}, store, dialogs=dialogs)
        store.set("left_indent", 99)
        # OK action equivalent: clear snapshot, then close
        run_effects([
            {"clear_dialog_snapshot": None},
            {"close_dialog": None},
        ], {}, store)
        assert store.get("left_indent") == 99
        assert store.get_dialog_id() is None


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
