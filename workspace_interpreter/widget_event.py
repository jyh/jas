"""The widget event contract: what a value widget's event means.

The executable meaning of WIDGET_EVENTS.md. A person commits a value into
an input widget, or presses a boolean one, and this module says what gets
written, in what order, and which declared behaviors run with what
``event.value``. Both active ports and the engine's panel door follow it;
``scripts/check_widget_event_contract.py`` holds the workspace YAML to the
event table below and the document's copy of it.

Three procedures, one per family of kinds:

``commit(widget, text, store, panel=...)`` — the INPUT kinds.
    1. Refuse a disabled widget, a missing value, and text the kind's parse
       refuses. A refusal writes nothing and runs nothing.
    2. Write the parsed value to the bound target, when the target is a
       ``panel.<ident>`` or ``dialog.<ident>`` path. A ``panel.<ident>``
       write also writes the global the panel's ``init:`` hydrates that
       field from, when that mapping is a bare ``state.<ident>``: the
       two-way bind.
    3. Then run every behavior whose event is ``commit`` or ``change``
       (synonyms for these kinds), in declaration order, with
       ``event.value`` set to the parsed value. The store already holds
       the new value, so a behavior that reads its own field reads the
       new one.

``press(widget, store, panel=...)`` — the BOOLEAN kinds.
    The new value is the negation of the bound value. If the widget
    declares a ``click`` or ``change`` behavior, those behaviors ARE the
    press: they run with ``event.value`` set to the new value, and the
    bind write is skipped (the shipped YAML flips its own field, and a
    prior write would flip it back). Otherwise the new value is written,
    with the same two-way bind.

``pick(widget, item_value, event, store, panel=...)`` — the ITEM kinds
    (``dropdown``). The pick names one declared item by its ``value``; an
    ``action`` item runs its own action, any other item runs the behaviors
    declared for ``event`` with ``item`` bound. Nothing is bound or written
    by the pick itself.

``panel`` is the spec of the panel the widget belongs to, or ``None`` for a
widget with no panel (a dialog). It is required, because forgetting it
silently drops the two-way bind.

The bind write is a plain store write. A store write notifies the store's
subscribers, which is how the reference applies a panel to the selection
(``effects.subscribe_stroke_panel``); a port's panel-write host is that
subscriber's counterpart, not a second step of this procedure.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any

from workspace_interpreter.effects import (
    _set_by_scoped_target,
    run_dialog_on_change,
    run_effects,
)
from workspace_interpreter.expr import evaluate
from workspace_interpreter.length import parse_length
from workspace_interpreter.state_store import StateStore

# ── The table ──────────────────────────────────────────────────
# WIDGET_EVENTS.md carries this table too, between its
# `widget-event-table` markers; the lint compares the two.

COMMIT_EVENTS = ("commit", "change")
PRESS_EVENTS = ("click", "change")
# Declared on text_input for search-as-you-type and key handling. They are
# not commits: `commit` never runs them.
TEXT_ENTRY_EVENTS = ("input", "blur", "keydown")

INPUT_KINDS = frozenset({
    "number_input", "length_input", "text_input",
    "select", "icon_select", "icon_button_group", "reference_point_widget",
    "combo_box", "slider", "color_bar",
})
BOOLEAN_KINDS = frozenset({"toggle", "checkbox"})
# A plain pick and an Alt pick of one declared item. They carry the ITEM,
# not text: see `pick`.
PICK_EVENTS = ("toggle", "alt_toggle")
ITEM_KINDS = frozenset({"dropdown"})
# The nine anchors a `reference_point_widget` takes, row by row. The KIND owns
# them (WIDGET_EVENTS.md, Parsing); no YAML declares them.
REFERENCE_POINT_ANCHORS = (
    "top_left", "top_center", "top_right",
    "middle_left", "center", "middle_right",
    "bottom_left", "bottom_center", "bottom_right",
)
# A press that CHECKS and never unchecks: see `check`. Its events are the
# press synonyms.
CHECK_KINDS = frozenset({"radio"})
# A pick of one of a group's `options` by its `id`: see `choose`.
CHOOSE_EVENTS = ("toggle",)
OPTION_KINDS = frozenset({"radio_group"})
# A click runs the widget's `click` behaviors, else its node-level `action`:
# see `click`. `mouse_down` and `mouse_up` are named and not defined here
# (press-and-hold buttons); a click never runs them.
CLICK_EVENTS = ("click",)
POINTER_EVENTS = ("mouse_down", "mouse_up")
CLICK_KINDS = frozenset({"button", "icon_button"})
# The modifier keys a click carries as `event.*`; an absent one reads false.
CLICK_MODIFIERS = ("shift", "ctrl", "meta", "alt")

# The STOPS kind (WIDGET_EVENTS.md §The stops kind): a gesture crosses as
# raw parameters and the slider law (gradient_law) applies it. Its one
# behavior event, ``commit``, is "a gesture finished".
STOPS_KINDS = frozenset({"gradient_slider"})
STOPS_EVENTS = ("commit",)
STOPS_GESTURES = ("press", "drag", "release", "press_midpoint", "drag_midpoint",
                  "release_midpoint", "add", "key")

ALLOWED_EVENTS: dict[str, tuple[str, ...]] = {
    **{kind: COMMIT_EVENTS for kind in INPUT_KINDS},
    "text_input": COMMIT_EVENTS + TEXT_ENTRY_EVENTS,
    **{kind: PRESS_EVENTS for kind in BOOLEAN_KINDS},
    **{kind: PICK_EVENTS for kind in ITEM_KINDS},
    **{kind: PRESS_EVENTS for kind in CHECK_KINDS},
    **{kind: CHOOSE_EVENTS for kind in OPTION_KINDS},
    **{kind: CLICK_EVENTS + POINTER_EVENTS for kind in CLICK_KINDS},
    **{kind: STOPS_EVENTS for kind in STOPS_KINDS},
}

# The names a behavior's expressions can start from: the store's evaluation
# context (with a dialog and its params open) plus `event`. Any other root
# evaluates to null, silently. A widget inside a `foreach` also has its item
# name, which the port's view supplies. The lint holds the YAML to this set.
EVENT_ROOTS = frozenset({
    "event", "state", "panel", "tool", "dialog", "param", "active_document",
    "data",
})

# ── Refusals ───────────────────────────────────────────────────

BAD_VALUE = "BadValue"          # the kind's parse refused the text
MISSING_VALUE = "MissingValue"  # a commit carried no text at all
DISABLED = "Disabled"           # bind.disabled is true
WRONG_KIND = "WrongKind"        # commit on a non-input kind, press on a non-boolean
WRONG_EVENT = "WrongEvent"      # an event the kind's procedure does not take
NO_PRESS = "NoPress"            # a drag or release with no press snapshot
LAW_REFUSED = "LawRefused"      # the slider law refused the gesture
NOT_WRITABLE = "NotWritable"    # a stops widget whose binds are not panel fields


@dataclass(frozen=True)
class EventResult:
    """What one event did.

    ``outcome`` is ``committed`` (something was written or run), ``refused``
    (nothing was, and ``reason`` says why), or ``inert`` (the event was
    valid, but the widget binds nothing writable and declares nothing).
    """
    outcome: str
    reason: str | None = None
    value: Any = None
    bind_written: bool = False
    behaviors_run: int = 0


# ── Parsing ────────────────────────────────────────────────────

# The number grammar, whole-string and ASCII. The reference's `set:`
# coercion (schema._NUMBER_STR_RE under re.match) is wider on two inputs:
# Unicode decimal digits and a trailing newline. Both active ports use the
# narrow form (widget_commit.rs parse_numeric_string, WidgetCommit.swift).
_NUMBER_RE = re.compile(r"-?[0-9]+(?:\.[0-9]+)?", re.ASCII)


def _as_bound(v) -> float | None:
    """A declared bound, or None. A bool is not a number here."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return float(v)


