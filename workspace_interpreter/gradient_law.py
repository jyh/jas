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
