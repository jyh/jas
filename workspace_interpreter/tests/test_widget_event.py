"""The widget event contract (WIDGET_EVENTS.md), driven against the reference
StateStore.

Two kinds of arm live here. The SYNTHETIC arms pin one clause each with a
widget small enough to read. The SHIPPED arms load the real workspace and
drive the real magic_wand and stroke widgets. They are the ones that say
whether the contract means what the YAML's authors wrote, and they carry
the ORDER arm: the only place where "the bind write comes first" and "the
bind write comes last" give different answers.
"""

import json
import math
import os

import pytest

from workspace_interpreter import widget_event as we
from workspace_interpreter.loader import (
    find_element_by_id,
    load_workspace,
    panel_state_defaults,
    state_defaults,
)
from workspace_interpreter.state_store import StateStore

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
NUMBER_COMMIT = os.path.join(
    REPO_ROOT, "test_fixtures", "algorithms", "number_commit.json")


def _panel_store(panel_id, panel_state, globals_=None):
    store = StateStore(dict(globals_ or {}))
    store.init_panel(panel_id, dict(panel_state))
    store.set_active_panel(panel_id)
    return store


def _recorder(store, panel_id):
    """Log every panel and global write, in the order the store saw them."""
    log = []
    store.subscribe_panel(panel_id, lambda k, v: log.append(("panel", k, v)))
    store.subscribe(None, lambda k, v: log.append(("state", k, v)))
    return log


# ── The table ──────────────────────────────────────────────────


class TestContractTable:
    def test_the_eight_kinds_and_nothing_else(self):
        assert set(we.ALLOWED_EVENTS) == we.INPUT_KINDS | we.BOOLEAN_KINDS
        assert len(we.INPUT_KINDS) == 6 and len(we.BOOLEAN_KINDS) == 2
        assert not (we.INPUT_KINDS & we.BOOLEAN_KINDS)

    def test_input_kinds_commit_on_commit_or_change(self):
        for kind in we.INPUT_KINDS - {"text_input"}:
            assert we.ALLOWED_EVENTS[kind] == ("commit", "change"), kind

    def test_text_input_adds_its_three_non_commit_events(self):
        assert we.ALLOWED_EVENTS["text_input"] == (
            "commit", "change", "input", "blur", "keydown")

    def test_boolean_kinds_press_on_click_or_change(self):
        for kind in we.BOOLEAN_KINDS:
            assert we.ALLOWED_EVENTS[kind] == ("click", "change"), kind


# ── Parsing, kind by kind ──────────────────────────────────────


class TestNumberCommitRule:
    def _vectors(self):
        with open(NUMBER_COMMIT, encoding="utf-8") as f:
            vectors = json.load(f)["vectors"]
        assert len(vectors) > 10, "the shared corpus must not be empty"
        return vectors

    def test_every_shared_vector(self):
        # The corpus both active ports are gated by. Its expectations were
        # derived from the reference's coercion, so this is the reference
        # agreeing with the rule it was the source of.
        ran = 0
        for v in self._vectors():
            got = we.number_commit(v["text"], v.get("min"), v.get("max"))
            assert got == v["expected"], v["name"]
            if got is not None:
                assert isinstance(got, float), v["name"]
            ran += 1
        assert ran == len(self._vectors())

    def test_the_grammar_is_ascii_and_whole_string(self):
        # The reference's `set:` coercion (schema._NUMBER_STR_RE with
        # re.match) accepts both of these. A widget commit does not, which
        # is what both active ports do (widget_commit.rs, WidgetCommit.swift).
        assert we.number_commit("١٢", None, None) is None
        assert we.number_commit("12\n", None, None) is None
        assert we.number_commit("12", None, None) == 12.0

    def test_a_bool_bound_is_not_a_bound(self):
        assert we.number_commit("5", True, None) == 5.0