def _clamp(v: float, lo: float | None, hi: float | None) -> float:
    if lo is not None and v < lo:
        v = lo
    if hi is not None and v > hi:
        v = hi
    return v


def _snap(v: float, lo: float | None, step: float | None) -> float:
    """A slider's step (WIDGET_EVENTS.md, Parsing): the nearest step from
    `min` (or 0), half up. No step, or one that is not positive, does not snap."""
    if step is None or step <= 0:
        return v
    base = lo if lo is not None else 0.0
    return base + math.floor((v - base) / step + 0.5) * step


def number_commit(text: str, lo, hi) -> float | None:
    """The number_input commit rule (test_fixtures/algorithms/number_commit.json).

    The text must be a number by the grammar above; the result is clamped
    to whichever bounds are declared. ``None`` means refused.
    """
    if not isinstance(text, str) or _NUMBER_RE.fullmatch(text) is None:
        return None
    return _clamp(float(text), _as_bound(lo), _as_bound(hi))


#: A bare list item that is a divider between groups, never a value
#: (SCHEMA.md, `options`). The same token a menubar's `items` use.
OPTION_DIVIDER = "separator"


def option_rows(options) -> list[dict] | None:
    """How a literal ``options`` list reads (SCHEMA.md, ``options``).

    One row per offered item, in order: ``{"kind": "option", "value": v,
    "label": s}`` (plus ``"glyph"`` when declared) or ``{"kind":
    "separator"}``. A bare item is an option labelled by its own text; the
    bare string ``separator`` is a divider; a map with no ``value`` cannot be
    written and is not offered. ``None`` for computed options (an expression),
    which have no declared rows.

    Pinned for every reader by ``test_fixtures/algorithms/option_rows.json``.
    """
    if not isinstance(options, list):
        return None
    rows = []
    for item in options:
        if item == OPTION_DIVIDER:
            rows.append({"kind": "separator"})
            continue
        if isinstance(item, dict):
            if item.get("value") is None:
                continue
            value = item["value"]
            label = item.get("label")
            row = {"kind": "option", "value": value,
                   "label": label if isinstance(label, str) else str(value)}
            if isinstance(item.get("glyph"), str):
                row["glyph"] = item["glyph"]
            rows.append(row)
            continue
        if item is None:
            continue
        rows.append({"kind": "option", "value": item, "label": str(item)})
    return rows


