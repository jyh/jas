#!/usr/bin/env python3
"""Generate the stops-kind gesture corpus: test_fixtures/widget_events/stops_gestures.json.

Each case is a SEQUENCE of slider gestures (WIDGET_EVENTS.md §The stops
kind) on the SHIPPED `grad_slider` widget, run by the reference
(`widget_event.gesture`) over one store. After every step the case records
what the step did and the panel's stops, selection and press snapshot, so a
consumer is held to whole gestures (a press, its drags, its release), not
to single calls. Stops and selection start from each case's `setup`.

Consumers: the reference (workspace_interpreter/tests/test_stops_gesture_corpus.py,
which also checks this file is fresh), the engine (jas_dioxus
`panel_behavior::stops_step`, cross_language_test.rs) and Swift
(`WidgetEvent.gesture`, GradientStopCorpusTests.swift).

Regenerate: python scripts/gen_stops_gesture_corpus.py
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, ROOT.as_posix())

from workspace_interpreter import widget_event as we  # noqa: E402
from workspace_interpreter.loader import find_element_by_id  # noqa: E402
from workspace_interpreter.state_store import StateStore  # noqa: E402

BUNDLE = ROOT / "workspace" / "workspace.json"
OUT = ROOT / "test_fixtures" / "widget_events" / "stops_gestures.json"
PANEL = "gradient_panel_content"
WIDGET = "grad_slider"


def S(color, location, mid=40, opacity=100):
    return {"color": color, "opacity": opacity, "location": location,
            "midpoint_to_next": mid}


R, G, B = "#ff0000", "#00ff00", "#0000ff"
THREE = [S(R, 0), S(G, 50), S(B, 100)]
TWO = [S(R, 0), S(B, 100)]

# (name, setup {stops, stop, midpoint}, [(gesture, params), ...])
SEED = [
    ("drag_across_and_back_restores_the_midpoints", {"stops": THREE},
     [("press", {"index": 0, "location": 0}), ("drag", {"location": 70, "dy": 0}),
      ("drag", {"location": 10, "dy": 0}), ("release", {"location": 10, "dy": 0})]),
    ("drag_off_the_bar_and_back_keeps_the_stop", {"stops": THREE},
     [("press", {"index": 1, "location": 50}), ("drag", {"location": 50, "dy": 40}),
      ("drag", {"location": 55, "dy": 3}), ("release", {"location": 55, "dy": 3})]),
    ("release_off_the_bar_deletes", {"stops": THREE},
     [("press", {"index": 1, "location": 50}), ("release", {"location": 60, "dy": -25})]),
    ("release_off_the_bar_at_the_floor_moves", {"stops": TWO},
     [("press", {"index": 1, "location": 100}), ("release", {"location": 60, "dy": 40})]),
    ("a_click_on_a_stop_selects_it_and_commits_its_own_place", {"stops": THREE, "midpoint": 0},
     [("press", {"index": 2, "location": 100}), ("release", {"location": 100, "dy": 0})]),
    ("midpoint_press_drag_release", {"stops": THREE, "stop": 2},
     [("press_midpoint", {"pair": 1, "location": 70}), ("drag_midpoint", {"location": 60}),
      ("release_midpoint", {"location": 75})]),
    ("add_between_two_stops", {"stops": [S(R, 0, 50), S(B, 100, 50, opacity=0)], "midpoint": 0},
     [("add", {"location": 25})]),
    ("keys_on_a_stop", {"stops": THREE, "stop": 1},
     [("key", {"key": "Right", "shift": False}), ("key", {"key": "Left", "shift": True}),
      ("key", {"key": "End", "shift": False}), ("key", {"key": "Home", "shift": False}),
      ("key", {"key": "Delete", "shift": False})]),
    ("keys_on_a_midpoint", {"stops": THREE, "midpoint": 0},
     [("key", {"key": "Right", "shift": True}), ("key", {"key": "End", "shift": False}),
      ("key", {"key": "Delete", "shift": False})]),
    ("a_drag_with_no_press_is_refused", {"stops": THREE},
     [("drag", {"location": 30, "dy": 0}), ("release", {"location": 30, "dy": 0})]),
    ("a_midpoint_press_does_not_feed_a_stop_release", {"stops": THREE},
     [("press_midpoint", {"pair": 0, "location": 20}), ("release", {"location": 30, "dy": 0})]),
    ("refusals_by_the_law", {"stops": TWO, "stop": 0},
     [("add", {"location": 150}), ("press", {"index": 2, "location": 0}), ("press_midpoint", {"pair": 1, "location": 0}),
      ("key", {"key": "Delete", "shift": False})]),
    ("inert_keys", {"stops": THREE},
     [("key", {"key": "Right", "shift": False}), ("press", {"index": 1, "location": 50}),
      ("release", {"location": 50, "dy": 0}), ("key", {"key": "q", "shift": False})]),
    ("an_unknown_gesture", {"stops": THREE}, [("wiggle", {})]),
    # The grab: a press carries the pointer's location, and a drag moves the
    # marker by how far the pointer moved, never to the pointer.
    ("a_click_off_a_stops_centre_moves_nothing", {"stops": THREE},
     [("press", {"index": 1, "location": 51.5}), ("release", {"location": 51.5, "dy": 0})]),
    ("a_drag_keeps_the_grab_offset", {"stops": THREE},
     [("press", {"index": 1, "location": 52}), ("drag", {"location": 62, "dy": 0}),
      ("release", {"location": 72, "dy": 0})]),
    ("a_midpoint_drag_keeps_the_grab_offset", {"stops": THREE},
     [("press_midpoint", {"pair": 0, "location": 22}), ("drag_midpoint", {"location": 32}),
      ("release_midpoint", {"location": 32})]),
    ("a_press_without_a_location_is_refused", {"stops": THREE, "stop": 2},
     [("press", {"index": 1}), ("press_midpoint", {"pair": 0}),
      ("press", {"index": 1, "location": True}), ("release", {"location": 50, "dy": 0})]),
]


def _store(setup: dict) -> StateStore:
    store = StateStore({"gradient_stops": None})
    store.init_panel(PANEL, {"stops": [dict(s) for s in setup["stops"]],
                             "selected_stop_index": setup.get("stop", -1),
                             "selected_midpoint_index": setup.get("midpoint", -1)})
    store.set_active_panel(PANEL)
    return store


def _case(widget: dict, name: str, setup: dict, steps: list) -> dict:
    store = _store(setup)
    out = []
    for gesture, params in steps:
        store.set("gradient_stops", None)
        r = we.gesture(widget, gesture, params, store, panel=None)
        out.append({
            "gesture": gesture,
            "params": params,
            "expected": {
                "outcome": r.outcome,
                "reason": r.reason,
                "behaviors_run": r.behaviors_run,
                "committed": store.get("gradient_stops"),
                "stops": store.get_panel(PANEL, "stops"),
                "stop": store.get_panel(PANEL, "selected_stop_index"),
                "midpoint": store.get_panel(PANEL, "selected_midpoint_index"),
                "pressed": store.get_panel(PANEL, "stops" + we.PRESS_SUFFIX) is not None,
            },
        })
    return {"name": name, "setup": setup, "steps": out}


def build() -> dict:
    bundle = json.loads(BUNDLE.read_text(encoding="utf-8"))
    widget = find_element_by_id(bundle["panels"][PANEL], WIDGET)
    if widget is None:
        raise SystemExit(f"no widget {WIDGET!r} in {PANEL}")
    return {
        "_doc": [line for line in (__doc__ or "").strip().splitlines()],
        "widget": WIDGET,
        "cases": [_case(widget, *seed) for seed in SEED],
    }


def render(corpus: dict) -> str:
    return json.dumps(corpus, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    corpus = build()
    with OUT.open("w", encoding="utf-8", newline="") as f:
        f.write(render(corpus))
    steps = sum(len(c["steps"]) for c in corpus["cases"])
    print(f"wrote {len(corpus['cases'])} cases, {steps} steps -> "
          f"{OUT.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