class TestParseByKind:
    def test_number_input_clamps_to_its_declared_bounds(self):
        w = {"type": "number_input", "min": 0, "max": 255}
        assert we.parse_commit(w, "300") == (True, 255.0)
        assert we.parse_commit(w, "abc") == (False, None)

    def test_length_input_converts_to_pt(self):
        w = {"type": "length_input", "unit": "pt"}
        ok, v = we.parse_commit(w, "5 mm")
        assert ok and math.isclose(v, 5 * 72 / 25.4)
        assert we.parse_commit(w, "12") == (True, 12.0)

    def test_length_input_bare_number_takes_the_widget_unit(self):
        assert we.parse_commit({"type": "length_input", "unit": "in"}, "2") == (True, 144.0)

    def test_length_input_unit_defaults_to_pt(self):
        assert we.parse_commit({"type": "length_input"}, "3") == (True, 3.0)

    def test_length_input_clamps_rather_than_rejects(self):
        # Both active ports clamp (renderer.rs render_length_input,
        # YamlPanelBodyView.swift renderLengthInput); UNIT_INPUTS.md said
        # "reject" until this contract.
        w = {"type": "length_input", "unit": "pt", "min": 0, "max": 1000}
        assert we.parse_commit(w, "2000") == (True, 1000.0)
        assert we.parse_commit(w, "-3") == (True, 0.0)

    def test_length_input_refuses_what_parse_length_refuses(self):
        w = {"type": "length_input", "unit": "pt"}
        for text in ("5 dpi", "pt", "5 mm 3", "abc"):
            assert we.parse_commit(w, text) == (False, None), text

    def test_length_input_blank_is_null_only_when_the_widget_is_nullable(self):
        assert we.parse_commit(
            {"type": "length_input", "nullable": True}, "   ") == (True, None)
        assert we.parse_commit(
            {"type": "length_input"}, "   ") == (False, None)
        assert we.parse_commit(
            {"type": "length_input", "nullable": False}, "") == (False, None)

    def test_text_input_is_verbatim(self):
        w = {"type": "text_input"}
        for text in ("", "  padded  ", "12", "Layer 1"):
            assert we.parse_commit(w, text) == (True, text)

    def test_select_takes_the_matching_options_declared_value(self):
        w = {"type": "select", "options": [
            {"label": "Letter", "value": "letter"},
            {"label": "Two", "value": 2},
        ]}
        assert we.parse_commit(w, "letter") == (True, "letter")
        assert we.parse_commit(w, "2") == (True, 2)
        assert we.parse_commit(w, "Letter") == (False, None)
        assert we.parse_commit(w, "legal") == (False, None)

    def test_icon_select_is_a_select(self):
        w = {"type": "icon_select", "options": [
            {"value": "", "glyph": "-", "label": "None"},
            {"value": "bullet-disc", "glyph": "*", "label": "Disc"},
        ]}
        assert we.parse_commit(w, "") == (True, "")
        assert we.parse_commit(w, "bullet-disc") == (True, "bullet-disc")
        assert we.parse_commit(w, "bullet-square") == (False, None)

    def test_select_with_computed_options_takes_the_text(self):
        w = {"type": "select", "options": "state.font_families"}
        assert we.parse_commit(w, "Helvetica") == (True, "Helvetica")

    def test_combo_box_number_by_the_number_grammar_and_clamped(self):
        w = {"type": "combo_box", "min": 1, "options": [50, 100, 200]}
        assert we.parse_commit(w, "150") == (True, 150.0)
        assert we.parse_commit(w, "0") == (True, 1.0)

    def test_combo_box_non_number_is_its_text(self):
        w = {"type": "combo_box", "options": [{"label": "Auto", "value": "auto"}]}
        assert we.parse_commit(w, "Auto") == (True, "Auto")
        # The platform float parsers both ports use accept these; the
        # contract's number grammar does not.
        assert we.parse_commit(w, "1e3") == (True, "1e3")
        assert we.parse_commit(w, "inf") == (True, "inf")

    def test_combo_box_blank_is_refused(self):
        assert we.parse_commit({"type": "combo_box"}, "") == (False, None)
        assert we.parse_commit({"type": "combo_box"}, "  ") == (False, None)

    def test_a_boolean_kind_has_no_text_parse(self):
        with pytest.raises(ValueError):
            we.parse_commit({"type": "toggle"}, "true")