def parse_commit(widget: dict, text: str) -> tuple[bool, Any]:
    """Parse committed text by the widget's kind: ``(accepted, value)``.

    A refused parse is ``(False, None)``. Raises ``ValueError`` for a kind
    that is not an input kind, because such a kind has no text to parse.
    """
    kind = widget.get("type")
    refused = (False, None)
    lo, hi = _as_bound(widget.get("min")), _as_bound(widget.get("max"))

    if kind == "number_input":
        v = number_commit(text, lo, hi)
        return refused if v is None else (True, v)

    if kind == "length_input":
        if not text.strip():
            return (True, None) if widget.get("nullable") is True else refused
        unit = widget.get("unit")
        v = parse_length(text, unit if isinstance(unit, str) else "pt")
        return refused if v is None else (True, _clamp(v, lo, hi))

    if kind == "text_input":
        return (True, text)

    if kind == "slider":
        v = number_commit(text, lo, hi)
        if v is None:
            return refused
        return (True, _clamp(_snap(v, lo, _as_bound(widget.get("step"))), lo, hi))

    if kind == "color_bar":
        # A point normalized to [0,1]^2 (fork B2): "u,v", each coordinate in
        # the number grammar, each clamped. The colour is
        # color_util.color_bar_rgb(u, v); the parse stops at the point.
        parts = text.split(",")
        if len(parts) != 2:
            return refused
        point = [number_commit(p, 0.0, 1.0) for p in parts]
        return refused if None in point else (True, point)

    if kind == "reference_point_widget":
        return (True, text) if text in REFERENCE_POINT_ANCHORS else refused

    if kind in ("select", "icon_select", "icon_button_group"):
        options = widget.get("options")
        if not isinstance(options, list):
            # Computed options: the shell offered what the expression
            # produced, so the text is the value.
            return (True, text)
        # A divider is not a row a commit can match (SCHEMA.md, `options`).
        for row in option_rows(options):
            if row["kind"] == "option" and str(row["value"]) == text:
                return (True, row["value"])
        return refused

    if kind == "combo_box":
        if not text.strip():
            return refused
        if _NUMBER_RE.fullmatch(text):
            return (True, _clamp(float(text), lo, hi))
        return (True, text)

    raise ValueError(f"{kind!r} is not an input kind")


