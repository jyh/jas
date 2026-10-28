"""Every action dispatch in the workspace passes only params its action
declares, and every `param.X` an action reads is declared.

#746 put the first half on the panels' `keyboard:` rows after the Layers F2 and
Enter rows were found passing `element_id` to `rename_element`, which declares
`path`. Menu rows, context menus, shortcuts, dialog buttons and widget
behaviours pass params the same way, and nothing checked them (bank
2026-10-28). The census on 2026-10-28 read 231 such sites across 23 files and
found two defects: the Symbols orphan dialog's Delete passed `master` to
`delete_symbol_orphan_confirm_ok`, whose effects read `param.master` and
which declared no params; and the Layers context menu's isolation row passes
`container_id` to both branches of its template.
"""

import os
import re

import pytest

from workspace_interpreter.loader import load_workspace

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(scope="module")
def ws():
    return load_workspace(os.path.join(REPO_ROOT, "workspace"))


def action_names(raw):
    """The actions a dispatch's `action` can name: the string itself, or each
    quoted branch of a `{{ ... }}` template."""
    if "{{" in raw:
        return re.findall(r"'([a-z_0-9]+)'", raw)
    return [raw]


def dispatch_sites(node, where=()):
    """Every mapping that names an `action` (a string) and passes `params` (a
    mapping), with where it sits."""
    if isinstance(node, dict):
        if isinstance(node.get("action"), str) and isinstance(node.get("params"), dict):
            yield where, node
        for k, v in node.items():
            yield from dispatch_sites(v, where + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from dispatch_sites(v, where + (str(i),))


def undeclared_passes(ws_data):
    """A site passing a param no action it can name declares. A template's
    branches share one params map, so a param need only be declared by ONE of
    them: the Layers isolation row passes `container_id`, which enter reads and
    exit ignores. A param no branch declares is still caught, which is the
    F2 shape (one branch, the wrong name)."""
    actions = ws_data["actions"]
    bad = []
    for where, site in dispatch_sites(ws_data):
        names = action_names(site["action"])
        if not names:
            bad.append(f"{'/'.join(where)}: no action name in {site['action']!r}")
            continue
        missing = [n for n in names if n not in actions]
        if missing:
            bad.append(f"{'/'.join(where)}: no action {missing}")
            continue
        declared = set()
        for n in names:
            declared |= set((actions[n].get("params") or {}).keys())
        for p in site["params"]:
            if p not in declared:
                bad.append(f"{'/'.join(where)}: {names} declare {sorted(declared)}, the site passes {p!r}")
    return bad


def undeclared_reads(actions):
    """An action whose effects (or enabled_when, or any field but its
    description and its params table) read `param.X` without declaring X."""
    bad = []
    for name, spec in actions.items():
        declared = set((spec.get("params") or {}).keys())
        body = repr({k: v for k, v in spec.items() if k not in ("description", "params")})
        for read in sorted(set(re.findall(r"\bparam\.([a-z_][a-z_0-9]*)", body)) - declared):
            bad.append(f"{name}: reads param.{read}, declares {sorted(declared)}")
    return bad


def test_every_dispatch_site_passes_only_declared_params(ws):
    sites = list(dispatch_sites(ws))
    # Positive control on the population, not merely non-zero: 231 on
    # 2026-10-28, and the keyboard rows #746 already gated are among them.
    assert len(sites) >= 200, f"only {len(sites)} dispatch sites: the walk lost a surface"
    assert any(s.get("action") == "rename_element" and "path" in s["params"] for _, s in sites), \
        "the Layers F2 row is not in the population"
    assert not (bad := undeclared_passes(ws)), "\n".join(bad)


def test_every_param_an_action_reads_is_declared(ws):
    actions = ws["actions"]
    reads = sum(len(re.findall(r"\bparam\.", repr(a))) for a in actions.values())
    assert reads >= 250, f"only {reads} param reads: the scan lost the effects"
    assert not (bad := undeclared_reads(actions)), "\n".join(bad)


# The checks against planted defects, so a green above is about the workspace
# and not about a checker that cannot fail.

_ACTIONS = {
    "rename_element": {"params": {"path": {}}, "effects": [{"set": "param.path"}]},
    "enter_iso": {"params": {"container_id": {}}},
    "exit_iso": {"effects": [{"pop": "panel.isolation_stack"}]},
}


def _ws(site):
    return {"actions": _ACTIONS, "panels": {"p": {"menu": [site]}}}


def test_a_param_its_action_does_not_declare_is_caught():
    bad = undeclared_passes(_ws({"action": "rename_element", "params": {"element_id": "x"}}))
    assert len(bad) == 1 and "'element_id'" in bad[0]
    assert undeclared_passes(_ws({"action": "rename_element", "params": {"path": "x"}})) == []


def test_a_template_needs_one_branch_to_declare_each_param():
    shared = "{{if c then 'exit_iso' else 'enter_iso'}}"
    assert undeclared_passes(_ws({"action": shared, "params": {"container_id": "x"}})) == []
    bad = undeclared_passes(_ws({"action": shared, "params": {"containr_id": "x"}}))
    assert len(bad) == 1 and "'containr_id'" in bad[0]


def test_a_missing_action_is_caught():
    bad = undeclared_passes(_ws({"action": "no_such", "params": {}}))
    assert len(bad) == 1 and "no action" in bad[0]


def test_a_read_of_an_undeclared_param_is_caught():
    actions = {"a": {"effects": [{"x": "param.master"}]},
               "b": {"params": {"master": {}}, "effects": [{"x": "param.master"}]},
               "c": {"description": "mentions param.master in prose only"}}
    assert undeclared_reads(actions) == ["a: reads param.master, declares []"]
