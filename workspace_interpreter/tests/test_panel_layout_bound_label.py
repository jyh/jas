"""A button whose label is BOUND is as wide as the label it draws (flask
STATUS §569, finding L). The renderers draw `bind.label` evaluated as an
expression when it yields a string, else the static `label` (Rust
`render_button`); the layout measured the static `label` alone, so a bound
label measured 0 and the button was planned 16 wide, its text clipped to a
sliver on Windows (Make Mask, and each Concepts operation button).

The two shipped sites are Opacity's `op_make_mask` (an `if` over
`selection_has_mask`) and the Concepts panel's operation buttons (`op.label`
inside a foreach); these synthetic arms pin the rule, and Rust and Swift
carry the same.
"""

from workspace_interpreter.panel_layout import CHAR_WIDTH, layout_panel


def _w(leaf, ctx=None):
    rows = layout_panel({"content": {"type": "row", "children": [leaf]}}, 400, ctx=ctx)
    return next(r["rect"]["w"] for r in rows if r["path"] == [0])


def test_a_bound_label_is_measured_as_it_draws():
    mask = {"type": "button", "bind": {"label": 'if selection_has_mask then "Release" else "Make Mask"'}}
    assert _w(mask, {"selection_has_mask": False}) == 9 * CHAR_WIDTH + 16
    assert _w(mask, {"selection_has_mask": True}) == 7 * CHAR_WIDTH + 16, "the other arm"
    assert _w({"type": "button", "bind": {"label": "op.label"}}, {"op": {"label": "Add Side"}}) == \
        8 * CHAR_WIDTH + 16, "a foreach row's label"


def test_a_bound_label_beats_the_static_one_and_falls_back_to_it():
    both = {"type": "button", "label": "Static", "bind": {"label": "op.label"}}
    assert _w(both, {"op": {"label": "Bound label"}}) == 11 * CHAR_WIDTH + 16
    assert _w(both, {}) == 6 * CHAR_WIDTH + 16, "a non-string result draws, and measures, the static label"
    assert _w({"type": "button", "label": "Static"}) == 6 * CHAR_WIDTH + 16, "no bind: unchanged"