# ── Targets ────────────────────────────────────────────────────

_WRITABLE_RE = re.compile(r"(panel|dialog)\.([A-Za-z0-9_]+)", re.ASCII)
_GLOBAL_RE = re.compile(r"state\.([A-Za-z0-9_]+)", re.ASCII)


def bound_target(widget: dict) -> str | None:
    """The widget's bound expression: ``bind.value``, else ``bind.checked``,
    else a bare-string ``bind``. ``None`` when there is none."""
    bind = widget.get("bind")
    if isinstance(bind, str):
        return bind
    if isinstance(bind, dict):
        for key in ("value", "checked"):
            if isinstance(bind.get(key), str):
                return bind[key]
    return None


def writable_target(expr) -> tuple[str, str] | None:
    """``(scope, key)`` when the event layer may write ``expr``; else None.

    Only ``panel.<ident>`` and ``dialog.<ident>`` are writable here. Every
    other bind (a state path, a foreach item's field, an indexed path, an
    expression, a name a port handles natively) is read, never written,
    by this layer.
    """
    if not isinstance(expr, str):
        return None
    m = _WRITABLE_RE.fullmatch(expr.strip())
    return (m.group(1), m.group(2)) if m else None


def mirrored_global(panel: dict | None, key: str) -> str | None:
    """The global a panel field is two-way bound to: the ``<ident>`` of a
    bare ``state.<ident>`` in the panel's ``init:`` for ``key``, else None."""
    init = panel.get("init") if isinstance(panel, dict) else None
    expr = init.get(key) if isinstance(init, dict) else None
    m = _GLOBAL_RE.fullmatch(expr.strip()) if isinstance(expr, str) else None
    return m.group(1) if m else None


def _write_bind(target: tuple[str, str], value, store: StateStore, panel) -> None:
    scope, key = target
    _set_by_scoped_target(store, f"{scope}.{key}", value)
    if scope == "panel":
        global_key = mirrored_global(panel, key)
        if global_key is not None:
            store.set(global_key, value)


def _settle(store: StateStore, run_kwargs: dict) -> None:
    """End the event as one batch ends: a write to a field of the open dialog
    runs the dialog's ``on_change`` action, once (WIDGET_EVENTS.md, "The bound
    target"). The hook fires only while the dialog is dirty, so after a
    behavior batch that already fired it this is a no-op."""
    run_dialog_on_change({}, store, **run_kwargs)


def evaluate_in(store: StateStore, expr: str, ctx: dict | None = None):
    """Evaluate ``expr`` against the store, as a behavior would see it."""
    return evaluate(expr, store.eval_context(ctx or {})).value


def _is_disabled(widget: dict, store: StateStore) -> bool:
    bind = widget.get("bind")
    expr = bind.get("disabled") if isinstance(bind, dict) else None
    if not isinstance(expr, str):
        return False
    return evaluate(expr, store.eval_context({})).to_bool()


# ── Running behaviors ──────────────────────────────────────────


def _declared(widget: dict, events: tuple[str, ...]) -> list[dict]:
    behaviors = widget.get("behavior")
    if not isinstance(behaviors, list):
        return []
    return [b for b in behaviors
            if isinstance(b, dict) and b.get("event") in events]


