"""The Gradient panel's stop-edit law — the spec's executable meaning.

``STOP_OPACITY_COMBO`` and ``STOP_LOCATION_COMBO`` (transcripts/GRADIENT.md)
edit the SELECTED stop of the active gradient. Their bind is an indexed path
(``panel.stops[panel.selected_stop_index].opacity``), which the widget-event
layer reads and never writes (WIDGET_EVENTS.md), so each widget does its work
through a declared behavior that names the field; a port's gradient host
applies the edit to the selection's own gradient through this law.

``edit_stop`` is PURE and dict-shaped: a stop is the YAML's
``{color, opacity, location, midpoint_to_next}``. It is pinned by
``test_fixtures/gradient_stop/stop_edit.json``, which the Rust and Swift
ports read too.
"""

from __future__ import annotations

import math
from typing import Any

#: The stop fields this law writes. Colour goes through the colour picker.
STOP_FIELDS = ("opacity", "location")


def _percent(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    v = float(value)
    return v if 0.0 <= v <= 100.0 else None


def edit_stop(stops: list[dict], index: int, field: str,
              value: Any) -> tuple[list[dict], int] | None:
    """``stops`` with stop ``index``'s ``field`` set to ``value``, and the
    index that stop now sits at; ``None`` (refused, nothing written) when
    ``index`` names no stop, ``field`` is not a stop field, or ``value`` is
    not a number in [0, 100].

    ``opacity`` is a plain set. ``location`` sets the location and then
    re-sorts the list by location, STABLY (a tie does not cross a neighbour);
    the selected index follows the moved stop, and every stop whose NEXT stop
    changed has its ``midpoint_to_next`` reset to 50 (GRADIENT.md
    §Combo-driven reorder: "midpoints involved in the reorder reset to 50%").
    """
    if field not in STOP_FIELDS or not isinstance(index, int) \
            or isinstance(index, bool) or not 0 <= index < len(stops):
        return None
    v = _percent(value)
    if v is None:
        return None
    out = [dict(s) for s in stops]
    out[index][field] = v
    if field == "opacity":
        return out, index
    # Sort positions, not stops, so "the next stop changed" compares
    # identities (two stops may be equal as values).
    order = sorted(range(len(out)), key=lambda i: out[i]["location"])
    old_next = {i: (i + 1 if i + 1 < len(out) else None) for i in range(len(out))}
    new_next = {order[k]: (order[k + 1] if k + 1 < len(order) else None)
                for k in range(len(order))}
    for i in range(len(out)):
        if old_next[i] != new_next[i]:
            out[i]["midpoint_to_next"] = 50
    return [out[i] for i in order], order.index(index)


# ── The slider law (GRADIENT.md, The slider law (precisely)) ─────────────
#
# Five pure functions for the GRADIENT_SLIDER's gestures, pinned by
# ``test_fixtures/gradient_stop/slider.json``. They share the combo law's two
# rules: a sort is stable, and a midpoint resets to 50 exactly when its
# stop's NEXT stop changed, compared by identity.

#: A stop drag released further than this from the bar's centre line, in
#: pixels, deletes the stop. Strict: exactly this far is still on the bar.
OFF_BAR_PX = 20


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _index(value: Any, n: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < n:
        return None
    return value


def _clamp(v: float) -> float:
    return min(max(v, 0.0), 100.0)


def _rgb(color: str) -> tuple[int, int, int] | None:
    if not isinstance(color, str) or len(color) != 7 or color[0] != "#":
        return None
    try:
        return int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    except ValueError:
        return None


def round_channel(x: float) -> int:
    """A channel rounded half UP (Python's ``round`` is half-even)."""
    return int(math.floor(x + 0.5))


def _reset_changed_nexts(old: list[dict], order: list[int | None]) -> list[dict]:
    """``order`` lists, for each output position, the index in ``old`` it
    came from (``None`` for a new stop). Returns the output stops, with the
    midpoint of every OLD stop whose next stop changed reset to 50."""
    out = []
    for k, src in enumerate(order):
        if src is None:
            out.append(None)
            continue
        s = dict(old[src])
        old_next = src + 1 if src + 1 < len(old) else None
        new_next = order[k + 1] if k + 1 < len(order) else None
        # A NEW stop as the next stop is always a change, even for the old
        # last stop, whose old next is also None.
        gained_new = k + 1 < len(order) and new_next is None
        if gained_new or old_next != new_next:
            s["midpoint_to_next"] = 50
        out.append(s)
    return out


def value_at(stops: list[dict], location: float) -> tuple[str, float] | None:
    """The gradient's colour (``#rrggbb``) and opacity at ``location``, over
    ``stops`` taken in location order, with the midpoint honoured and classic
    sRGB interpolation; ``None`` when a colour does not parse."""
    s = sorted(stops, key=lambda t: t["location"])
    below = [k for k, t in enumerate(s) if t["location"] <= location]
    if not below:
        a, b, u = s[0], None, 0.0
    elif below[-1] == len(s) - 1:
        a, b, u = s[-1], None, 0.0
    else:
        a, b = s[below[-1]], s[below[-1] + 1]
        t = (location - a["location"]) / (b["location"] - a["location"])
        m = a["midpoint_to_next"] / 100
        u = 0.5 * (t / m) if t < m else 0.5 + 0.5 * ((t - m) / (1 - m))
    ca = _rgb(a["color"])
    if ca is None:
        return None
    if b is None:
        return "#%02x%02x%02x" % ca, a["opacity"]
    cb = _rgb(b["color"])
    if cb is None:
        return None
    ch = [round_channel(x + u * (y - x)) for x, y in zip(ca, cb)]
    return "#%02x%02x%02x" % tuple(ch), a["opacity"] + u * (b["opacity"] - a["opacity"])


def add_stop(stops: list[dict], location: Any) -> tuple[list[dict], int] | None:
    """A click on the empty bar: ``stops`` sorted stably by location with a
    new stop inserted after every stop at or below ``location``, carrying the
    gradient's value there and midpoint 50, and the new stop's index.
    Refused when ``location`` is not a number in [0, 100] or there are no
    stops."""
    loc = _number(location)
    if loc is None or not 0.0 <= loc <= 100.0 or not stops:
        return None
    value = value_at(stops, loc)
    if value is None:
        return None
    order: list[int | None] = sorted(range(len(stops)), key=lambda i: stops[i]["location"])
    at = sum(1 for i in order if stops[i]["location"] <= loc)
    order.insert(at, None)
    out = _reset_changed_nexts(stops, order)
    color, opacity = value
    out[at] = {"color": color, "opacity": opacity, "location": loc,
               "midpoint_to_next": 50}
    return out, at


def delete_stop(stops: list[dict], index: Any) -> tuple[list[dict], int] | None:
    """The trash button, Delete, or a drag off the bar: ``stops`` without
    stop ``index`` (stored order, no sort) and the selected stop afterwards,
    the deleted stop's left neighbour or 0. Refused at the two-stop floor."""
    i = _index(index, len(stops))
    if i is None or len(stops) <= 2:
        return None
    order: list[int | None] = [k for k in range(len(stops)) if k != i]
    return _reset_changed_nexts(stops, order), max(i - 1, 0)


def drag_stop(press_stops: list[dict], index: Any, location: Any,
              dy: Any) -> tuple[list[dict], int] | None:
    """A stop drag, computed from the stops at the PRESS: a delete when
    ``|dy|`` exceeds :data:`OFF_BAR_PX` and three or more stops remain,
    else the location (clamped to [0, 100]) applied by :func:`edit_stop`."""
    i = _index(index, len(press_stops))
    loc, d = _number(location), _number(dy)
    if i is None or loc is None or d is None:
        return None
    if abs(d) > OFF_BAR_PX and len(press_stops) > 2:
        return delete_stop(press_stops, i)
    return edit_stop(press_stops, i, "location", _clamp(loc))


def set_midpoint(stops: list[dict], pair: Any, value: Any) -> list[dict] | None:
    """``stops[pair].midpoint_to_next`` set to ``value`` clamped to [0, 100].
    Refused when ``pair`` names no stop with a next stop."""
    p, v = _index(pair, len(stops) - 1), _number(value)
    if p is None or v is None:
        return None
    out = [dict(s) for s in stops]
    out[p]["midpoint_to_next"] = _clamp(v)
    return out


def drag_midpoint(stops: list[dict], pair: Any, location: Any) -> list[dict] | None:
    """A midpoint drag to absolute ``location``: the pair's midpoint set to
    ``(location - a) / (b - a) * 100``, clamped, for ``a``, ``b`` the pair's
    two stops in stored order. Refused for a zero-width pair."""
    p, loc = _index(pair, len(stops) - 1), _number(location)
    if p is None or loc is None:
        return None
    a, b = stops[p]["location"], stops[p + 1]["location"]
    if a == b:
        return None
    return set_midpoint(stops, p, ((loc - a) / (b - a)) * 100)
