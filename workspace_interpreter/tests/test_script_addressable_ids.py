"""O96 row 72(a): the widgets a test script must name carry ids, and the Layers
search field passes the text it was given.

Spec's S2/S3 scripts address a widget by id (TESTING.md §6). Five widgets a
script must press had none: the swatch tile (stamped per swatch), the
breadcrumb's exit-all chevron and its per-level segment, and Layer Options'
OK and Cancel. Each is found here in the COMPILED bundle, by id, and checked
to be the widget the script means (its kind and the action it runs), so an id
moved onto a neighbour fails.

G1: `lp_search_input`'s `input` behaviour passed `panel.search_query`. An
`input` event writes no bind (WIDGET_EVENTS.md, "Typing in a text field"), so
that read the OLD query and the filter never saw the typed text. It must pass
`event.value`, the field's whole text after the change.
"""

from __future__ import annotations

import json
import os

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def _bundle():
    with open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8") as f:
        return json.load(f)


def _find(node, widget_id):
    """Every node in `node` whose id is `widget_id` (a list, so a duplicate shows)."""
    out = []
    if isinstance(node, dict):
        if node.get("id") == widget_id:
            out.append(node)
        for v in node.values():
            out.extend(_find(v, widget_id))
    elif isinstance(node, list):
        for v in node:
            out.extend(_find(v, widget_id))
    return out


def _one(container, widget_id):
    hits = _find(container, widget_id)
    assert len(hits) == 1, f"{widget_id}: {len(hits)} nodes carry it, want 1"
    return hits[0]


def _actions(widget, event="click"):
    acts = [b.get("action") for b in widget.get("behavior", []) if b.get("event") == event]
    if widget.get("action"):
        acts.append(widget["action"])
    return acts


def test_swatch_tile_has_an_id():
    tile = _one(_bundle()["panels"]["swatches_panel_content"], "sp_swatch_tile")
    assert tile["type"] == "color_swatch"
    assert "set_active_color" in _actions(tile)


def test_breadcrumb_exit_all_has_an_id():
    chev = _one(_bundle()["panels"]["layers_panel_content"], "lp_breadcrumb_exit_all")
    assert chev["type"] == "icon_button"
    (b,) = [b for b in chev["behavior"] if b.get("event") == "click"]
    assert b["action"] == "exit_isolation_to_level"
    assert b["params"] == {"level_index": 0}


def test_breadcrumb_segment_has_an_id():
    seg = _one(_bundle()["panels"]["layers_panel_content"], "lp_breadcrumb_segment")
    assert seg["type"] == "text"
    (b,) = [b for b in seg["behavior"] if b.get("event") == "click"]
    assert b["action"] == "exit_isolation_to_level"
    assert b["params"] == {"level_index": "level._index + 1"}


def test_layer_options_ok_and_cancel_have_ids():
    dlg = _bundle()["dialogs"]["layer_options"]
    ok = _one(dlg, "lo_ok")
    cancel = _one(dlg, "lo_cancel")
    assert ok["type"] == "button" and ok["action"] == "layer_options_confirm"
    assert cancel["type"] == "button" and cancel["action"] == "dismiss_dialog"


def test_layers_search_passes_the_typed_text():
    field = _one(_bundle()["panels"]["layers_panel_content"], "lp_search_input")
    (b,) = [b for b in field["behavior"] if b.get("event") == "input"]
    assert b["action"] == "set_layers_search"
    assert b["params"] == {"query": "event.value"}