def _run_behaviors(behaviors: list[dict], value, store, run_kwargs: dict,
                   scope: dict | None = None, event: dict | None = None) -> int:
    """Run ``behaviors`` in order; the count excludes a false ``condition``.
    ``scope`` adds names beside ``event`` (a pick's ``item``). ``event``
    replaces the default ``{"value": value}`` (a click's modifiers)."""
    ran = 0
    for b in behaviors:
        ctx = {**(scope or {}), "event": event if event is not None else {"value": value}}
        condition = b.get("condition")
        if isinstance(condition, str) and not evaluate(
                condition, store.eval_context(ctx)).to_bool():
            continue
        effects = b.get("effects")
        if isinstance(effects, list):
            run_effects(effects, ctx, store, **run_kwargs)
        action = b.get("action")
        if isinstance(action, str):
            dispatch = {"action": action, "params": b.get("params") or {}}
            run_effects([{"dispatch": dispatch}], ctx, store, **run_kwargs)
        ran += 1
    return ran


# ── The two procedures ─────────────────────────────────────────


def commit(widget: dict, text: str | None, store: StateStore, *,
           panel: dict | None, **run_kwargs) -> EventResult:
    """Commit ``text`` into an input widget. ``run_kwargs`` go to
    ``run_effects`` (``actions``, ``dialogs``, ``platform_effects``, …)."""
    if widget.get("type") not in INPUT_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    if text is None:
        return EventResult("refused", reason=MISSING_VALUE)
    accepted, value = parse_commit(widget, text)
    if not accepted:
        return EventResult("refused", reason=BAD_VALUE)

    target = writable_target(bound_target(widget))
    if target is not None:
        _write_bind(target, value, store, panel)
    ran = _run_behaviors(_declared(widget, COMMIT_EVENTS), value, store,
                         run_kwargs)
    _settle(store, run_kwargs)
    outcome = "committed" if target is not None or ran else "inert"
    return EventResult(outcome, value=value,
                       bind_written=target is not None, behaviors_run=ran)


def press(widget: dict, store: StateStore, *, panel: dict | None,
          **run_kwargs) -> EventResult:
    """Press a boolean widget."""
    if widget.get("type") not in BOOLEAN_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)

    expr = bound_target(widget)
    current = (evaluate(expr, store.eval_context({})).to_bool()
               if expr is not None else False)
    value = not current

    declared = _declared(widget, PRESS_EVENTS)
    if declared:
        # Declared, not merely run: a behavior skipped by its condition
        # still owns the press, so the field is not written behind it.
        ran = _run_behaviors(declared, value, store, run_kwargs)
        return EventResult("committed" if ran else "inert", value=value,
                           behaviors_run=ran)
    target = writable_target(expr)
    if target is None:
        return EventResult("inert", value=value)
    _write_bind(target, value, store, panel)
    _settle(store, run_kwargs)
    return EventResult("committed", value=value, bind_written=True)


def check(widget: dict, store: StateStore, *, panel: dict | None,
          **run_kwargs) -> EventResult:
    """Press a CHECK kind (``radio``): check it, never uncheck it.

    Refuse a wrong kind or a disabled radio. A radio whose bound expression
    is already true is ``inert``. Otherwise its node-level ``on_check``
    effects ARE the check (``event.value`` is ``True``, nothing is written
    behind them); with none, ``True`` is written to a writable bind. Any
    declared ``click``/``change`` behaviors run after, in order.
    """
    if widget.get("type") not in CHECK_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    expr = bound_target(widget)
    if expr is not None and evaluate(expr, store.eval_context({})).to_bool():
        return EventResult("inert", value=True)
    ran = 0
    written = False
    on_check = widget.get("on_check")
    if isinstance(on_check, list) and on_check:
        run_effects(on_check, {"event": {"value": True}}, store, **run_kwargs)
        ran = 1
    else:
        target = writable_target(expr)
        if target is not None:
            _write_bind(target, True, store, panel)
            written = True
    ran += _run_behaviors(_declared(widget, PRESS_EVENTS), True, store, run_kwargs)
    _settle(store, run_kwargs)
    return EventResult("committed" if ran or written else "inert", value=True,
                       bind_written=written, behaviors_run=ran)


