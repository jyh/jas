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
OPTION_ROWS = os.path.join(
    REPO_ROOT, "test_fixtures", "algorithms", "option_rows.json")


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
    def test_the_eighteen_kinds_and_nothing_else(self):
        families = [we.INPUT_KINDS, we.BOOLEAN_KINDS, we.ITEM_KINDS,
                    we.CHECK_KINDS, we.OPTION_KINDS, we.CLICK_KINDS, we.STOPS_KINDS]
        assert set(we.ALLOWED_EVENTS) == set().union(*families)
        assert len(we.INPUT_KINDS) == 10 and len(we.BOOLEAN_KINDS) == 2
        assert we.ITEM_KINDS == {"dropdown"}
        assert we.CHECK_KINDS == {"radio"} and we.OPTION_KINDS == {"radio_group"}
        assert we.CLICK_KINDS == {"button", "icon_button"}
        assert we.STOPS_KINDS == {"gradient_slider"}
        assert sum(len(f) for f in families) == len(set().union(*families)) == 18, \
            "the families are disjoint"

    def test_a_button_clicks_and_names_its_two_pointer_events(self):
        for kind in we.CLICK_KINDS:
            assert we.ALLOWED_EVENTS[kind] == ("click", "mouse_down", "mouse_up"), kind

    def test_a_radio_checks_on_click_or_change_and_a_group_on_toggle(self):
        assert we.ALLOWED_EVENTS["radio"] == ("click", "change")
        assert we.ALLOWED_EVENTS["radio_group"] == ("toggle",)

    def test_a_dropdown_picks_on_toggle_or_alt_toggle(self):
        assert we.ALLOWED_EVENTS["dropdown"] == ("toggle", "alt_toggle")

    def test_event_roots_are_the_store_context_plus_event(self):
        # Derived from the store, so a namespace added to eval_context
        # reaches the lint's allowed roots only through this failing.
        store = StateStore()
        store.init_dialog("d", {"k": 1}, params={"p": 1})
        assert set(store.eval_context({"event": {}})) == we.EVENT_ROOTS

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

    def test_reference_point_widget_takes_one_of_its_nine_anchors(self):
        # The KIND owns its vocabulary (WIDGET_EVENTS.md, Parsing): the nine
        # anchors of a 3x3 grid, row by row. No YAML declares them.
        w = {"type": "reference_point_widget", "bind": {"value": "panel.rp"}}
        assert we.REFERENCE_POINT_ANCHORS == (
            "top_left", "top_center", "top_right", "middle_left", "center",
            "middle_right", "bottom_left", "bottom_center", "bottom_right")
        for a in we.REFERENCE_POINT_ANCHORS:
            assert we.parse_commit(w, a) == (True, a)
        for t in ("", "Center", "middle_center", " center"):
            assert we.parse_commit(w, t) == (False, None), t

    def test_the_nine_anchors_are_the_shipped_preference_enum(self):
        # Derived, never typed: the Artboards panel's `reference_point` state
        # is an enum of exactly these, in this order. (Swift's grid wrote
        # `top`/`left`/`right`/`bottom` until 2026-10-15, values no enum
        # member and no `anchor_offset_*` case carries.)
        bundle = load_workspace(os.path.join(REPO_ROOT, "workspace"))
        enum = bundle["panels"]["artboards_panel_content"]["state"]["reference_point"]["values"]
        assert tuple(enum) == we.REFERENCE_POINT_ANCHORS

    def test_icon_button_group_is_a_select(self):
        # Artboard Options' orientation: options carry an `icon` and a
        # `value`, and no label. A commit is the option's value text.
        w = {"type": "icon_button_group", "options": [
            {"icon": "orientation_portrait", "value": "portrait"},
            {"icon": "orientation_landscape", "value": "landscape"}]}
        assert we.parse_commit(w, "landscape") == (True, "landscape")
        assert we.parse_commit(w, "square") == (False, None)

    def test_icon_select_is_a_select(self):
        w = {"type": "icon_select", "options": [
            {"value": "", "glyph": "-", "label": "None"},
            {"value": "bullet-disc", "glyph": "*", "label": "Disc"},
        ]}
        assert we.parse_commit(w, "") == (True, "")
        assert we.parse_commit(w, "bullet-disc") == (True, "bullet-disc")
        assert we.parse_commit(w, "bullet-square") == (False, None)

    def test_the_shared_option_rows_corpus(self):
        # SCHEMA.md `options`: a bare `separator` is a DIVIDER, never a value.
        # The corpus was authored from that text, because the reference it
        # now gates accepted the text `separator` as a commit.
        with open(OPTION_ROWS, encoding="utf-8") as f:
            vectors = json.load(f)["vectors"]
        assert len(vectors) >= 8, "the shared corpus must not be empty"
        rows_seen = commits_seen = dividers_seen = 0
        for v in vectors:
            assert we.option_rows(v["options"]) == v["rows"], v["name"]
            rows_seen += len(v["rows"])
            dividers_seen += sum(1 for r in v["rows"] if r["kind"] == "separator")
            w = {"type": "select", "options": v["options"]}
            for c in v["commits"]:
                got = we.parse_commit(w, c["text"])
                assert got == (c["accepted"], c["value"]), (v["name"], c["text"], got)
                # A committed number keeps its declared type (int stays int).
                if c["accepted"]:
                    assert type(got[1]) is type(c["value"]), (v["name"], c["text"])
                commits_seen += 1
        # Floors on each population, and on the one the corpus exists for.
        assert rows_seen > 20 and commits_seen > 10 and dividers_seen >= 3

    def test_computed_options_have_no_rows(self):
        # An expression is not a literal list: its values are what it
        # yields, so there are no declared rows to read.
        assert we.option_rows("state.font_families") is None

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
        r = we.commit({"type": "radio_group", "bind": {"value": "panel.n"}}, "3", store, panel=None)
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


