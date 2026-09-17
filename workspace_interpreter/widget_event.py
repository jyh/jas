"""The widget event contract: what a value widget's event means.

The executable meaning of WIDGET_EVENTS.md. A person commits a value into
an input widget, or presses a boolean one, and this module says what gets
written, in what order, and which declared behaviors run with what
``event.value``. Both active ports and the engine's panel door follow it;
``scripts/check_widget_event_contract.py`` holds the workspace YAML to the
event table below and the document's copy of it.

Two procedures, one per family of kinds:

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

``panel`` is the spec of the panel the widget belongs to, or ``None`` for a
widget with no panel (a dialog). It is required, because forgetting it
silently drops the two-way bind.

The bind write is a plain store write. A store write notifies the store's
subscribers, which is how the reference applies a panel to the selection
(``effects.subscribe_stroke_panel``); a port's panel-write host is that
subscriber's counterpart, not a second step of this procedure.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from workspace_interpreter.effects import _set_by_scoped_target, run_effects
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
    "select", "icon_select", "combo_box",
})
BOOLEAN_KINDS = frozenset({"toggle", "checkbox"})

ALLOWED_EVENTS: dict[str, tuple[str, ...]] = {
    **{kind: COMMIT_EVENTS for kind in INPUT_KINDS},
    "text_input": COMMIT_EVENTS + TEXT_ENTRY_EVENTS,
    **{kind: PRESS_EVENTS for kind in BOOLEAN_KINDS},
}

# The names a behavior's expressions can start from: the store's evaluation
# context (with a dialog and its params open) plus `event`. Any other root
# evaluates to null, silently. A widget inside a `foreach` also has its item
# name, which the port's view supplies. The lint holds the YAML to this set.
EVENT_ROOTS = frozenset({
    "event", "state", "panel", "tool", "dialog", "param", "active_document",
})

# ── Refusals ───────────────────────────────────────────────────

BAD_VALUE = "BadValue"          # the kind's parse refused the text
MISSING_VALUE = "MissingValue"  # a commit carried no text at all
DISABLED = "Disabled"           # bind.disabled is true
WRONG_KIND = "WrongKind"        # commit on a non-input kind, press on a non-boolean


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


def number_commit(text: str, lo, hi) -> float | None:
    """The number_input commit rule (test_fixtures/algorithms/number_commit.json).

    The text must be a number by the grammar above; the result is clamped
    to whichever bounds are declared. ``None`` means refused.
    """
    if not isinstance(text, str) or _NUMBER_RE.fullmatch(text) is None:
        return None
    return _clamp(float(text), _as_bound(lo), _as_bound(hi))


def _option_value(option):
    return option.get("value") if isinstance(option, dict) else option


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

    if kind in ("select", "icon_select"):
        options = widget.get("options")
        if not isinstance(options, list):
            # Computed options: the shell offered what the expression
            # produced, so the text is the value.
            return (True, text)
        for option in options:
            value = _option_value(option)
            if value is not None and str(value) == text:
                return (True, value)
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


def _run_behaviors(behaviors: list[dict], value, store, run_kwargs: dict) -> int:
    """Run ``behaviors`` in order; the count excludes a false ``condition``."""
    ran = 0
    for b in behaviors:
        ctx = {"event": {"value": value}}
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
    return EventResult("committed", value=value, bind_written=True)