def choose(widget: dict, option_id, event: str, store: StateStore, *,
           panel: dict | None, **run_kwargs) -> EventResult:
    """Pick one option of an OPTION kind (``radio_group``) by its ``id``.

    Refuse a wrong kind, an event other than ``toggle``, a disabled group, a
    pick naming no option (``MissingValue``) or one the group does not
    declare (``BadValue``). The option whose ``id`` equals the bound value as
    text is already checked: ``inert``. Otherwise write the ``id`` (a string)
    to a writable bind, then run the ``toggle`` behaviors with
    ``event.value`` set to the ``id``.
    """
    if widget.get("type") not in OPTION_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if event not in CHOOSE_EVENTS:
        return EventResult("refused", reason=WRONG_EVENT)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    if option_id is None:
        return EventResult("refused", reason=MISSING_VALUE)
    options = widget.get("options") if isinstance(widget.get("options"), list) else []
    if not any(isinstance(o, dict) and o.get("id") == option_id for o in options):
        return EventResult("refused", reason=BAD_VALUE)
    expr = bound_target(widget)
    if expr is not None and _as_text(evaluate(expr, store.eval_context({}))) == option_id:
        return EventResult("inert", value=option_id)
    target = writable_target(expr)
    if target is not None:
        _write_bind(target, option_id, store, panel)
    ran = _run_behaviors(_declared(widget, (event,)), option_id, store, run_kwargs)
    _settle(store, run_kwargs)
    return EventResult("committed" if target is not None or ran else "inert",
                       value=option_id, bind_written=target is not None,
                       behaviors_run=ran)


def click(widget: dict, event: str, store: StateStore, *, panel: dict | None,
          modifiers: dict | None = None, **run_kwargs) -> EventResult:
    """Click a CLICK kind (``button``, ``icon_button``).

    Refuse a wrong kind, an event other than ``click`` (``WrongEvent``) and a
    disabled widget. ``event`` is the click's modifiers (``shift``, ``ctrl``,
    ``meta``, ``alt``; an absent one is false) and carries no value. If the
    widget declares any ``click`` behavior, those behaviors ARE the click, run
    in order, and the node-level ``action`` does not run, even when every
    condition is false. Otherwise a node-level ``action`` is dispatched with
    its ``params``, exactly as a behavior's ``action`` is. A click that runs
    nothing is ``inert``. A click writes no bind.
    """
    del panel  # no bind write: accepted for the procedures' common signature
    if widget.get("type") not in CLICK_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if event not in CLICK_EVENTS:
        return EventResult("refused", reason=WRONG_EVENT)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    mods = {k: bool((modifiers or {}).get(k, False)) for k in CLICK_MODIFIERS}
    declared = _declared(widget, CLICK_EVENTS)
    if declared:
        ran = _run_behaviors(declared, None, store, run_kwargs, event=mods)
        return EventResult("committed" if ran else "inert", behaviors_run=ran)
    action = widget.get("action")
    if not isinstance(action, str):
        return EventResult("inert")
    ran = _run_behaviors([{"action": action, "params": widget.get("params")}],
                         None, store, run_kwargs, event=mods)
    return EventResult("committed", behaviors_run=ran)


def _as_text(v) -> str | None:
    """A bound value as the text an option ``id`` is compared with: a
    string as itself, a whole number without its ``.0``, a bool as
    ``true``/``false``, anything else ``None``."""
    raw = v.value if hasattr(v, "value") else v
    if isinstance(raw, bool):
        return "true" if raw else "false"
    if isinstance(raw, str):
        return raw
    if isinstance(raw, (int, float)):
        return str(int(raw)) if float(raw).is_integer() else str(raw)
    return None