class TestShippedGradient(_Shipped):
    # The four value widgets write `gradient_*`, the render keys the apply
    # builds a gradient from. A render key written null is read back as its
    # default, so each arm asserts the key holds the edit, not merely that a
    # behavior ran.
    PANEL = "gradient_panel_content"

    @pytest.mark.parametrize("wid, text, key, expected", [
        ("grad_angle_combo", "45", "angle", 45.0),
        ("grad_aspect_combo", "150", "aspect_ratio", 150.0),
        ("grad_method_dropdown", "smooth", "method", "smooth"),
    ])
    def test_a_commit_reaches_the_panel_and_its_render_key(
            self, workspace_path, wid, text, key, expected):
        panel, store = self._setup(workspace_path)
        assert store.get_panel(self.PANEL, key) != expected, \
            "the arm needs a starting value that is not the edit"
        w = find_element_by_id(panel, wid)
        r = we.commit(w, text, store, panel=panel)
        assert r == we.EventResult("committed", value=expected,
                                   bind_written=True, behaviors_run=1)
        assert store.get_panel(self.PANEL, key) == expected
        assert store.get("gradient_" + key) == expected

    def test_the_dither_checkbox_flips_its_field_and_its_render_key(
            self, workspace_path):
        # A declared `change` owns the press, so the behavior is the only
        # thing that can flip the field.
        panel, store = self._setup(workspace_path)
        w = find_element_by_id(panel, "grad_dither_checkbox")
        before = store.get_panel(self.PANEL, "dither")
        assert before is False
        for expected in (True, False):
            r = we.press(w, store, panel=panel)
            assert r == we.EventResult("committed", value=expected,
                                       bind_written=False, behaviors_run=1)
            assert store.get_panel(self.PANEL, "dither") is expected
            assert store.get("gradient_dither") is expected


# ── Picking a dropdown item ────────────────────────────────────
#
# `dropdown` was outside the contract until the engine door needed the
# Layers type filter: its behaviors read `item.value`, and nothing bound
# `item`, so the door's `list_toggle` would have written null.


def _dropdown(**extra):
    w = {
        "type": "dropdown", "id": "dd",
        "items": [
            {"label": "All", "value": "__all__", "type": "action", "action": "act_all"},
            "separator",
            {"label": "A", "value": "a", "type": "toggle"},
            {"label": "B", "value": "b", "type": "toggle"},
        ],
        "behavior": [
            {"event": "toggle",
             "effects": [{"set": {"picked": "item.value"}}, {"set": {"ev": "event.value"}}]},
            {"event": "alt_toggle", "effects": [{"set": {"alt_picked": "item.label"}}]},
        ],
    }
    w.update(extra)
    return w


