"""Path B layout property tests: no panel renders overlapping or
overflowing widgets.

The cross-language byte-gate (``test_fixtures/algorithms/panel_layout.json``)
proves the 5 apps *agree* on the rects, but a layout that is consistently
wrong across apps still passes it. This suite pins the *semantic* property
the byte-gate cannot: within a panel, no two leaf widgets overlap, and no
leaf extends past the panel width.

The defect this guards against: rows with ``col`` spans use the Bootstrap-12
grid; a child whose intrinsic width exceeds its column cell used to render at
that intrinsic width, overrunning its neighbour (e.g. the Opacity panel's
"Opacity:" label over the value field; the Stroke panel's dash inputs). The
grid now grows cells to their content and shrinks-to-fit when a row
over-subscribes, clamping each leaf to its cell so nothing overlaps.
"""

from __future__ import annotations

import importlib.util
import json
import os

import pytest

from workspace_interpreter.expr import evaluate
from workspace_interpreter.panel_layout import render_plan

_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
_PANEL_W = 228  # canonical dock panel width (matches the byte-gate seed)

# Composite panels whose data-driven widgets the v1 absolute pass does not
# size yet; they stay on each app's native layout path. gradient/layers carry
# composite/tree widgets. (Color and Swatches were excluded here until
# 2026-10-12 because their fill/stroke widget is a 2-D arrangement of
# positioned children; PATH_B_DESIGN B.8 and B.9 lay it out.)
_EXCLUDED = {
    "gradient_panel_content",
    "layers_panel_content",
}