class TestBoundTarget:
    def test_precedence_value_then_checked_then_bare_string(self):
        assert we.bound_target({"bind": {"value": "panel.a", "checked": "panel.b"}}) == "panel.a"
        assert we.bound_target({"bind": {"checked": "panel.b", "disabled": "x"}}) == "panel.b"
        assert we.bound_target({"bind": "dialog.c"}) == "dialog.c"
        assert we.bound_target({"bind": {"disabled": "x"}}) is None
        assert we.bound_target({}) is None

    def test_writable_is_panel_or_dialog_identifier_only(self):
        assert we.writable_target("panel.fill_tolerance") == ("panel", "fill_tolerance")
        assert we.writable_target(" dialog.web_only ") == ("dialog", "web_only")
        for expr in ("state.magic_wand_fill_color", "selection_mask_clip",
                     "ab.name", "not panel.x", "panel.stops[panel.i].opacity",
                     "panel.", "${bind}", None):
            assert we.writable_target(expr) is None, expr


# ── Committing a value ─────────────────────────────────────────


class TestCommitSynthetic:
    PID = "probe_panel_content"

    def _store(self, **panel):
        return _panel_store(self.PID, {"n": 1, "log": [], **panel})

    def test_writes_the_bound_field_then_runs_the_behavior(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": "commit", "effects": [
                 {"set": {"seen": "panel.n"}}]}]}
        r = we.commit(w, "7", store, panel=None)
        assert r == we.EventResult("committed", value=7.0,
                                   bind_written=True, behaviors_run=1)
        # The behavior read the NEW value from the store, not a patched scope.
        assert store.get("seen") == 7.0
        assert log == [("panel", "n", 7.0), ("state", "seen", 7.0)]

    def test_event_value_is_the_typed_parse(self):
        store = self._store()
        w = {"type": "length_input", "unit": "in", "bind": {"value": "panel.n"},
             "behavior": [{"event": "commit", "effects": [
                 {"set": {"echo": "event.value"}}]}]}
        we.commit(w, "1", store, panel=None)
        assert store.get("echo") == 72.0

    def test_commit_and_change_both_run_in_declaration_order(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "select", "options": [{"value": "a"}],
             "bind": {"value": "panel.n"},
             "behavior": [
                 {"event": "change", "effects": [{"set": {"first": "1"}}]},
                 {"event": "input", "effects": [{"set": {"never": "1"}}]},
                 {"event": "commit", "effects": [{"set": {"second": "2"}}]},
             ]}
        r = we.commit(w, "a", store, panel=None)
        assert r.behaviors_run == 2
        assert [e[1] for e in log] == ["n", "first", "second"]
        assert store.get("never") is None

    def test_text_entry_events_are_not_commits(self):
        store = self._store()
        w = {"type": "text_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": e, "effects": [{"set": {e: "1"}}]}
                          for e in ("input", "blur", "keydown")]}
        r = we.commit(w, "x", store, panel=None)
        assert r == we.EventResult("committed", value="x",
                                   bind_written=True, behaviors_run=0)
        assert [store.get(e) for e in ("input", "blur", "keydown")] == [None] * 3

    def test_a_refused_parse_moves_nothing_and_runs_nothing(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": "commit", "effects": [{"set": {"ran": "true"}}]}]}
        assert we.commit(w, "abc", store, panel=None) == we.EventResult(
            "refused", reason=we.BAD_VALUE)
        assert log == []
        assert store.get_panel(self.PID, "n") == 1

    def test_a_missing_value_moves_nothing(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "number_input", "bind": {"value": "panel.n"}}
        assert we.commit(w, None, store, panel=None) == we.EventResult(
            "refused", reason=we.MISSING_VALUE)
        assert log == []

    def test_a_disabled_widget_moves_nothing(self):
        store = self._store(on=False)
        log = _recorder(store, self.PID)
        w = {"type": "number_input",
             "bind": {"value": "panel.n", "disabled": "not panel.on"},
             "behavior": [{"event": "commit", "effects": [{"set": {"ran": "true"}}]}]}
        assert we.commit(w, "5", store, panel=None) == we.EventResult(
            "refused", reason=we.DISABLED)
        assert log == []

    def test_an_enabled_widget_with_a_disabled_clause_commits(self):
        store = self._store(on=True)
        w = {"type": "number_input",
             "bind": {"value": "panel.n", "disabled": "not panel.on"}}
        assert we.commit(w, "5", store, panel=None).outcome == "committed"
        assert store.get_panel(self.PID, "n") == 5.0

    def test_a_non_writable_bind_still_runs_the_behavior(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "text_input", "bind": {"value": "ab.name"},
             "behavior": [{"event": "commit", "effects": [
                 {"set": {"renamed": "event.value"}}]}]}
        r = we.commit(w, "Board 2", store, panel=None)
        assert r == we.EventResult("committed", value="Board 2",
                                   bind_written=False, behaviors_run=1)
        assert log == [("state", "renamed", "Board 2")]

    def test_nothing_bound_and_nothing_declared_is_inert(self):
        store = self._store()
        log = _recorder(store, self.PID)
        r = we.commit({"type": "number_input"}, "5", store, panel=None)
        assert r == we.EventResult("inert", value=5.0)
        assert log == []

    def test_a_false_condition_skips_that_behavior_only(self):
        store = self._store()
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [
                 {"event": "commit", "condition": "panel.n > 10",
                  "effects": [{"set": {"big": "true"}}]},
                 {"event": "commit", "effects": [{"set": {"any": "true"}}]},
             ]}
        assert we.commit(w, "5", store, panel=None).behaviors_run == 1
        assert store.get("big") is None and store.get("any") is True
        assert we.commit(w, "50", store, panel=None).behaviors_run == 2
        assert store.get("big") is True

    def test_an_action_behavior_dispatches_with_params_read_after_the_write(self):
        # A self-referential param names the field being edited. It must
        # read the NEW value (the case run_input_behavior's doc records).
        store = self._store()
        actions = {"remember": {"effects": [{"set": {"got": "param.v"}}]}}
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": "change", "action": "remember",
                           "params": {"v": "panel.n"}}]}
        r = we.commit(w, "9", store, actions=actions, panel=None)
        assert r.behaviors_run == 1
        assert store.get("got") == 9.0

    def test_effects_run_before_the_action_within_one_behavior(self):
        store = self._store()
        actions = {"copy": {"effects": [{"set": {"after": "state.before"}}]}}
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": "commit", "action": "copy",
                           "effects": [{"set": {"before": "panel.n"}}]}]}
        we.commit(w, "4", store, actions=actions, panel=None)
        assert store.get("after") == 4.0

    def test_a_dialog_bind_writes_the_open_dialog(self):
        store = StateStore()
        store.init_dialog("d", {"x": 1})
        w = {"type": "number_input", "bind": "dialog.x"}
        assert we.commit(w, "3", store, panel=None).bind_written
        assert store.get_dialog("x") == 3.0

    def test_a_boolean_kind_is_refused_by_commit(self):
        store = self._store()
        r = we.commit({"type": "toggle", "bind": {"checked": "panel.n"}}, "x", store, panel=None)
        assert r == we.EventResult("refused", reason=we.WRONG_KIND)

    def test_an_unknown_kind_is_refused_by_commit(self):
        store = self._store()
        r = we.commit({"type": "slider", "bind": {"value": "panel.n"}}, "3", store, panel=None)
        assert r == we.EventResult("refused", reason=we.WRONG_KIND)
        assert store.get_panel(self.PID, "n") == 1