_ACTIONS = {"act_all": {"effects": [{"set": {"all_ran": "true"}}]}}


# ── Checking a radio, picking a radio option ───────────────────


class TestCheckSynthetic:
    PID = "probe_panel_content"

    def _radio(self, **extra):
        return {"type": "radio", "bind": {"checked": "dialog.axis == 'v'"},
                "on_check": [{"set": {"dialog.axis": "'v'"}}], **extra}

    def _store(self, axis):
        store = StateStore()
        store.init_dialog("d", {"axis": axis, "n": 0})
        return store

    def test_on_check_is_the_check_and_the_comparison_is_not_written(self):
        store = self._store("h")
        r = we.check(self._radio(), store, panel=None)
        assert r == we.EventResult("committed", value=True, behaviors_run=1)
        assert store.get_dialog("axis") == "v"

    def test_a_checked_radio_is_inert_and_never_unchecks(self):
        store = self._store("v")
        w = self._radio(on_check=[{"set": {"dialog.n": "dialog.n + 1"}}])
        assert we.check(w, store, panel=None) == we.EventResult("inert", value=True)
        assert store.get_dialog("n") == 0, "on_check did not run"

    def test_a_disabled_radio_moves_nothing(self):
        store = self._store("h")
        w = self._radio(bind={"checked": "dialog.axis == 'v'", "disabled": "true"})
        assert we.check(w, store, panel=None) == we.EventResult("refused", reason=we.DISABLED)
        assert store.get_dialog("axis") == "h"

    def test_no_on_check_writes_true_to_a_writable_bind(self):
        store = _panel_store(self.PID, {"on": False})
        r = we.check({"type": "radio", "bind": {"checked": "panel.on"}}, store, panel=None)
        assert r == we.EventResult("committed", value=True, bind_written=True)
        assert store.get_panel(self.PID, "on") is True

    def test_no_on_check_and_no_writable_bind_is_inert(self):
        store = self._store("h")
        r = we.check({"type": "radio", "bind": {"checked": "dialog.axis == 'v'"}}, store, panel=None)
        assert r == we.EventResult("inert", value=True)
        assert store.get_dialog("axis") == "h"

    def test_declared_press_behaviors_run_after_on_check(self):
        store = self._store("h")
        w = self._radio(behavior=[
            {"event": "click", "effects": [{"set": {"dialog.n": "dialog.axis == 'v'"}}]},
            {"event": "alt_toggle", "effects": [{"set": {"dialog.n": 99}}]}])
        r = we.check(w, store, panel=None)
        assert r.outcome == "committed" and r.behaviors_run == 2
        assert store.get_dialog("n") is True, "the behavior read the axis on_check wrote"

    def test_check_refuses_every_other_kind(self):
        store = _panel_store(self.PID, {"on": False})
        for kind in ("toggle", "checkbox", "radio_group", "dropdown", "number_input"):
            r = we.check({"type": kind, "bind": {"checked": "panel.on"}}, store, panel=None)
            assert r == we.EventResult("refused", reason=we.WRONG_KIND), kind
        assert store.get_panel(self.PID, "on") is False

    def test_press_refuses_a_radio(self):
        store = self._store("h")
        assert we.press(self._radio(), store, panel=None).reason == we.WRONG_KIND


