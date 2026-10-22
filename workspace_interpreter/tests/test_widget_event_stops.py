"""The STOPS kind (``gradient_slider``) of the widget event contract
(WIDGET_EVENTS.md §The stops kind), driven against the reference StateStore.

A gesture crosses as its raw parameters and the procedure applies the slider
law (``gradient_law``). A drag is computed from the stops snapshotted at the
press, writes the bound stops and selection only, and runs no behaviors; the
gesture's end (release, add, key) runs the ``commit`` behaviors once, with
``event.value`` the new stops.
"""

import pytest

from workspace_interpreter import widget_event as we
from workspace_interpreter.state_store import StateStore

PANEL = "gradient_panel_content"


def S(color, location, mid=40, opacity=100):
    return {"color": color, "opacity": opacity, "location": location,
            "midpoint_to_next": mid}


R, G, B = "#ff0000", "#00ff00", "#0000ff"
THREE = [S(R, 0), S(G, 50), S(B, 100)]

WIDGET = {
    "id": "grad_slider", "type": "gradient_slider",
    "bind": {"stops": "panel.stops",
             "selected_stop_index": "panel.selected_stop_index",
             "selected_midpoint_index": "panel.selected_midpoint_index"},
    "behavior": [{"event": "commit",
                  "effects": [{"set": {"gradient_stops": "event.value"}}]}],
}


def store_with(stops=THREE, stop=-1, midpoint=-1, **extra):
    st = StateStore({"gradient_stops": None})
    st.init_panel(PANEL, {"stops": [dict(s) for s in stops],
                          "selected_stop_index": stop,
                          "selected_midpoint_index": midpoint, **extra})
    st.set_active_panel(PANEL)
    return st


def go(st, name, widget=WIDGET, **params):
    return we.gesture(widget, name, params, st, panel=None)


def panel(st, key):
    return st.get_panel(PANEL, key)


class TestTable:
    def test_the_stops_kind_takes_commit_only(self):
        assert we.STOPS_KINDS == {"gradient_slider"}
        assert we.ALLOWED_EVENTS["gradient_slider"] == ("commit",)

    def test_the_gestures_are_named(self):
        assert we.STOPS_GESTURES == (
            "press", "drag", "release", "press_midpoint", "drag_midpoint",
            "release_midpoint", "add", "key")


class TestStopDrag:
    def test_press_selects_and_writes_nothing_else(self):
        st = store_with(midpoint=0)
        r = go(st, "press", index=1)
        assert r.outcome == "committed" and r.behaviors_run == 0
        assert (panel(st, "selected_stop_index"), panel(st, "selected_midpoint_index")) == (1, -1)
        assert panel(st, "stops") == THREE and st.get("gradient_stops") is None

    def test_a_drag_writes_the_store_and_runs_no_behavior(self):
        st = store_with()
        go(st, "press", index=1)
        r = go(st, "drag", location=30, dy=0)
        assert r.behaviors_run == 0 and st.get("gradient_stops") is None
        assert panel(st, "stops")[1]["location"] == 30

    def test_a_drag_is_computed_from_the_press_not_the_last_preview(self):
        # Across a neighbour (midpoints reset) and back: from the press the
        # midpoints return to 40; applied incrementally they would stay 50.
        st = store_with()
        go(st, "press", index=0)
        go(st, "drag", location=70, dy=0)
        assert panel(st, "selected_stop_index") == 1
        go(st, "drag", location=10, dy=0)
        assert panel(st, "stops") == [S(R, 10), S(G, 50), S(B, 100)]
        assert panel(st, "selected_stop_index") == 0

    def test_off_the_bar_and_back_restores_the_stop(self):
        st = store_with()
        go(st, "press", index=1)
        go(st, "drag", location=50, dy=40)
        assert len(panel(st, "stops")) == 2 and panel(st, "selected_stop_index") == 0
        go(st, "drag", location=55, dy=3)
        assert panel(st, "stops") == [S(R, 0), S(G, 55), S(B, 100)]

    def test_release_commits_once_and_clears_the_snapshot(self):
        st = store_with()
        go(st, "press", index=1)
        go(st, "drag", location=20, dy=0)
        r = go(st, "release", location=25, dy=0)
        want = [S(R, 0), S(G, 25), S(B, 100)]
        assert r.outcome == "committed" and r.behaviors_run == 1 and r.value == want
        assert st.get("gradient_stops") == want and panel(st, "stops") == want
        assert go(st, "release", location=25, dy=0).reason == we.NO_PRESS

    def test_a_release_or_drag_with_no_press_is_refused_by_name(self):
        st = store_with()
        assert go(st, "drag", location=25, dy=0).reason == we.NO_PRESS
        assert go(st, "release", location=25, dy=0).reason == we.NO_PRESS
        assert panel(st, "stops") == THREE

    def test_a_press_on_a_midpoint_does_not_feed_a_stop_release(self):
        st = store_with()
        go(st, "press_midpoint", pair=0)
        assert go(st, "release", location=25, dy=0).reason == we.NO_PRESS