def _load_ctx() -> dict:
    """The real per-panel eval context used by the byte-gate golden, so this
    test exercises the same data the apps render (foreach lists, bindings)."""
    path = os.path.join(_ROOT, "scripts", "gen_panel_layout_fixture.py")
    spec = importlib.util.spec_from_file_location("gen_panel_layout_fixture", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod._CTX


def _panels() -> dict:
    bundle = json.load(open(os.path.join(_ROOT, "workspace", "workspace.json"), encoding="utf-8"))
    for panel in bundle["panels"].values():
        if isinstance(panel.get("content"), dict):
            _stamp_arrangements(panel["content"])
    return bundle["panels"]


def _overlap(a: dict, b: dict) -> bool:
    if a["w"] <= 0 or a["h"] <= 0 or b["w"] <= 0 or b["h"] <= 0:
        return False
    return not (
        a["x"] + a["w"] <= b["x"]
        or b["x"] + b["w"] <= a["x"]
        or a["y"] + a["h"] <= b["y"]
        or b["y"] + b["h"] <= a["y"]
    )


def _is_positioned(node: dict) -> bool:
    st = node.get("style")
    return isinstance(st, dict) and "position" in st


def _stamp_arrangements(node: dict, owner: str | None = None) -> None:
    """Stamp ``_arrangement`` on every node at or below a POSITIONED child
    (B.8): the path of the container that owns that arrangement. Leaves with
    the same stamp are composed together on purpose (the overlapping fill and
    stroke squares), so the overlap check exempts them from each other and
    from nothing else."""
    if owner is not None:
        node["_arrangement"] = owner
    for i, c in enumerate(node.get("children") or []):
        if isinstance(c, dict):
            here = owner
            if here is None and _is_positioned(c):
                here = node.get("_path", "")
            c["_path"] = f'{node.get("_path", "")}/{i}'
            _stamp_arrangements(c, here)


_PANEL_IDS = [
    pid
    for pid in _panels()
    if pid.endswith("_panel_content") and pid not in _EXCLUDED
]


@pytest.mark.parametrize("panel_id", _PANEL_IDS)
def test_panel_has_no_overlapping_leaves(panel_id):
    """No two leaf widgets in a panel overlap (avail_h=0 = what the dock draws)."""
    ctx = _load_ctx().get(panel_id.replace("_panel_content", ""), {})
    plan = render_plan(_panels()[panel_id], _PANEL_W, 0, ctx)
    overlaps = _overlapping_leaves(plan)
    assert not overlaps, f"{panel_id} has overlapping leaves:\n  " + "\n  ".join(overlaps)


def _overlapping_leaves(plan: dict) -> list[str]:
    leaves = plan["leaves"]
    out = []
    for i in range(len(leaves)):
        for j in range(i + 1, len(leaves)):
            ai = leaves[i]["node"].get("_arrangement")
            aj = leaves[j]["node"].get("_arrangement")
            if ai is not None and ai == aj:
                continue  # one positioned arrangement's own composition (B.8)
            ri, rj = leaves[i]["rect"], leaves[j]["rect"]
            if _overlap(ri, rj):
                ki = leaves[i]["node"].get("type", "?")
                kj = leaves[j]["node"].get("type", "?")
                out.append(f"{ki}{ri} X {kj}{rj}")
    return out


def _hide_resolved_false(node: dict, ctx: dict) -> int:
    """Set the literal ``visible: false`` the layout pass drops on every node
    whose ``visible`` / ``bind.visible`` expression resolves false in ``ctx``,
    as the plan's ``laid_out_node`` does (Rust ``panel_plan.rs``). Returns how
    many nodes it hid."""
    hidden = 0
    for c in node.get("children") or []:
        if not isinstance(c, dict):
            continue
        expr = c.get("visible")
        if not isinstance(expr, str):
            b = c.get("bind")
            expr = b.get("visible") if isinstance(b, dict) else None
        if isinstance(expr, str) and evaluate(expr, ctx).value is False:
            c["visible"] = False
            hidden += 1
            continue
        hidden += _hide_resolved_false(c, ctx)
    return hidden


def _color_modes() -> list[str]:
    menu = _panels()["color_panel_content"]["menu"]
    return [m["params"]["mode"] for m in menu
            if isinstance(m, dict) and m.get("action") == "set_color_panel_mode"]


@pytest.mark.parametrize("mode", _color_modes())
def test_color_panel_has_no_overlapping_leaves_in_each_mode(mode):
    """The colour panel as the plan lays it out: ONE mode group shown. With all
    five stacked, the sliders column was tall enough to hide the fill/stroke
    widget's overflow; with one shown, the hex row and colour bar overlapped
    its mode buttons (flask, live on the Windows dock, #363)."""
    assert len(_color_modes()) == 5, _color_modes()
    panel = _panels()["color_panel_content"]
    ctx = dict(_load_ctx().get("color", {}))
    ctx["panel"] = dict(ctx.get("panel") or {}, mode=mode)
    hid = _hide_resolved_false(panel["content"], ctx)
    assert hid == 4, f"expected the other four mode groups hidden, hid {hid}"
    overlaps = _overlapping_leaves(render_plan(panel, _PANEL_W, 0, ctx))
    assert not overlaps, f"color ({mode}) has overlapping leaves:\n  " + "\n  ".join(overlaps)


@pytest.mark.parametrize("panel_id", _PANEL_IDS)
def test_panel_leaves_within_width(panel_id):
    """No leaf extends past the panel width."""
    ctx = _load_ctx().get(panel_id.replace("_panel_content", ""), {})
    plan = render_plan(_panels()[panel_id], _PANEL_W, 0, ctx)
    over = [
        (lf["node"].get("type", "?"), lf["rect"])
        for lf in plan["leaves"]
        if lf["rect"]["w"] > 0 and lf["rect"]["x"] + lf["rect"]["w"] > _PANEL_W
    ]
    assert not over, f"{panel_id} has leaves past width {_PANEL_W}:\n  " + "\n  ".join(
        f"{k}{r}" for k, r in over
    )


# ── B.8's refusals: a position the pass would not honour ─────────────

_POSITION_PARENTS = ("container", "row", "col", "panel")


def _unhonoured_positions(node: dict, where: str = "") -> list[str]:
    """Every ``style.position`` the layout pass would NOT honour: one that is
    not two numbers, or one whose parent is not a plain container (a ``grid``,
    a ``foreach`` body or a ``disclosure`` does not read it). Either would sit
    silently in the flow, so the gate names it."""
    out = []
    kids = node.get("children") if isinstance(node.get("children"), list) else []
    bodies = [("do", node["do"])] if isinstance(node.get("do"), dict) else []
    for label, c in [(f"[{i}]", c) for i, c in enumerate(kids)] + bodies:
        if not isinstance(c, dict):
            continue
        st = c.get("style")
        if isinstance(st, dict) and "position" in st:
            pos = st["position"]
            ok_shape = (isinstance(pos, dict)
                        and all(isinstance(pos.get(k), (int, float))
                                and not isinstance(pos.get(k), bool) for k in ("x", "y")))
            ok_parent = (label != "do" and node.get("type") in _POSITION_PARENTS
                         and not isinstance(node.get("foreach"), dict))
            if not ok_shape:
                out.append(f"{where}{label}: position {pos!r} is not two numbers")
            if not ok_parent:
                out.append(f"{where}{label}: positioned under a {node.get('type')!r} that does not read position")
        out += _unhonoured_positions(c, f"{where}{label}")
    return out


def test_every_panel_position_is_one_the_pass_honours():
    found = []
    seen = 0
    for pid, panel in _panels().items():
        content = panel.get("content")
        if isinstance(content, dict):
            found += [f"{pid}{x}" for x in _unhonoured_positions(content)]
            seen += json.dumps(content).count('"position"')
    assert seen >= 10, f"only {seen} positions in the panels: the census is not reading them"
    assert not found, "positions the layout pass would not honour:\n  " + "\n  ".join(found)


def test_the_position_census_names_both_refusals():
    """CONTROL: a malformed position and one under a grid are both named."""
    bad = {"type": "container", "children": [
        {"type": "icon_button", "style": {"position": {"x": "50%", "y": 3}}},
        {"type": "grid", "children": [{"type": "icon_button", "style": {"position": {"x": 1, "y": 2}}}]},
    ]}
    got = _unhonoured_positions(bad)
    assert len(got) == 2, got
    assert "not two numbers" in got[0] and "'grid'" in got[1], got