class TestChooseSynthetic:
    def _group(self, **extra):
        return {"type": "radio_group", "bind": "dialog.channel",
                "options": [{"id": "h", "label": ""}, {"id": "s", "label": ""}], **extra}

    def _store(self, channel="h"):
        store = StateStore()
        store.init_dialog("d", {"channel": channel, "n": 0})
        return store

    def test_a_pick_writes_the_options_id(self):
        store = self._store("h")
        r = we.choose(self._group(), "s", "toggle", store, panel=None)
        assert r == we.EventResult("committed", value="s", bind_written=True)
        assert store.get_dialog("channel") == "s"

    def test_the_checked_option_is_inert(self):
        store = self._store("h")
        assert we.choose(self._group(), "h", "toggle", store, panel=None) == \
            we.EventResult("inert", value="h")

    def test_the_comparison_is_as_text(self):
        # 2.0, not 2. Here the evaluator already reads a whole 2.0 as the
        # int 2, so the mutant `str(raw)` SURVIVES in this port (equivalent,
        # recorded), and in Rust too (f64's Display writes 2.0 as "2"). In
        # Swift, whose Double prints "2.0", the rule is load-bearing: its
        # mutant is killed by WidgetEventRadioTests (2026-10-15).
        store = self._store(2.0)
        g = self._group(options=[{"id": "2"}, {"id": "3"}])
        assert we.choose(g, "2", "toggle", store, panel=None).outcome == "inert"
        assert we.choose(g, "3", "toggle", store, panel=None).outcome == "committed"
        assert store.get_dialog("channel") == "3", "the id is written as a string"

    def test_refusals_move_nothing(self):
        cases = [("s", "change", we.WRONG_EVENT), (None, "toggle", we.MISSING_VALUE),
                 ("x", "toggle", we.BAD_VALUE)]
        for value, event, reason in cases:
            store = self._store("h")
            r = we.choose(self._group(), value, event, store, panel=None)
            assert r == we.EventResult("refused", reason=reason), (value, event)
            assert store.get_dialog("channel") == "h"
        # A bare-string bind cannot declare `disabled`; the dict form can.
        for disabled, outcome in (("true", "refused"), ("false", "committed")):
            store = self._store("h")
            g = self._group(bind={"value": "dialog.channel", "disabled": disabled})
            assert we.choose(g, "s", "toggle", store, panel=None).outcome == outcome, disabled

    def test_toggle_behaviors_run_after_the_write(self):
        store = self._store("h")
        g = self._group(behavior=[{"event": "toggle", "effects": [{"set": {"dialog.n": "event.value"}}]}])
        r = we.choose(g, "s", "toggle", store, panel=None)
        assert r == we.EventResult("committed", value="s", bind_written=True, behaviors_run=1)
        assert store.get_dialog("n") == "s"

    def test_choose_refuses_every_other_kind(self):
        store = self._store("h")
        for kind in ("radio", "dropdown", "select"):
            r = we.choose({**self._group(), "type": kind}, "s", "toggle", store, panel=None)
            assert r == we.EventResult("refused", reason=we.WRONG_KIND), kind


class TestShippedShearAxis:
    """The shipped Shear Options radios, from the compiled bundle: three
    siblings share `dialog.axis` through their own comparisons."""

    def test_checking_vertical_unchecks_horizontal(self):
        from workspace_interpreter.loader import load_workspace
        bundle = load_workspace(os.path.join(REPO_ROOT, "workspace"))
        dlg = bundle["dialogs"]["shear_options"]
        horizontal = find_element_by_id(dlg, "sho_axis_horizontal")
        vertical = find_element_by_id(dlg, "sho_axis_vertical")
        store = StateStore()
        store.init_dialog("shear_options", {"axis": "horizontal"})
        checked = lambda w: we.evaluate_in(store, w["bind"]["checked"])
        assert checked(horizontal) and not checked(vertical), "the control"
        assert we.check(vertical, store, panel=None).outcome == "committed"
        assert store.get_dialog("axis") == "vertical"
        assert checked(vertical) and not checked(horizontal)
        assert we.check(vertical, store, panel=None).outcome == "inert"


class TestShippedArtboardOrientation:
    """Artboard Options' orientation group (`ao_orientation`): its `change`
    runs `toggle_artboard_orientation`, which SWAPS width and height. A commit
    of the orientation already shown must not swap it, so the behavior is
    guarded by its own condition (the web renderer ran it on every click)."""

    def _run(self, width, height, text):
        bundle = load_workspace(os.path.join(REPO_ROOT, "workspace"))
        w = find_element_by_id(bundle["dialogs"]["artboard_options"], "ao_orientation")
        store = StateStore()
        store.init_dialog("artboard_options", {"width": width, "height": height})
        actions = {"toggle_artboard_orientation": {"effects": [{"set": {"toggled": "true"}}]}}
        r = we.commit(w, text, store, panel=None, actions=actions)
        return r, store.get("toggled")

    def test_the_other_orientation_toggles(self):
        r, toggled = self._run(100, 200, "landscape")
        assert r.outcome == "committed" and r.behaviors_run == 1 and toggled is True

    def test_the_shown_orientation_changes_nothing(self):
        r, toggled = self._run(100, 200, "portrait")
        assert r.outcome == "inert" and r.behaviors_run == 0 and toggled is None