class TestMidpointDrag:
    def test_press_midpoint_selects_it_and_clears_the_stop(self):
        st = store_with(stop=2)
        r = go(st, "press_midpoint", pair=1)
        assert r.outcome == "committed" and r.behaviors_run == 0
        assert (panel(st, "selected_stop_index"), panel(st, "selected_midpoint_index")) == (-1, 1)

    def test_drag_then_release_midpoint(self):
        st = store_with()
        go(st, "press_midpoint", pair=1)
        go(st, "drag_midpoint", location=60)
        assert panel(st, "stops")[1]["midpoint_to_next"] == 20
        assert st.get("gradient_stops") is None
        r = go(st, "release_midpoint", location=75)
        assert r.behaviors_run == 1 and st.get("gradient_stops")[1]["midpoint_to_next"] == 50
        assert go(st, "drag_midpoint", location=60).reason == we.NO_PRESS


class TestAdd:
    def test_add_inserts_selects_and_commits(self):
        st = store_with(stops=[S(R, 0, 50), S(B, 100, 50, opacity=0)], midpoint=0)
        r = go(st, "add", location=25)
        assert r.behaviors_run == 1
        assert panel(st, "stops")[1] == S("#bf0040", 25, 50, opacity=75)
        assert (panel(st, "selected_stop_index"), panel(st, "selected_midpoint_index")) == (1, -1)
        assert st.get("gradient_stops") == panel(st, "stops")

    def test_a_refused_add_writes_nothing(self):
        st = store_with()
        r = go(st, "add", location=150)
        assert (r.outcome, r.reason) == ("refused", we.LAW_REFUSED)
        assert panel(st, "stops") == THREE and st.get("gradient_stops") is None


class TestKeys:
    @pytest.mark.parametrize("key,shift,loc", [
        ("Right", False, 51), ("Left", False, 49), ("Right", True, 60),
        ("Left", True, 40), ("Home", False, 0), ("End", False, 100)])
    def test_a_key_moves_the_selected_stop(self, key, shift, loc):
        st = store_with(stop=1)
        r = go(st, "key", key=key, shift=shift)
        assert r.behaviors_run == 1
        moved = [s for s in panel(st, "stops") if s["color"] == G][0]
        assert moved["location"] == loc

    def test_a_nudge_clamps(self):
        st = store_with(stop=2)
        go(st, "key", key="Right", shift=True)
        assert panel(st, "stops")[2]["location"] == 100

    def test_delete_removes_the_selected_stop(self):
        for key in ("Delete", "Backspace"):
            st = store_with(stop=1)
            go(st, "key", key=key, shift=False)
            assert [s["color"] for s in panel(st, "stops")] == [R, B]
            assert panel(st, "selected_stop_index") == 0

    def test_delete_at_the_floor_is_refused(self):
        st = store_with(stops=[S(R, 0), S(B, 100)], stop=0)
        r = go(st, "key", key="Delete", shift=False)
        assert r.reason == we.LAW_REFUSED and st.get("gradient_stops") is None

    @pytest.mark.parametrize("key,shift,mid", [
        ("Right", False, 41), ("Left", True, 30), ("Home", False, 0), ("End", False, 100)])
    def test_a_key_moves_the_selected_midpoint(self, key, shift, mid):
        st = store_with(midpoint=0)
        go(st, "key", key=key, shift=shift)
        assert panel(st, "stops")[0]["midpoint_to_next"] == mid

    def test_a_midpoint_cannot_be_deleted(self):
        st = store_with(midpoint=0)
        r = go(st, "key", key="Delete", shift=False)
        assert r.outcome == "inert" and panel(st, "stops") == THREE

    def test_a_key_with_nothing_selected_is_inert(self):
        st = store_with()
        assert go(st, "key", key="Right", shift=False).outcome == "inert"

    def test_an_unknown_key_is_inert(self):
        st = store_with(stop=1)
        assert go(st, "key", key="q", shift=False).outcome == "inert"


class TestRefusals:
    def test_a_wrong_kind(self):
        st = store_with()
        assert go(st, "press", widget={**WIDGET, "type": "slider"}, index=1).reason == we.WRONG_KIND

    def test_an_unknown_gesture(self):
        assert go(store_with(), "wiggle").reason == we.WRONG_EVENT

    def test_disabled(self):
        w = {**WIDGET, "bind": {**WIDGET["bind"], "disabled": "true"}}
        st = store_with()
        assert go(st, "add", widget=w, location=25).reason == we.DISABLED
        assert panel(st, "stops") == THREE

    def test_a_bad_index_is_refused_by_the_law(self):
        st = store_with()
        assert go(st, "press", index=7).reason == we.LAW_REFUSED
        assert go(st, "press_midpoint", pair=2).reason == we.LAW_REFUSED
        assert panel(st, "selected_stop_index") == -1

    def test_a_widget_whose_stops_are_not_a_panel_field_is_refused(self):
        w = {**WIDGET, "bind": {**WIDGET["bind"], "stops": "state.stops"}}
        assert go(store_with(), "add", widget=w, location=25).reason == we.NOT_WRITABLE