# ── Pressing a boolean ─────────────────────────────────────────


class TestPressSynthetic:
    PID = "probe_panel_content"

    def test_no_behavior_writes_the_negation(self):
        store = _panel_store(self.PID, {"on": True})
        r = we.press({"type": "toggle", "bind": {"checked": "panel.on"}}, store, panel=None)
        assert r == we.EventResult("committed", value=False,
                                   bind_written=True, behaviors_run=0)
        assert store.get_panel(self.PID, "on") is False
        we.press({"type": "checkbox", "bind": {"value": "panel.on"}}, store, panel=None)
        assert store.get_panel(self.PID, "on") is True

    def test_a_declared_behavior_replaces_the_bind_write(self):
        store = _panel_store(self.PID, {"on": True})
        log = _recorder(store, self.PID)
        w = {"type": "checkbox", "bind": {"checked": "panel.on"},
             "behavior": [{"event": "click", "effects": [
                 {"set": {"seen": "event.value"}},
                 {"set": {"panel_was": "panel.on"}}]}]}
        r = we.press(w, store, panel=None)
        assert r == we.EventResult("committed", value=False,
                                   bind_written=False, behaviors_run=1)
        # event.value carries the new boolean; the field was not written.
        assert log == [("state", "seen", False), ("state", "panel_was", True)]

    def test_change_and_click_both_run_and_nothing_else_does(self):
        store = _panel_store(self.PID, {"on": False})
        w = {"type": "toggle", "bind": {"checked": "panel.on"},
             "behavior": [
                 {"event": "change", "effects": [{"set": {"a": "event.value"}}]},
                 {"event": "commit", "effects": [{"set": {"never": "1"}}]},
                 {"event": "click", "effects": [{"set": {"b": "event.value"}}]},
             ]}
        assert we.press(w, store, panel=None).behaviors_run == 2
        assert (store.get("a"), store.get("b"), store.get("never")) == (True, True, None)

    def test_a_declared_behavior_owns_the_press_even_when_its_condition_is_false(self):
        store = _panel_store(self.PID, {"on": True, "armed": False})
        w = {"type": "toggle", "bind": {"checked": "panel.on"},
             "behavior": [{"event": "click", "condition": "panel.armed",
                           "effects": [{"set": {"ran": "true"}}]}]}
        assert we.press(w, store, panel=None) == we.EventResult("inert", value=False)
        assert store.get_panel(self.PID, "on") is True
        assert store.get("ran") is None

    def test_a_non_boolean_bound_value_reads_by_truthiness(self):
        store = _panel_store(self.PID, {"mode": "on"})
        assert we.press({"type": "toggle", "bind": {"checked": "panel.mode"}},
                        store, panel=None).value is False

    def test_an_expression_bind_is_read_but_not_written(self):
        store = _panel_store(self.PID, {"mode": "a"})
        w = {"type": "toggle", "bind": {"checked": "panel.mode == 'a'"}}
        assert we.press(w, store, panel=None) == we.EventResult("inert", value=False)
        assert store.get_panel(self.PID, "mode") == "a"

    def test_unbound_and_undeclared_is_inert(self):
        store = StateStore()
        assert we.press({"type": "toggle"}, store, panel=None) == we.EventResult("inert", value=True)

    def test_a_disabled_boolean_moves_nothing(self):
        store = _panel_store(self.PID, {"on": True, "lock": True})
        w = {"type": "toggle",
             "bind": {"checked": "panel.on", "disabled": "panel.lock"}}
        assert we.press(w, store, panel=None) == we.EventResult("refused", reason=we.DISABLED)
        assert store.get_panel(self.PID, "on") is True

    def test_an_input_kind_is_refused_by_press(self):
        store = _panel_store(self.PID, {"n": 1})
        r = we.press({"type": "number_input", "bind": {"value": "panel.n"}}, store, panel=None)
        assert r == we.EventResult("refused", reason=we.WRONG_KIND)