def pick(widget: dict, item_value, event: str, store: StateStore, *,
         panel: dict | None, **run_kwargs) -> EventResult:
    """Pick one declared item of an ITEM kind (``dropdown``).

    The pick names its item by the item's ``value``. Refuse a wrong kind, an
    event the item kinds do not raise, a disabled widget, a pick that names
    no item (``MissingValue``), and one naming an item the widget does not
    declare (``BadValue``; a ``separator`` is not an item). An ``action``
    item runs its own ``action`` and no behavior. Any other item runs every
    behavior declared for ``event``, in order, with ``item`` bound to the
    declared item and ``event.value`` to its value. A dropdown binds no
    value, so nothing is written but what the behaviors write.
    """
    del panel  # no bind write: accepted for the procedures' common signature
    if widget.get("type") not in ITEM_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if event not in PICK_EVENTS:
        return EventResult("refused", reason=WRONG_EVENT)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    if item_value is None:
        return EventResult("refused", reason=MISSING_VALUE)
    items = widget.get("items") if isinstance(widget.get("items"), list) else []
    item = next((i for i in items
                 if isinstance(i, dict) and i.get("value") == item_value), None)
    if item is None:
        return EventResult("refused", reason=BAD_VALUE)
    if item.get("type") == "action":
        action = item.get("action")
        if not isinstance(action, str):
            return EventResult("inert", value=item_value)
        dispatch = {"action": action, "params": item.get("params") or {}}
        run_effects([{"dispatch": dispatch}], {"item": item}, store, **run_kwargs)
        return EventResult("committed", value=item_value)
    ran = _run_behaviors(_declared(widget, (event,)), item_value, store,
                         run_kwargs, scope={"item": item})
    return EventResult("committed" if ran else "inert", value=item_value,
                       behaviors_run=ran)


# ── The stops kind (WIDGET_EVENTS.md §The stops kind) ─────────

#: The suffix of the panel key a press snapshots into, beside the bound
#: stops (``panel.stops`` -> ``panel.stops__press``).
PRESS_SUFFIX = "__press"

#: A key's nudge: (plain, with Shift); Home and End go to 0 and 100.
NUDGE = {"Left": (-1, -10), "Right": (1, 10)}


def _stops_targets(widget: dict) -> dict | None:
    """The three binds a stops widget writes, each a ``panel.`` key, or
    ``None`` when any is missing or not a panel field."""
    bind = widget.get("bind")
    if not isinstance(bind, dict):
        return None
    out = {}
    for name in ("stops", "selected_stop_index", "selected_midpoint_index"):
        t = writable_target(bind.get(name))
        if t is None or t[0] != "panel":
            return None
        out[name] = t[1]
    return out


