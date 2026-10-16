#!/usr/bin/env python3
"""Every function an expression in workspace/ CALLS is one the evaluator defines.

A call to a name the evaluator does not know evaluates to null, SILENTLY, in
every port. `artboard.yaml` read `len(active_document.artboards_panel_selection_ids)
> 0` for months: `len` is no function anywhere (the language says `x.length`),
so the condition was always false and the Artboard tool's Delete never ran its
branch, and the same `len(...)` hid the resize-handle overlay (jas, 2026-10-15,
PR #460). `check_state_reads` checks that an expression PARSES and that its
namespace heads exist; it does not look at calls. This gate does.

The defined set is DERIVED from the reference evaluator
(`workspace_interpreter/expr_eval.py`), the spec's executable meaning, never
typed here: the `if name == "x"` arms, the `name in ("a", "b")` arms, and the
keys of `_COLOR_DECOMPOSE`. A name bound by `fun` or `let` inside the same
expression is a local and is not refused. `__apply__` (calling a computed
value) is the parser's own form.

What is examined: every string scalar under workspace/ (YAML, the source of
truth, not the compiled workspace.json) that contains `<identifier>(` and
parses as an expression, minus prose keys (description, summary, label, ...)
and minus CSS: every `style:` subtree and `theme.yaml`, whose `rgba(...)` and
`var(--...)` are CSS functions a renderer reads, not expressions.
A string that does not parse is NOT judged here (`check_state_reads` owns
parse failures for the strings that read state). The receipt counts what was
examined, and a run that examined fewer calls than the floor refuses: a parse
that stopped matching would otherwise read as a clean zero.

    python3 scripts/check_expr_functions.py              # the gate
    python3 scripts/check_expr_functions.py --self-test  # can it fail?
"""
from __future__ import annotations

import argparse
import dataclasses
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from workspace_interpreter import expr_eval  # noqa: E402
from workspace_interpreter.expr_parser import FuncCall, Lambda, Let, parse  # noqa: E402

CSS_KEYS = {"style"}
CSS_FILES = {"theme.yaml"}
PROSE_KEYS = {"description", "summary", "label", "tooltip", "comment", "menu_label",
              "title", "help", "placeholder", "notes", "text", "message", "caption"}
CALL_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\(")
# The floor: calls examined in the live tree on 2026-10-15 were well above
# this. It is a MINIMUM that proves the walk reached the population, never a
# target; raise it by measurement, never to the count.
MIN_CALLS = 100


def defined_functions() -> set[str]:
    """The reference evaluator's function names, read from its own source and
    its own table."""
    src = open(expr_eval.__file__, encoding="utf-8").read()
    names = set(re.findall(r'\bname == "([A-Za-z_][A-Za-z0-9_]*)"', src))
    for group in re.findall(r"\bname in \(([^)]*)\)", src):
        names.update(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', group))
    names.update(expr_eval._COLOR_DECOMPOSE.keys())
    names.add("__apply__")
    return names


def calls(node, bound: frozenset, out: list) -> None:
    """Every FuncCall name in `node` not bound by an enclosing fun/let."""
    if isinstance(node, Lambda):
        calls(node.body, bound | frozenset(node.params), out)
        return
    if isinstance(node, Let):
        calls(node.value, bound, out)
        calls(node.body, bound | {node.name}, out)
        return
    if isinstance(node, FuncCall) and node.name not in bound:
        out.append(node.name)
    if dataclasses.is_dataclass(node):
        for f in dataclasses.fields(node):
            calls(getattr(node, f.name), bound, out)
    elif isinstance(node, (list, tuple)):
        for item in node:
            calls(item, bound, out)


def scan(root_dir: str):
    """(examined_calls, findings) over every YAML file under `root_dir`."""
    known = defined_functions()
    examined, findings = 0, []

    def walk(node, rel, keypath):
        nonlocal examined
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(k, str) and (k in PROSE_KEYS or k in CSS_KEYS):
                    continue
                walk(v, rel, f"{keypath}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, rel, f"{keypath}[{i}]")
        elif isinstance(node, str) and CALL_RE.search(node):
            texts = re.findall(r"\{\{(.*?)\}\}", node) if "{{" in node else [node]
            for text in texts:
                try:
                    ast = parse(text.strip())
                except Exception:
                    continue
                found: list = []
                calls(ast, frozenset(), found)
                examined += len(found)
                for name in found:
                    if name not in known:
                        findings.append(f"{rel}{keypath}: `{name}(...)` is no function "
                                        f"the evaluator defines: {text.strip()!r}")

    for dirpath, _, files in os.walk(root_dir):
        for fn in sorted(files):
            if not fn.endswith((".yaml", ".yml")) or fn in CSS_FILES:
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as f:
                try:
                    doc = yaml.safe_load(f)
                except yaml.YAMLError:
                    continue
            walk(doc, rel, "")
    return examined, findings


def self_test() -> int:
    import tempfile
    failures = []
    known = defined_functions()
    for must in ("filter", "map", "hsb_h", "rgb", "brush_type_of"):
        if must not in known:
            failures.append(f"derived set lacks a function the evaluator defines: {must}")
    if "len" in known:
        failures.append("derived set claims `len`, which the evaluator does not define")
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "t.yaml"), "w", encoding="utf-8", newline="") as f:
            f.write('a:\n  if: "len(x.items) > 0"\n'
                    'b:\n  if: "filter(x, fun i -> i.y == 1)[0].z"\n'
                    'c:\n  set: "let f = fun v -> v in f(1)"\n'
                    'd:\n  description: "count (len(of) things)"\n'
                    'e:\n  value: "{{ nope(1) }} and {{ hsb_h(c) }}"\n'
                    'f:\n  style: { color: "var(--x, #888)" }\n')
        with open(os.path.join(d, "theme.yaml"), "w", encoding="utf-8", newline="") as f:
            f.write('c:\n  shadow: "rgba(0,0,0,0.3)"\n')
        examined, findings = scan(d)
        if examined != 4:
            failures.append(f"examined {examined} calls, expected exactly 4 "
                            "(len, filter, nope, hsb_h; the let-bound f, the prose and the CSS skipped)")
        names = sorted(re.findall(r"`([a-z_]+)\(", " ".join(findings)))
        if names != ["len", "nope"]:
            failures.append(f"found {names}, expected exactly ['len', 'nope'] "
                            "(the interpolated `nope` is found; CSS and prose are not)")
    if failures:
        print("SELF-TEST FAILED -- the gate does not read what it claims:")
        print("\n".join(f"  {x}" for x in failures))
        return 1
    print(f"self-test: OK ({len(known)} defined functions derived; a planted `len(` "
          "and an interpolated call are found; a let-bound call, prose and CSS are not)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    examined, findings = scan(os.path.join(ROOT, "workspace"))
    if examined < MIN_CALLS:
        print(f"ERROR: examined {examined} calls, below the floor {MIN_CALLS}: "
              "the walk did not reach the population, and a clean zero would be a lie.")
        return 1
    if findings:
        print(f"FAIL: {len(findings)} call(s) to a function the evaluator does not define:")
        print("\n".join(f"  {x}" for x in findings))
        return 1
    print(f"check_expr_functions: OK ({examined} calls examined across workspace/*.yaml, "
          f"every one to a function the reference evaluator defines; strings that do not "
          f"parse are not judged here)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