# ── The two-way bind: a panel field and the global its `init:` reads ──


class TestTwoWayBind:
    """A panel's `init:` maps a field to the global it hydrates from. When
    that mapping is a bare `state.<ident>`, the bind write writes the global
    too, in the same step, before any behavior. The shipped YAML says so:
    stroke.yaml's scale combos rely on "the native two-way bind" to have
    written the global that "drives apply-to-selection"."""
    PID = "probe_panel_content"
    PANEL = {"init": {"n": "state.gn", "e": "state.a + 1", "z": "0",
                      "f": "hsb_h(state.c)", "b": "state.gb"}}

    def _store(self, **panel):
        return _panel_store(self.PID, {"n": 1, "e": 1, "z": 0, "f": 0, "b": True, **panel},
                            {"gn": 1, "a": 0, "gb": True})

    def test_the_mapped_global_is_written_with_the_field_and_before_behaviors(self):
        store = self._store()
        log = _recorder(store, self.PID)
        w = {"type": "number_input", "bind": {"value": "panel.n"},
             "behavior": [{"event": "commit", "effects": [{"set": {"seen": "state.gn"}}]}]}
        r = we.commit(w, "7", store, panel=self.PANEL)
        assert r.bind_written
        assert log == [("panel", "n", 7.0), ("state", "gn", 7.0), ("state", "seen", 7.0)]

    def test_only_a_bare_state_mapping_is_mirrored(self):
        for key in ("e", "z", "f"):
            store = self._store()
            before = store.get_all()
            we.commit({"type": "number_input", "bind": {"value": f"panel.{key}"}},
                      "5", store, panel=self.PANEL)
            assert store.get_panel(self.PID, key) == 5.0, key
            assert store.get_all() == before, key

    def test_an_unmapped_field_and_no_panel_write_the_field_only(self):
        store = self._store(u=0)
        before = store.get_all()
        we.commit({"type": "number_input", "bind": {"value": "panel.u"}}, "5", store,
                  panel=self.PANEL)
        we.commit({"type": "number_input", "bind": {"value": "panel.n"}}, "6", store,
                  panel=None)
        assert store.get_all() == before
        assert store.get_panel(self.PID, "n") == 6.0

    def test_a_panel_without_init_mirrors_nothing(self):
        store = self._store()
        before = store.get_all()
        we.commit({"type": "number_input", "bind": {"value": "panel.n"}}, "6", store,
                  panel={"id": "p"})
        assert store.get_all() == before

    def test_an_undeclared_press_writes_both(self):
        store = self._store()
        r = we.press({"type": "toggle", "bind": {"checked": "panel.b"}}, store,
                     panel=self.PANEL)
        assert r.bind_written
        assert store.get_panel(self.PID, "b") is False
        assert store.get("gb") is False

    def test_a_declared_press_writes_neither(self):
        store = self._store()
        w = {"type": "toggle", "bind": {"checked": "panel.b"},
             "behavior": [{"event": "click", "effects": [{"set": {"x": "1"}}]}]}
        we.press(w, store, panel=self.PANEL)
        assert store.get_panel(self.PID, "b") is True
        assert store.get("gb") is True

    def test_a_refusal_writes_neither(self):
        store = self._store()
        before = (store.get_panel_state(self.PID), store.get_all())
        we.commit({"type": "number_input", "bind": {"value": "panel.n"}}, "x", store,
                  panel=self.PANEL)
        assert (store.get_panel_state(self.PID), store.get_all()) == before

    def test_the_panel_keyword_is_required(self):
        with pytest.raises(TypeError):
            we.commit({"type": "number_input"}, "1", StateStore())
        with pytest.raises(TypeError):
            we.press({"type": "toggle"}, StateStore())