class TestClickSynthetic:
    """A click on a CLICK kind (`button`, `icon_button`): its declared `click`
    behaviors, else its node-level `action` with `params`."""

    ACTIONS = {"record": {"effects": [
        {"set": {"got_n": "param.n", "got_copy": "param.copy",
                 "got_target": "param.target", "got_alt": "event.alt"}}]}}

    def _store(self, n=7):
        store = StateStore()
        store.init_dialog("d", {"n": n, "hits": 0})
        return store

    def _button(self, **extra):
        return {"type": "button", "action": "record",
                "params": {"n": "dialog.n", "copy": False, "target": "artboard"},
                **extra}

    def test_a_node_action_dispatches_with_its_params_resolved(self):
        store = self._store()
        r = we.click(self._button(), "click", store, panel=None, actions=self.ACTIONS)
        assert r == we.EventResult("committed", behaviors_run=1)
        assert store.get("got_n") == 7, "a string param is an expression"
        assert store.get("got_copy") is False, "a YAML literal is that value"
        assert store.get("got_target") == "artboard", "a bare null identifier is its name"

    def test_an_icon_button_is_a_click_kind_too(self):
        store = self._store()
        w = {"type": "icon_button", "action": "record", "params": {"n": "dialog.n"}}
        assert we.click(w, "click", store, panel=None,
                        actions=self.ACTIONS).outcome == "committed"
        assert store.get("got_n") == 7

    def test_declared_click_behaviors_are_the_click_and_the_action_does_not_run(self):
        store = self._store()
        w = self._button(behavior=[
            {"event": "click", "effects": [{"set": {"dialog.hits": "dialog.hits + 1"}}]},
            {"event": "click", "effects": [{"set": {"dialog.hits": "dialog.hits + 10"}}]}])
        r = we.click(w, "click", store, panel=None, actions=self.ACTIONS)
        assert r == we.EventResult("committed", behaviors_run=2)
        assert store.get_dialog("hits") == 11, "both ran, in order"
        assert store.get("got_n") is None, "the node action did not run"

    def test_a_click_behavior_skipped_by_its_condition_still_owns_the_click(self):
        store = self._store()
        w = self._button(behavior=[
            {"event": "click", "condition": "event.alt",
             "effects": [{"set": {"dialog.hits": 1}}]}])
        r = we.click(w, "click", store, panel=None, actions=self.ACTIONS)
        assert r == we.EventResult("inert")
        assert store.get_dialog("hits") == 0 and store.get("got_n") is None

    def test_event_carries_the_modifiers_and_no_value(self):
        store = self._store()
        w = self._button(behavior=[
            {"event": "click", "condition": "event.alt",
             "effects": [{"set": {"dialog.hits": "event.shift"}}]}])
        r = we.click(w, "click", store, panel=None,
                     modifiers={"alt": True, "shift": True}, actions=self.ACTIONS)
        assert r.outcome == "committed" and store.get_dialog("hits") is True
        assert we.click(self._button(), "click", self._store(), panel=None,
                        modifiers={"alt": True}).value is None

    def test_absent_modifiers_read_false_not_null(self):
        store = self._store()
        we.click(self._button(), "click", store, panel=None, actions=self.ACTIONS)
        assert store.get("got_alt") is False

    def test_a_node_action_sees_the_modifiers(self):
        store = self._store()
        we.click(self._button(), "click", store, panel=None,
                 modifiers={"alt": True}, actions=self.ACTIONS)
        assert store.get("got_alt") is True

    def test_mouse_down_behaviors_are_not_a_click(self):
        store = self._store()
        w = {"type": "icon_button", "behavior": [
            {"event": "mouse_down", "effects": [{"set": {"dialog.hits": 1}}]}]}
        assert we.click(w, "click", store, panel=None) == we.EventResult("inert")
        assert store.get_dialog("hits") == 0

    def test_nothing_declared_is_inert(self):
        assert we.click({"type": "button", "label": "x"}, "click", self._store(),
                        panel=None) == we.EventResult("inert")

    def test_a_disabled_button_runs_nothing(self):
        store = self._store()
        w = self._button(bind={"disabled": "dialog.n > 5"})
        r = we.click(w, "click", store, panel=None, actions=self.ACTIONS)
        assert r == we.EventResult("refused", reason=we.DISABLED)
        assert store.get("got_n") is None

    def test_only_click_is_a_click(self):
        store = self._store()
        for event in ("mouse_down", "mouse_up", "change", "commit", "toggle"):
            r = we.click(self._button(), event, store, panel=None, actions=self.ACTIONS)
            assert r == we.EventResult("refused", reason=we.WRONG_EVENT), event
        assert store.get("got_n") is None

    def test_click_refuses_every_other_kind(self):
        store = self._store()
        for kind in ("toggle", "checkbox", "radio", "dropdown", "number_input", "text"):
            w = {"type": kind, "action": "record", "params": {"n": "dialog.n"}}
            r = we.click(w, "click", store, panel=None, actions=self.ACTIONS)
            assert r == we.EventResult("refused", reason=we.WRONG_KIND), kind
        assert store.get("got_n") is None


