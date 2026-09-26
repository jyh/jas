"""PATH_B_DESIGN B.5: a container's ``style.width`` is honoured as its
``style.height`` is (B.4). Until 2026-09-26 no layout pass read it, while the
web DOM did (through CSS), so four shipped containers drew one width on the web
and another in every port's rects.

Synthetic panels, so each rule is witnessed by a shape the shipped panels may
not take. The shipped cases are pinned by the ``panel_layout.json`` goldens,
which Rust and Swift replay.
"""

from workspace_interpreter.panel_layout import layout_panel


def _rects(content, avail_w=200):
    return {tuple(r["path"]): r["rect"] for r in layout_panel({"content": content}, avail_w)}


def _box(style=None, children=None, **kw):
    node = {"type": "container", "children": children or [{"type": "separator"}]}
    if style is not None:
        node["style"] = style
    node.update(kw)
    return node


def test_a_container_without_a_width_fills_the_width_it_is_given():
    # The control: nothing declared, nothing changes.
    r = _rects({"type": "container", "children": [_box()]})
    assert r[(0,)]["w"] == 200


def test_a_declared_width_is_the_containers_width_in_a_column():
    r = _rects({"type": "container", "children": [_box({"width": 40})]})
    assert r[(0,)]["w"] == 40


def test_its_children_are_laid_out_in_the_declared_width():
    # A fill leaf (separator) takes the width its container gives it.
    r = _rects({"type": "container", "children": [_box({"width": 40, "padding": 4})]})
    assert r[(0, 0)]["w"] == 40 - 8


def test_a_width_wider_than_the_space_is_clamped_to_it():
    r = _rects({"type": "container", "children": [_box({"width": 500})]})
    assert r[(0,)]["w"] == 200


def test_a_percentage_resolves_against_the_width_given():
    r = _rects({"type": "container", "children": [_box({"width": "25%"})]})
    assert r[(0,)]["w"] == 50


def test_an_unreadable_width_is_ignored_like_any_other_dimension():
    r = _rects({"type": "container", "children": [_box({"width": "auto"})]})
    assert r[(0,)]["w"] == 200


def test_in_a_row_the_declared_width_is_the_containers_natural_width():
    # A row places children at their natural width; a sized container next to a
    # text leaf starts the text after the declared 30, not after its content.
    row = {"type": "container", "layout": "row",
           "children": [_box({"width": 30}), {"type": "text", "content": "ab"}]}
    r = _rects(row)
    assert r[(0,)]["w"] == 30
    assert r[(1,)]["x"] == 30


def test_the_height_rule_is_unchanged():
    r = _rects({"type": "container", "children": [_box({"width": 40, "height": 24})]})
    assert (r[(0,)]["w"], r[(0,)]["h"]) == (40, 24)