# ── The shipped widgets ────────────────────────────────────────


class _Shipped:
    PANEL = ""

    def _setup(self, workspace_path):
        data = load_workspace(workspace_path)
        panel = data["panels"][self.PANEL]
        globals_ = state_defaults(data["state"])
        store = _panel_store(self.PANEL, panel_state_defaults(panel), globals_)
        # Opening the panel hydrates it from its `init:` expressions.
        for key, expr in (panel.get("init") or {}).items():
            store.set_panel(self.PANEL, key, we.evaluate_in(store, expr))
        return panel, store


class TestShippedMagicWand(_Shipped):
    PANEL = "magic_wand_panel_content"

    def test_the_hydrated_panel_matches_its_globals(self, workspace_path):
        panel, store = self._setup(workspace_path)
        assert store.get_panel(self.PANEL, "fill_tolerance") == \
            store.get("magic_wand_fill_tolerance")
        assert store.get_panel(self.PANEL, "fill_color") is True

    def test_arm_a_a_tolerance_commit_reaches_panel_and_tool(self, workspace_path):
        panel, store = self._setup(workspace_path)
        w = find_element_by_id(panel, "mwp_fill_tolerance")
        r = we.commit(w, "40", store, panel=panel)
        assert r == we.EventResult("committed", value=40.0,
                                   bind_written=True, behaviors_run=1)
        assert store.get_panel(self.PANEL, "fill_tolerance") == 40.0
        assert store.get("magic_wand_fill_tolerance") == 40.0

    def test_arm_a_the_declared_bound_clamps(self, workspace_path):
        panel, store = self._setup(workspace_path)
        w = find_element_by_id(panel, "mwp_fill_tolerance")
        assert we.commit(w, "900", store, panel=panel).value == 255.0
        assert store.get("magic_wand_fill_tolerance") == 255.0

    def test_arms_b_and_c_refusals_move_nothing(self, workspace_path):
        panel, store = self._setup(workspace_path)
        before = (store.get_panel_state(self.PANEL), store.get_all())
        w = find_element_by_id(panel, "mwp_fill_tolerance")
        assert we.commit(w, None, store, panel=panel).reason == we.MISSING_VALUE
        assert we.commit(w, "abc", store, panel=panel).reason == we.BAD_VALUE
        assert (store.get_panel_state(self.PANEL), store.get_all()) == before

    def test_a_disabled_tolerance_refuses(self, workspace_path):
        panel, store = self._setup(workspace_path)
        we.press(find_element_by_id(panel, "mwp_fill_color"), store, panel=panel)
        w = find_element_by_id(panel, "mwp_fill_tolerance")
        assert we.commit(w, "40", store, panel=panel).reason == we.DISABLED
        assert store.get("magic_wand_fill_tolerance") != 40.0

    def test_arm_e_a_toggle_press_flips_panel_and_tool_once(self, workspace_path):
        # The five toggles flip their own field. A bind write before the
        # flip would flip it straight back, which is why a declared
        # behavior REPLACES the bind write for boolean kinds.
        panel, store = self._setup(workspace_path)
        toggles = [n for n in ("mwp_fill_color", "mwp_stroke_color",
                               "mwp_stroke_weight", "mwp_opacity",
                               "mwp_blending_mode")]
        assert len(toggles) == 5
        for wid in toggles:
            w = find_element_by_id(panel, wid)
            key = w["bind"]["checked"].split(".", 1)[1]
            before = store.get_panel(self.PANEL, key)
            r = we.press(w, store, panel=panel)
            assert r == we.EventResult("committed", value=not before,
                                       bind_written=False, behaviors_run=1), wid
            assert store.get_panel(self.PANEL, key) is (not before), wid
            assert store.get("magic_wand_" + key) is (not before), wid


