"""PATH_B_DESIGN B.6: a container's ``style.min_height`` floors its height.

Until 2026-09-26 no layout pass read it. The one shipped case, the Color
panel's fill/stroke container (``height: 59.52``, ``min_height: 60``), was
laid out 59 high in every port, because a dimension resolves by truncation.

Synthetic panels witness each rule; the shipped case is pinned by the
``panel_layout.json`` goldens, which Rust and Swift replay. The last test is
the GATE for what B.6 defers: it reds when a panel declares a size key no
layout reads.
"""

import json
import os

from workspace_interpreter.panel_layout import layout_panel


def _rects(content, avail_w=200):
    return {tuple(r["path"]): r["rect"] for r in layout_panel({"content": content}, avail_w)}


def _box(style=None):
    node = {"type": "container", "children": [{"type": "text", "content": "x"}]}
    if style is not None:
        node["style"] = style
    return node


def _content_h():
    return _rects({"type": "container", "children": [_box()]})[(0,)]["h"]


def test_without_a_min_height_a_container_is_its_content_height():
    # The control, and the baseline every floor below is measured against.
    assert _content_h() > 0


def test_a_min_height_above_the_content_is_the_height():
    r = _rects({"type": "container", "children": [_box({"min_height": 60})]})
    assert r[(0,)]["h"] == 60 > _content_h()


def test_a_min_height_below_the_content_changes_nothing():
    # A floor, never a size: it cannot shrink a container.
    r = _rects({"type": "container", "children": [_box({"min_height": 1})]})
    assert r[(0,)]["h"] == _content_h()


def test_a_min_height_floors_a_smaller_declared_height():
    # The shipped shape: a truncated 59.52 is 59, and the floor makes it 60.
    r = _rects({"type": "container", "children": [_box({"height": 59.52, "min_height": 60})]})
    assert r[(0,)]["h"] == 60


def test_a_declared_height_above_the_floor_stands():
    r = _rects({"type": "container", "children": [_box({"height": 80, "min_height": 60})]})
    assert r[(0,)]["h"] == 80


def test_the_next_sibling_starts_below_the_floor():
    r = _rects({"type": "container", "style": {"gap": 0},
                "children": [_box({"min_height": 60}), _box()]})
    assert r[(1,)]["y"] == r[(0,)]["y"] + 60


def test_a_percentage_or_unreadable_floor_is_ignored_as_a_height_is():
    # A height resolves against nothing (B.4), so a percentage has no base.
    for v in ("50%", "auto"):
        r = _rects({"type": "container", "children": [_box({"min_height": v})]})
        assert r[(0,)]["h"] == _content_h(), v


# ── The gate for what B.6 defers ────────────────────────────────────────
#
# The size keys each node class has a layout rule for. A panel node declaring
# any OTHER min/max key is drawn by the web (CSS) and ignored by every port's
# rects: the B.5 divergence again. Zero panel nodes do today; this reds on the
# first one, so the deferral fires on its own precondition.
READ = {"container": {"min_height"}, "leaf": {"min_width"}}
SIZE_KEYS = {"min_width", "min_height", "max_width", "max_height"}


def unread_size_keys(panels):
    found = []

    def walk(n, where):
        if isinstance(n, dict):
            st = n.get("style")
            if isinstance(st, dict):
                cls = "container" if "children" in n or n.get("type") in ("container", "row", "col") else "leaf"
                for k in sorted(SIZE_KEYS & st.keys() - READ[cls]):
                    found.append((where, n.get("id"), cls, k))
            for v in n.values():
                walk(v, where)
        elif isinstance(n, list):
            for v in n:
                walk(v, where)

    for pid, p in panels.items():
        walk(p, pid)
    return found


def test_the_gate_names_a_size_key_no_layout_reads():
    # Positive control: every unread class is reported, the read ones are not.
    panels = {"p": {"content": {"type": "container", "style": {"max_width": 9, "min_height": 9},
                                "children": [{"type": "text", "style": {"min_height": 9, "min_width": 9}}]}}}
    assert unread_size_keys(panels) == [("p", None, "container", "max_width"),
                                        ("p", None, "leaf", "min_height")]


def test_no_shipped_panel_declares_a_size_key_no_layout_reads():
    path = os.path.join(os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")
    with open(path, encoding="utf-8") as f:
        panels = json.load(f)["panels"]
    assert len(panels) > 10, "vacuous: too few panels read"
    assert unread_size_keys(panels) == []
