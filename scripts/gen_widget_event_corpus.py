#!/usr/bin/env python3
"""Generate the widget event corpus: test_fixtures/widget_events/corpus.json.

Each case names a shipped widget in the compiled bundle, a starting store, and
one event: a commit (the text a person entered, or null for a commit that
carried none) or a press. The expected result is what the reference
(workspace_interpreter/widget_event.py, WIDGET_EVENTS.md) does. The expected
values are PRODUCED by running the reference, never typed.

The starting store, which is how every consumer rebuilds it:
  * global state = the bundle's `state` defaults, then `before.state` on top;
  * the widget's panel scope = `before.panel`, whole;
  * that panel is the active panel.
`before.panel` is written out whole, so a consumer never has to evaluate the
panel's `init:` expressions to reproduce it. The generator derives it by
opening the panel the way the reference does (its `state:` defaults, then each
`init:` expression, then the case's own panel setup).

The expected values:
  * `result` is the EventResult, field for field;
  * `panel` is the panel scope afterwards, whole;
  * `state_changed` holds exactly the global keys whose value changed,
    including the global a panel field is two-way bound to through the
    panel's `init:` (WIDGET_EVENTS.md, "The bound target").
Numbers compare as numbers, not as JSON text. A value a behavior writes has
passed through the expression evaluator, so it can serialize as `40` where
the bind write of the same value serialized as `40.0`.

Every case's behaviors write only to the store. What a port's panel-write
host then does to the document is outside this corpus.

Regenerate after changing widget_event.py, the seed list, or the bundle:

    python -m workspace_interpreter.compile workspace/ workspace/workspace.json
    python scripts/gen_widget_event_corpus.py

workspace_interpreter/tests/test_widget_event_corpus.py fails on a stale file.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, ROOT.as_posix())

from workspace_interpreter import widget_event as we  # noqa: E402
from workspace_interpreter.loader import (  # noqa: E402
    find_element_by_id,
    panel_state_defaults,
    state_defaults,
)
from workspace_interpreter.state_store import StateStore  # noqa: E402

BUNDLE = ROOT / "workspace" / "workspace.json"
OUT = ROOT / "test_fixtures" / "widget_events" / "corpus.json"

MW = "magic_wand_panel_content"
STROKE = "stroke_panel_content"

# (name, panel, widget, setup {"panel": {...}, "state": {...}}, event)
# A setup writes the panel scope and global state before the event, as an
# earlier edit by the person would have.
SEED = [
    # W2b-1 arm (a): a commit with a value reaches the panel and the tool.
    ("magic_wand_tolerance_commit", MW, "mwp_fill_tolerance", {}, {"commit": "40"}),
    ("magic_wand_tolerance_clamped", MW, "mwp_fill_tolerance", {}, {"commit": "900"}),
    ("magic_wand_weight_tolerance_decimal", MW, "mwp_stroke_weight_tolerance", {},
     {"commit": "2.5"}),
    # Arms (b) and (c): refusals move nothing.
    ("magic_wand_tolerance_missing_value", MW, "mwp_fill_tolerance", {}, {"commit": None}),
    ("magic_wand_tolerance_bad_value", MW, "mwp_fill_tolerance", {}, {"commit": "abc"}),
    ("magic_wand_tolerance_exponent_refused", MW, "mwp_fill_tolerance", {},
     {"commit": "1e3"}),
    ("magic_wand_tolerance_disabled", MW, "mwp_fill_tolerance",
     {"panel": {"fill_color": False}, "state": {"magic_wand_fill_color": False}},
     {"commit": "40"}),
    # Arm (e): a declared behavior replaces the bind write, so a flip lands once.
    ("magic_wand_fill_color_press", MW, "mwp_fill_color", {}, {"press": True}),
    ("magic_wand_blending_mode_press", MW, "mwp_blending_mode", {}, {"press": True}),
    # Arm (d): the order arm. Bind-first and bind-last disagree only here.
    ("stroke_start_scale_linked", STROKE, "stk_start_arrowhead_scale",
     {"panel": {"link_arrowhead_scale": True}}, {"commit": "200"}),
    ("stroke_start_scale_unlinked", STROKE, "stk_start_arrowhead_scale",
     {"panel": {"link_arrowhead_scale": False}}, {"commit": "200"}),
    ("stroke_start_scale_clamped_to_min", STROKE, "stk_start_arrowhead_scale",
     {"panel": {"link_arrowhead_scale": True}}, {"commit": "0"}),
    ("stroke_dashed_press", STROKE, "stk_dashed", {}, {"press": True}),
    # length_input: units, clamping, and the widget's own nullability.
    ("stroke_weight_in_inches", STROKE, "stk_weight", {}, {"commit": "3 in"}),
    ("stroke_weight_clamped_to_max", STROKE, "stk_weight", {}, {"commit": "2000"}),
    ("stroke_weight_unknown_unit", STROKE, "stk_weight", {}, {"commit": "5 dpi"}),
    ("stroke_dash_2_cleared", STROKE, "stk_dash_2",
     {"panel": {"dashed": True, "dash_2": 6},
      "state": {"stroke_dashed": True, "stroke_dash_2": 6}}, {"commit": "  "}),
    ("stroke_dash_1_blank_refused", STROKE, "stk_dash_1",
     {"panel": {"dashed": True}}, {"commit": ""}),
    ("stroke_dash_2_disabled_while_solid", STROKE, "stk_dash_2",
     {"panel": {"dashed": False}}, {"commit": "4"}),
    # select: the declared option's value, or a refusal.
    ("stroke_profile_option", STROKE, "stk_profile", {}, {"commit": "taper_end"}),
    ("stroke_profile_by_label_refused", STROKE, "stk_profile", {},
     {"commit": "Taper End"}),
]


def _store(bundle, panel_id, setup):
    panel = bundle["panels"][panel_id]
    store = StateStore(state_defaults(bundle["state"]))
    for key, value in (setup.get("state") or {}).items():
        store.set(key, value)
    store.init_panel(panel_id, panel_state_defaults(panel))
    store.set_active_panel(panel_id)
    for key, expr in (panel.get("init") or {}).items():
        store.set_panel(panel_id, key, we.evaluate_in(store, expr))
    for key, value in (setup.get("panel") or {}).items():
        store.set_panel(panel_id, key, value)
    return store


def _case(bundle, name, panel_id, widget_id, setup, event):
    panel = bundle["panels"][panel_id]
    widget = find_element_by_id(panel, widget_id)
    if widget is None:
        raise SystemExit(f"{name}: no widget {widget_id!r} in {panel_id}")
    store = _store(bundle, panel_id, setup)
    before_state = store.get_all()
    before_panel = store.get_panel_state(panel_id)
    if "press" in event:
        result = we.press(widget, store, panel=panel)
    else:
        result = we.commit(widget, event["commit"], store, panel=panel)
    after_state = store.get_all()
    return {
        "name": name,
        "panel": panel_id,
        "widget": widget_id,
        "event": event,
        "before": {"panel": before_panel, "state": dict(setup.get("state") or {})},
        "expected": {
            "result": {
                "outcome": result.outcome,
                "reason": result.reason,
                "value": result.value,
                "bind_written": result.bind_written,
                "behaviors_run": result.behaviors_run,
            },
            "panel": store.get_panel_state(panel_id),
            "state_changed": {k: v for k, v in sorted(after_state.items())
                              if k not in before_state or before_state[k] != v},
        },
    }


def build() -> dict:
    bundle = json.loads(BUNDLE.read_text(encoding="utf-8"))
    return {
        "_doc": [line for line in (__doc__ or "").strip().splitlines()],
        "cases": [_case(bundle, *seed) for seed in SEED],
    }


def render(corpus: dict) -> str:
    return json.dumps(corpus, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    corpus = build()
    with OUT.open("w", encoding="utf-8", newline="") as f:
        f.write(render(corpus))
    refused = sum(1 for c in corpus["cases"]
                  if c["expected"]["result"]["outcome"] == "refused")
    print(f"wrote {len(corpus['cases'])} cases ({refused} refused) -> "
          f"{OUT.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