def _button_labelled(node, label):
    """The one button in ``node`` whose label is ``label`` (dialog buttons
    carry no id)."""
    found = []

    def walk(n):
        if isinstance(n, dict):
            if n.get("type") == "button" and n.get("label") == label:
                found.append(n)
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(node)
    assert len(found) == 1, (label, len(found))
    return found[0]


class TestShippedRotateButtons:
    """Rotate Options' Copy and OK both run `rotate_options_confirm`; only the
    literal `copy:` differs, so a port that reads a YAML `false` as the text
    "False" (an unknown identifier) copies on OK."""

    def _run(self, label):
        bundle = load_workspace(os.path.join(REPO_ROOT, "workspace"))
        w = _button_labelled(bundle["dialogs"]["rotate_options"], label)
        store = StateStore()
        store.init_dialog("rotate_options", {"angle": 30, "preview": False})
        actions = {"rotate_options_confirm": {"effects": [
            {"set": {"got_angle": "param.angle", "got_copy": "param.copy"}}]}}
        r = we.click(w, "click", store, panel=None, actions=actions)
        return r, store.get("got_angle"), store.get("got_copy")

    def test_ok_does_not_copy(self):
        assert self._run("OK") == (we.EventResult("committed", behaviors_run=1), 30, False)

    def test_copy_copies(self):
        assert self._run("Copy") == (we.EventResult("committed", behaviors_run=1), 30, True)


class TestDialogOnChange:
    """A write to a field of the open dialog runs the dialog's `on_change`
    action, once, in the same event. The transform dialogs' "Preview: the
    canvas re-renders live" is that action (`rotate_options_preview`); until
    2026-10-24 the reference wrote the bind outside any batch, so a typed
    angle previewed only at the NEXT button press, while the engine ran it."""

    ACTIONS = {"seen": {"effects": [{"set": {"fired": "state.fired + 1",
                                              "fired_angle": "dialog.angle"}}]}}

    def _store(self):
        store = StateStore({"fired": 0})
        store.init_dialog("d", {"angle": 0, "on": False})
        store.set_dialog_on_change("seen")
        store.take_dialog_dirty()
        return store

    def test_a_commit_runs_on_change_with_the_new_value(self):
        store = self._store()
        w = {"type": "number_input", "bind": {"value": "dialog.angle"}}
        r = we.commit(w, "30", store, panel=None, actions=self.ACTIONS)
        assert r.outcome == "committed"
        assert (store.get("fired"), store.get("fired_angle")) == (1, 30.0)

    def test_a_press_runs_on_change(self):
        store = self._store()
        w = {"type": "toggle", "bind": {"checked": "dialog.on"}}
        we.press(w, store, panel=None, actions=self.ACTIONS)
        assert store.get_dialog("on") is True
        assert store.get("fired") == 1

    def test_a_behavior_batch_runs_it_once_not_twice(self):
        store = self._store()
        w = {"type": "number_input", "bind": {"value": "dialog.angle"},
             "behavior": [{"event": "commit", "effects": [{"set": {"x": "1"}}]}]}
        we.commit(w, "5", store, panel=None, actions=self.ACTIONS)
        assert store.get("fired") == 1

    def test_a_panel_write_runs_no_dialog_action(self):
        store = self._store()
        store.init_panel("p", {"n": 0})
        store.set_active_panel("p")
        w = {"type": "number_input", "bind": {"value": "panel.n"}}
        we.commit(w, "4", store, panel=None, actions=self.ACTIONS)
        assert store.get("fired") == 0