def gesture(widget: dict, name: str, params: dict, store: StateStore, *,
            panel: dict | None, **run_kwargs) -> EventResult:
    """Apply one slider gesture to a STOPS widget.

    ``press`` / ``press_midpoint`` select and snapshot the bound stops, with
    the GRAB: how far the pointer's ``location`` lay from the pressed marker.
    ``drag`` / ``drag_midpoint`` apply the law to the SNAPSHOT at the
    pointer's location less the grab, so a marker moves by how far the
    pointer moved, never to the pointer (a click off its centre moves
    nothing), and write the
    stops and selection, running no behavior. ``release`` /
    ``release_midpoint`` write the same way, clear the snapshot, and run the
    ``commit`` behaviors with ``event.value`` the new stops; so do ``add``
    and ``key``, over the current stops. A refusal writes nothing."""
    from workspace_interpreter import gradient_law as law
    if widget.get("type") not in STOPS_KINDS:
        return EventResult("refused", reason=WRONG_KIND)
    if name not in STOPS_GESTURES:
        return EventResult("refused", reason=WRONG_EVENT)
    if _is_disabled(widget, store):
        return EventResult("refused", reason=DISABLED)
    keys = _stops_targets(widget)
    if keys is None:
        return EventResult("refused", reason=NOT_WRITABLE)
    panel_id = store.get_active_panel_id()
    read = lambda k: store.get_panel(panel_id, k)
    write = lambda k, v: _write_bind(("panel", k), v, store, panel)
    press_key = keys["stops"] + PRESS_SUFFIX
    stops = read(keys["stops"]) or []
    refused = EventResult("refused", reason=LAW_REFUSED)

    def select(stop: int, midpoint: int) -> None:
        write(keys["selected_stop_index"], stop)
        write(keys["selected_midpoint_index"], midpoint)

    def finish(new_stops, stop: int, midpoint: int) -> EventResult:
        write(keys["stops"], new_stops)
        select(stop, midpoint)
        ran = _run_behaviors(_declared(widget, STOPS_EVENTS), new_stops, store,
                             run_kwargs)
        return EventResult("committed", value=new_stops, bind_written=True,
                           behaviors_run=ran)

    if name in ("press", "press_midpoint"):
        kind = "stop" if name == "press" else "midpoint"
        i = params.get("index" if kind == "stop" else "pair")
        n = len(stops) if kind == "stop" else len(stops) - 1
        if isinstance(i, bool) or not isinstance(i, int) or not 0 <= i < n:
            return refused
        at = params.get("location")
        if isinstance(at, bool) or not isinstance(at, (int, float)):
            return refused
        if kind == "stop":
            here = stops[i]["location"]
        else:
            a, b = stops[i]["location"], stops[i + 1]["location"]
            here = a + (b - a) * stops[i].get("midpoint_to_next", 50) / 100
        write(press_key, {"kind": kind, "index": i, "stops": stops, "grab": at - here})
        if kind == "stop":
            select(i, -1)
        else:
            select(-1, i)
        return EventResult("committed", bind_written=True)

    if name in ("drag", "release", "drag_midpoint", "release_midpoint"):
        kind = "stop" if name in ("drag", "release") else "midpoint"
        snap = read(press_key)
        if not isinstance(snap, dict) or snap.get("kind") != kind:
            return EventResult("refused", reason=NO_PRESS)
        at = params.get("location")
        if isinstance(at, (int, float)) and not isinstance(at, bool):
            at = at - snap.get("grab", 0)
        if kind == "stop":
            got = law.drag_stop(snap["stops"], snap["index"], at, params.get("dy"))
            if got is None:
                return refused
            new_stops, sel = got
            sel_stop, sel_mid = sel, -1
        else:
            new_stops = law.drag_midpoint(snap["stops"], snap["index"], at)
            if new_stops is None:
                return refused
            sel_stop, sel_mid = -1, snap["index"]
        if name.startswith("drag"):
            write(keys["stops"], new_stops)
            select(sel_stop, sel_mid)
            return EventResult("committed", value=new_stops, bind_written=True)
        write(press_key, None)
        return finish(new_stops, sel_stop, sel_mid)

    if name == "add":
        got = law.add_stop(stops, params.get("location"))
        if got is None:
            return refused
        return finish(got[0], got[1], -1)

    # key
    key, shift = params.get("key"), bool(params.get("shift"))
    stop, midpoint = read(keys["selected_stop_index"]), read(keys["selected_midpoint_index"])
    if isinstance(stop, int) and 0 <= stop < len(stops):
        if key in ("Delete", "Backspace"):
            got = law.delete_stop(stops, stop)
        elif key in NUDGE or key in ("Home", "End"):
            here = stops[stop]["location"]
            to = (here + NUDGE[key][shift] if key in NUDGE
                  else 0 if key == "Home" else 100)
            got = law.drag_stop(stops, stop, to, 0)
        else:
            return EventResult("inert")
        if got is None:
            return refused
        return finish(got[0], got[1], -1)
    if isinstance(midpoint, int) and 0 <= midpoint < len(stops) - 1:
        if key in NUDGE or key in ("Home", "End"):
            here = stops[midpoint]["midpoint_to_next"]
            to = (here + NUDGE[key][shift] if key in NUDGE
                  else 0 if key == "Home" else 100)
            new_stops = law.set_midpoint(stops, midpoint, to)
            if new_stops is None:
                return refused
            return finish(new_stops, -1, midpoint)
        return EventResult("inert")
    return EventResult("inert")