class TestShippedStroke(_Shipped):
    PANEL = "stroke_panel_content"

    def _link(self, store, on):
        store.set_panel(self.PANEL, "link_arrowhead_scale", on)

    def test_arm_d_the_order_arm_moves_the_other_scale_to_the_new_value(
            self, workspace_path):
        # The ONE clause where bind-first and bind-last disagree: the mirror
        # copies panel.start_arrowhead_scale onto the end scale, so it copies
        # the NEW value only if the bind write already happened.
        panel, store = self._setup(workspace_path)
        self._link(store, True)
        start = store.get_panel(self.PANEL, "start_arrowhead_scale")
        assert start != 200, "the arm needs a start value that is not the edit"
        w = find_element_by_id(panel, "stk_start_arrowhead_scale")
        r = we.commit(w, "200", store, panel=panel)
        assert r == we.EventResult("committed", value=200.0,
                                   bind_written=True, behaviors_run=1)
        assert store.get_panel(self.PANEL, "end_arrowhead_scale") == 200.0
        assert store.get("stroke_end_arrowhead_scale") == 200.0

    def test_unlinked_the_other_scale_stays(self, workspace_path):
        panel, store = self._setup(workspace_path)
        self._link(store, False)
        end = store.get_panel(self.PANEL, "end_arrowhead_scale")
        w = find_element_by_id(panel, "stk_start_arrowhead_scale")
        we.commit(w, "200", store, panel=panel)
        assert store.get_panel(self.PANEL, "start_arrowhead_scale") == 200.0
        assert store.get_panel(self.PANEL, "end_arrowhead_scale") == end

    def test_the_edited_scale_reaches_its_global(self, workspace_path):
        panel, store = self._setup(workspace_path)
        self._link(store, False)
        w = find_element_by_id(panel, "stk_start_arrowhead_scale")
        we.commit(w, "200", store, panel=panel)
        assert store.get("stroke_start_arrowhead_scale") == 200.0

    def test_a_weight_commit_reaches_the_global_that_drives_the_apply(self, workspace_path):
        panel, store = self._setup(workspace_path)
        w = find_element_by_id(panel, "stk_weight")
        assert panel["init"]["weight"] == "state.stroke_width"
        we.commit(w, "3 in", store, panel=panel)
        assert store.get_panel(self.PANEL, "weight") == 216.0
        assert store.get("stroke_width") == 216.0

    def test_the_dashed_checkbox_flips_once(self, workspace_path):
        panel, store = self._setup(workspace_path)
        w = find_element_by_id(panel, "stk_dashed")
        assert w["type"] == "checkbox"
        before = store.get_panel(self.PANEL, "dashed")
        r = we.press(w, store, panel=panel)
        assert r.bind_written is False and r.behaviors_run == 1
        assert store.get_panel(self.PANEL, "dashed") is (not before)
