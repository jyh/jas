"""No widget names its icon with a `{{...}}` template.

The 10-30 Windows feel sitting, finding 4: the Layers row's eye, lock and twirl
drew as TEXT on Windows. Their `icon:` was a template, and the engine's plan
withholds a templated display string by design (`panel_plan.rs`), so the shell
never received a name. A changing icon is a `bind: { icon: <expr> }`, which the
plan resolves and every shell draws. This walks every workspace YAML, so a new
templated icon fails here before it reaches a shell that cannot draw it.
"""

from __future__ import annotations

import os

import yaml

_WORKSPACE = os.path.join(os.path.dirname(__file__), "..", "..", "workspace")


def _icons(node, where, out):
    if isinstance(node, dict):
        icon = node.get("icon")
        if isinstance(icon, str):
            out.append((where, node.get("id", "?"), icon))
        for k, v in node.items():
            _icons(v, where, out)
    elif isinstance(node, list):
        for v in node:
            _icons(v, where, out)


def _all_icons():
    out = []
    for root, _dirs, files in os.walk(_WORKSPACE):
        for f in sorted(files):
            if f.endswith(".yaml"):
                path = os.path.join(root, f)
                with open(path, encoding="utf-8") as fh:
                    _icons(yaml.safe_load(fh), os.path.relpath(path, _WORKSPACE), out)
    return out


def test_the_walk_reads_icons():
    """Anti-vacuity: the walk must find the shipped static icons it is
    checking, or a broken walk would pass the test below."""
    assert len(_all_icons()) >= 50


def test_no_icon_is_a_template():
    bad = [f"{w}:{i}: {icon}" for w, i, icon in _all_icons() if "{{" in icon]
    assert bad == [], "templated icon(s); use bind: { icon: <expr> }:\n" + "\n".join(bad)