class TestPickSynthetic:
    def test_a_toggle_item_runs_the_events_behaviors_with_item_bound(self):
        store = StateStore()
        r = we.pick(_dropdown(), "b", "toggle", store, panel=None, actions=_ACTIONS)
        assert r == we.EventResult("committed", value="b", behaviors_run=1)
        assert store.get("picked") == "b"
        assert store.get("ev") == "b", "event.value is the item's value"
        assert store.get("alt_picked") is None, "only the requested event runs"

    def test_alt_toggle_runs_only_its_own_behaviors(self):
        store = StateStore()
        r = we.pick(_dropdown(), "a", "alt_toggle", store, panel=None, actions=_ACTIONS)
        assert r.behaviors_run == 1
        assert store.get("alt_picked") == "A", "the WHOLE item is bound, not only its value"
        assert store.get("picked") is None

    def test_an_action_item_runs_its_own_action_and_no_behavior(self):
        store = StateStore()
        r = we.pick(_dropdown(), "__all__", "toggle", store, panel=None, actions=_ACTIONS)
        assert r == we.EventResult("committed", value="__all__", behaviors_run=0)
        assert store.get("all_ran") is True
        assert store.get("picked") is None

    def test_no_item_named_is_missing_value(self):
        store = StateStore()
        r = we.pick(_dropdown(), None, "toggle", store, panel=None, actions=_ACTIONS)
        assert r == we.EventResult("refused", reason=we.MISSING_VALUE)
        assert store.get("picked") is None

    def test_an_undeclared_item_is_bad_value(self):
        store = StateStore()
        r = we.pick(_dropdown(), "c", "toggle", store, panel=None, actions=_ACTIONS)
        assert r == we.EventResult("refused", reason=we.BAD_VALUE)
        assert store.get("picked") is None

    def test_a_separator_is_not_an_item(self):
        store = StateStore()
        r = we.pick(_dropdown(), "separator", "toggle", store, panel=None, actions=_ACTIONS)
        assert r.reason == we.BAD_VALUE

    def test_an_event_outside_the_table_is_wrong_event(self):
        store = StateStore()
        r = we.pick(_dropdown(), "a", "click", store, panel=None, actions=_ACTIONS)
        assert r == we.EventResult("refused", reason=we.WRONG_EVENT)
        assert store.get("picked") is None

    def test_a_non_dropdown_is_wrong_kind(self):
        store = StateStore()
        r = we.pick({"type": "select", "items": []}, "a", "toggle", store, panel=None)
        assert r.reason == we.WRONG_KIND

    def test_a_disabled_dropdown_refuses(self):
        store = StateStore({"off": True})
        r = we.pick(_dropdown(bind={"disabled": "state.off"}), "a", "toggle", store,
                    panel=None, actions=_ACTIONS)
        assert r.reason == we.DISABLED
        assert store.get("picked") is None

    def test_an_item_with_no_declared_behavior_is_inert(self):
        store = StateStore()
        w = _dropdown(behavior=[])
        assert we.pick(w, "a", "toggle", store, panel=None).outcome == "inert"


class TestShippedLayersFilter(_Shipped):
    PANEL = "layers_panel_content"

    def _run(self, workspace_path, value, event="toggle", initial=None):
        data = load_workspace(workspace_path)
        panel, store = self._setup(workspace_path)
        if initial is not None:
            store.set_panel(self.PANEL, "type_filter", list(initial))
        w = find_element_by_id(panel, "lp_filter_button")
        r = we.pick(w, value, event, store, panel=panel, actions=data["actions"])
        return r, store.get_panel(self.PANEL, "type_filter")

    def test_a_pick_toggles_that_type_into_the_filter(self, workspace_path):
        r, tf = self._run(workspace_path, "path")
        assert r.outcome == "committed"
        assert tf == ["path"], "the TYPE, never null"

    def test_a_second_pick_toggles_it_out(self, workspace_path):
        r, tf = self._run(workspace_path, "path", initial=["path", "text"])
        assert tf == ["text"]

    def test_an_alt_pick_solos_the_type(self, workspace_path):
        r, tf = self._run(workspace_path, "circle", event="alt_toggle", initial=["path", "text"])
        assert tf == ["circle"]

    def test_all_clears_the_filter(self, workspace_path):
        r, tf = self._run(workspace_path, "__all__", initial=["path", "text"])
        assert r.outcome == "committed"
        assert tf == []


