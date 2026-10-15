"""The two radio kinds have a width (WIDGET_EVENTS.md §Checking a radio and
§Picking a radio option made them value kinds, 2026-10-15). Until then both fell
to the leaf table's `0`, so every port planned a radio at zero width and a
shell drew a choice it could not size (flask STATUS §280).

* ``radio`` is sized as ``checkbox``: a 16 indicator, a 4 gap, its label.
* ``radio_group`` is its options in a row, each a 16 indicator plus, when the
  option has a label, a 4 gap and the label; options are 6 apart (the web
  renderer's ``gap:6px``). The Color Picker's one-option, unlabelled groups
  are 16 wide.

No shipped PANEL holds a radio (all live in dialogs), so the panel goldens do
not witness this; these synthetic arms do, and Rust and Swift carry the same.
"""

from workspace_interpreter.panel_layout import CHAR_WIDTH, layout_panel


def _w(leaf):
    rows = layout_panel({"content": {"type": "row", "children": [leaf]}}, 400)
    return next(r["rect"]["w"] for r in rows if r["path"] == [0])


def test_a_radio_is_sized_as_a_checkbox():
    label = {"label": "Vertical"}
    assert _w({"type": "radio", **label}) == 16 + 4 + 8 * CHAR_WIDTH
    assert _w({"type": "radio", **label}) == _w({"type": "checkbox", **label}), "the control"


def test_an_unlabelled_one_option_group_is_its_indicator():
    assert _w({"type": "radio_group", "options": [{"id": "h", "label": ""}]}) == 16


def test_a_group_is_its_options_in_a_row_six_apart():
    opts = [{"id": "a", "label": "Ab"}, {"id": "b"}, {"id": "c", "label": "C"}]
    assert _w({"type": "radio_group", "options": opts}) == \
        (16 + 4 + 2 * CHAR_WIDTH) + 6 + 16 + 6 + (16 + 4 + 1 * CHAR_WIDTH)


def test_an_icon_button_group_is_its_buttons_four_apart():
    # The web's `gap:4px` between 24-wide buttons: the orientation pair is 52.
    opts = [{"icon": "orientation_portrait", "value": "portrait"},
            {"icon": "orientation_landscape", "value": "landscape"}]
    assert _w({"type": "icon_button_group", "options": opts}) == 24 + 4 + 24
    assert _w({"type": "icon_button_group"}) == 0


def test_a_reference_point_widget_is_its_3x3_grid():
    # The web's `repeat(3, 8px)` tracks with `gap: 2px`, both ways: 28 x 28.
    rows = layout_panel({"content": {"type": "row", "children": [
        {"type": "reference_point_widget"}]}}, 400)
    rect = next(r["rect"] for r in rows if r["path"] == [0])
    assert (rect["w"], rect["h"]) == (28, 28)


def test_a_group_with_no_options_is_empty():
    assert _w({"type": "radio_group"}) == 0
    assert _w({"type": "radio_group", "options": "dialog.list"}) == 0, "computed options: unknown"