# ── slider (WIDGET_EVENTS.md, ruled 2026-10-12: flask's fork A) ──────────────

def _slider(lo=0, hi=255, step=51):
    w = {"type": "slider"}
    for k, v in (("min", lo), ("max", hi), ("step", step)):
        if v is not None:
            w[k] = v
    return w


@pytest.mark.parametrize("text, want", [
    ("130", 153),      # 130/51 = 2.55 -> 3 steps
    ("127", 102),      # 2.49 -> 2 steps
    ("127.5", 153),    # exactly half -> up
    ("255", 255),
    ("300", 255),      # clamped, then on a step
    ("-5", 0),         # clamped below
])
def test_a_slider_commit_clamps_then_snaps_to_its_step(text, want):
    ok, v = we.parse_commit(_slider(), text)
    assert ok and v == want, (text, v)


def test_a_slider_snaps_from_its_min_not_from_zero():
    ok, v = we.parse_commit(_slider(lo=10, hi=100, step=20), "39")
    assert ok and v == 30, v   # 10 + round((39-10)/20 = 1.45 -> 1) * 20


def test_a_snap_never_leaves_the_range():
    # max 100 is not on the 0,30,60,90,120 grid: 99 snaps to 90, never 120.
    ok, v = we.parse_commit(_slider(lo=0, hi=100, step=30), "99")
    assert ok and v == 90, v
    # And the max itself, off the grid, is unreachable, as on an HTML range
    # input: 100 -> 3.33 steps -> 3 -> 90.
    ok, v = we.parse_commit(_slider(lo=0, hi=100, step=30), "100")
    assert ok and v == 90, v


def test_without_a_positive_step_a_slider_is_a_clamped_number():
    for step in (None, 0, -1, True):
        ok, v = we.parse_commit(_slider(lo=0, hi=10, step=step), "7.3")
        assert ok and v == 7.3, (step, v)


def test_a_slider_refuses_text_outside_the_number_grammar():
    for text in ("abc", "", " 5", "1e3"):
        assert we.parse_commit(_slider(), text) == (False, None), text


# ── color_bar (WIDGET_EVENTS.md, fork B2, 2026-10-13) ────────────────────────
# A point normalized to [0,1]²: "u,v", two numbers in the number grammar
# joined by one comma. The colour is color_util.color_bar_rgb(u, v).

@pytest.mark.parametrize("text, want", [
    ("0.25,0.5", [0.25, 0.5]),
    ("0,0", [0.0, 0.0]),
    ("1,1", [1.0, 1.0]),
    ("1.4,-0.2", [1.0, 0.0]),     # each clamped to [0, 1]
    ("-3,7", [0.0, 1.0]),
])
def test_a_color_bar_commit_is_a_clamped_point(text, want):
    ok, v = we.parse_commit({"type": "color_bar"}, text)
    assert ok and v == want, (text, v)


@pytest.mark.parametrize("text", [
    "0.5",            # one coordinate
    "0.5,0.5,0.5",    # three
    "0.5, 0.5",       # a space is outside the grammar
    "a,b",
    ",0.5",
    "0.5,",
    "",
    ".5,.5",          # a leading `.` is outside the number grammar
])
def test_a_color_bar_refuses_anything_but_two_numbers(text):
    assert we.parse_commit({"type": "color_bar"}, text) == (False, None), text


def test_a_color_bar_is_an_input_kind_with_the_sliders_events():
    assert "color_bar" in we.INPUT_KINDS
    assert we.ALLOWED_EVENTS["color_bar"] == we.ALLOWED_EVENTS["slider"] == ("commit", "change")
