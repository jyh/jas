#!/usr/bin/env python3
"""Widget event contract gate (WIDGET_EVENTS.md).

WHY THIS EXISTS
---------------
`schema/widget.schema.json` types a behavior's `event` as a free string, and
until WIDGET_EVENTS.md nothing said which events a value widget raises. Three
executors of the panel YAML (Rust, Swift, and the engine's panel door) each
guessed, and the guesses differ. The contract is now written down once, in
`workspace_interpreter/widget_event.py` (ALLOWED_EVENTS), and this gate holds
two other copies of it to that one:

  1. THE YAML. Every behavior on one of the eight value kinds names an event
     the contract lists for that kind. A `number_input` with `event: click`,
     or a `toggle` with `event: commit`, is a behavior no executor will run
     the same way twice.
  2. THE DOCUMENT. WIDGET_EVENTS.md carries the table between its
     `widget-event-table` markers, for readers. It must say exactly what the
     module says, kind for kind and event for event, in order.

WHAT IT ASSERTS
---------------
* Over every `*.yaml` under `workspace/`: for each mapping whose `type` is a
  value kind and which carries `behavior`, the behavior is a list; each entry
  is a mapping with a string `event`; and that event is listed for the kind.
  A malformed entry is a FINDING, never a skip: a shape the gate cannot read
  is exactly where an unrun behavior hides.
* The document's table equals ALLOWED_EVENTS.
* The conforming entry count is DERIVED from the walk and printed. It is
  never compared to a typed number.

WHAT IT DOES NOT COVER, and why
-------------------------------
* It reads LOADED dicts, so a mapping with two `behavior:` keys has already
  lost one. Duplicate keys are `check_workspace_ids.py`'s subject.
* A widget whose `type` is a template placeholder (`${kind}`) is not a value
  kind to this gate. None exists today.
* Every other widget kind is outside the contract (WIDGET_EVENTS.md says why),
  and its events are not checked here.
* It checks the VOCABULARY. What an event does is the module's, and
  `workspace_interpreter/tests/test_widget_event.py` is what tests that.

WHY --self-test EXISTS
----------------------
An event census is a count, and a count has no failure mode: a walk that
found nothing reports no findings. So the self-test first proves the gate
REFUSES an empty population, a population smaller than git's index, an
unparseable file, a population with a value kind missing, and a document
without its table. Only then does it prove a clean fixture is green with the
count the fixture was BUILT to have, and that each planted violation turns it
red. The live run repeats the non-emptiness checks against the real tree.

Run `python scripts/check_widget_event_contract.py`; `--self-test` proves the
gate can still go red.
"""

import argparse
import ast
import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from workspace_interpreter.widget_event import ALLOWED_EVENTS  # noqa: E402

DOCUMENT = ROOT / "WIDGET_EVENTS.md"
TABLE_BEGIN = "<!-- widget-event-table:begin -->"
TABLE_END = "<!-- widget-event-table:end -->"


class Refusal(Exception):
    """The gate cannot judge. Never reported as a clean tree."""


# -- the population ---------------------------------------------------------

def tracked_yaml(root: pathlib.Path) -> set:
    """The workspace YAML files git knows about, as POSIX relative paths.

    A second oracle for the filesystem walk: a walk that silently lost files
    would otherwise report a clean, smaller tree."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--", "workspace"],
        capture_output=True, text=True, encoding="utf-8", check=False)
    if out.returncode != 0:
        raise Refusal("git ls-files failed: " + out.stderr.strip())
    return {p for p in out.stdout.splitlines() if p.endswith(".yaml")}


def walk_files(root: pathlib.Path) -> list:
    base = root / "workspace"
    return sorted(p.relative_to(root).as_posix() for p in base.rglob("*.yaml"))


def load(root: pathlib.Path, files: list) -> list:
    """[(relpath, document)]; refuses on any file it cannot parse."""
    docs = []
    for rel in files:
        text = (root / rel).read_text(encoding="utf-8")
        try:
            docs.append((rel, yaml.safe_load(text)))
        except yaml.YAMLError as e:
            raise Refusal(f"{rel}: unparseable YAML ({type(e).__name__})")
    return docs


# -- the census -------------------------------------------------------------

def census(docs: list, table: dict):
    """Walk every document. Returns (findings, conforming, widgets_per_kind).

    `conforming` counts behavior entries whose event the table allows;
    `widgets_per_kind` counts every widget of each value kind, with or
    without behaviors, so a kind that vanished from the tree is visible."""
    findings = []
    conforming = {kind: 0 for kind in table}
    widgets = {kind: 0 for kind in table}

    def visit(node, rel):
        if isinstance(node, dict):
            kind = node.get("type")
            if isinstance(kind, str) and kind in table:
                widgets[kind] += 1
                if "behavior" in node:
                    check(node, kind, rel)
            for value in node.values():
                visit(value, rel)
        elif isinstance(node, list):
            for value in node:
                visit(value, rel)

    def check(node, kind, rel):
        wid = node.get("id") if isinstance(node.get("id"), str) else "<no id>"
        behaviors = node["behavior"]
        if not isinstance(behaviors, list):
            findings.append((rel, wid, kind, "behavior is not a list"))
            return
        for i, entry in enumerate(behaviors):
            if not isinstance(entry, dict):
                findings.append((rel, wid, kind, f"behavior[{i}] is not a mapping"))
                continue
            event = entry.get("event")
            if not isinstance(event, str):
                findings.append((rel, wid, kind, f"behavior[{i}] has no string event"))
            elif event not in table[kind]:
                findings.append((rel, wid, kind,
                                 f"event '{event}' is not one of {', '.join(table[kind])}"))
            else:
                conforming[kind] += 1

    for rel, doc in docs:
        visit(doc, rel)
    return findings, conforming, widgets


# -- the document -----------------------------------------------------------

def document_table(text: str) -> dict:
    """Parse the table between the markers; refuses if it cannot find ONE."""
    if text.count(TABLE_BEGIN) != 1 or text.count(TABLE_END) != 1:
        raise Refusal("WIDGET_EVENTS.md must carry exactly one table between "
                      f"'{TABLE_BEGIN}' and '{TABLE_END}'")
    body = text.split(TABLE_BEGIN, 1)[1].split(TABLE_END, 1)[0]
    table = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("```"):
            continue
        kind, sep, events = line.partition(":")
        kind = kind.strip()
        if not sep or not kind:
            raise Refusal(f"WIDGET_EVENTS.md table line is not 'kind: events': {line!r}")
        if kind in table:
            raise Refusal(f"WIDGET_EVENTS.md table names '{kind}' twice")
        table[kind] = tuple(e.strip() for e in events.split(",") if e.strip())
    if not table:
        raise Refusal("WIDGET_EVENTS.md table is empty")
    return table


def table_differences(doc: dict, module: dict) -> list:
    out = []
    for kind in sorted(set(doc) | set(module)):
        if kind not in module:
            out.append(f"the document lists '{kind}', which the module does not")
        elif kind not in doc:
            out.append(f"the module lists '{kind}', which the document does not")
        elif doc[kind] != tuple(module[kind]):
            out.append(f"'{kind}': document says {', '.join(doc[kind])}; "
                       f"module says {', '.join(module[kind])}")
    return out


# -- the gate ---------------------------------------------------------------

def run(root: pathlib.Path, table: dict, doc_text: str, tracked: set):
    """Returns (findings, report). Raises Refusal when it cannot judge."""
    files = walk_files(root)
    if not files:
        raise Refusal("no workspace YAML files found")
    missing = sorted(tracked - set(files))
    if missing:
        raise Refusal(f"{len(missing)} tracked YAML file(s) not found by the "
                      f"walk, first {missing[0]}")
    findings, conforming, widgets = census(load(root, files), table)
    absent = sorted(k for k, n in widgets.items() if n == 0)
    if absent:
        raise Refusal("no widget of kind " + ", ".join(absent) + " anywhere; a "
                      "renamed kind would exempt itself silently")
    if sum(conforming.values()) == 0 and not findings:
        raise Refusal("no behavior on any value kind; the census read nothing")
    findings = findings + [("WIDGET_EVENTS.md", "-", "-", d) for d in
                           table_differences(document_table(doc_text), table)]
    return findings, {"files": len(files), "conforming": conforming,
                      "widgets": widgets}


def main_live() -> int:
    try:
        findings, report = run(ROOT, ALLOWED_EVENTS,
                               DOCUMENT.read_text(encoding="utf-8"),
                               tracked_yaml(ROOT))
    except Refusal as e:
        print(f"check_widget_event_contract: REFUSED: {e}")
        return 2
    if findings:
        print(f"check_widget_event_contract: FAIL: {len(findings)} finding(s)")
        for rel, wid, kind, why in findings:
            print(f"  {rel}  {wid} ({kind}): {why}")
        print("  The table is workspace_interpreter/widget_event.py ALLOWED_EVENTS; "
              "WIDGET_EVENTS.md says what each event means.")
        return 1
    total = sum(report["conforming"].values())
    per_kind = ", ".join(f"{k} {report['conforming'][k]}"
                         for k in sorted(report["conforming"]))
    print(f"check_widget_event_contract: PASS: {total} behavior entries on "
          f"{len(report['widgets'])} value kinds conform, across "
          f"{report['files']} workspace YAML files ({per_kind}); the "
          "WIDGET_EVENTS.md table equals the module's.")
    print("  LIMITS: checks event NAMES only, not what they do (that is "
          "test_widget_event.py); reads loaded dicts, so a duplicated "
          "behavior: key is check_workspace_ids.py's; other widget kinds are "
          "outside the contract.")
    return 0


# -- the self-test ----------------------------------------------------------

def _fixture(root: pathlib.Path, files: dict, doc: str):
    for rel, body in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8", newline="")
    return doc


def _yaml_widgets(widgets: list) -> str:
    return yaml.safe_dump({"id": "p", "type": "panel", "content": {
        "type": "container", "children": widgets}}, sort_keys=False)


def _doc_for(table: dict) -> str:
    lines = [f"{k}: {', '.join(v)}" for k, v in table.items()]
    return "\n".join(["# t", TABLE_BEGIN, "```", *lines, "```", TABLE_END, ""])


def self_test() -> int:
    failures = []
    arms = 0

    def arm(name, ok):
        nonlocal arms
        arms += 1
        if not ok:
            failures.append(name)
            print(f"  FAILED: {name}")

    table = {k: tuple(v) for k, v in ALLOWED_EVENTS.items()}
    arm("the module table is not empty", len(table) == 8)
    # One widget per (kind, event): the count this fixture is BUILT to have.
    clean = [{"type": k, "id": f"{k}_{e}", "behavior": [{"event": e, "effects": []}]}
             for k, events in table.items() for e in events]
    built = len(clean)
    arm("the clean fixture has a behavior for every table cell",
        built == sum(len(v) for v in table.values()) and built > 8)
    outside = {"type": "icon_button", "id": "ib",
               "behavior": [{"event": "mouse_down"}, {"event": "anything"}]}

    def attempt(widgets, doc=None, extra=None, tracked=None):
        """("judged", findings, report) or ("refused", message)."""
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            (root / "workspace").mkdir()
            files = {"workspace/panels/p.yaml": _yaml_widgets(widgets)} \
                if widgets is not None else {}
            files.update(extra or {})
            _fixture(root, files, "")
            rels = set(files) if tracked is None else tracked
            try:
                return ("judged",) + run(
                    root, table, _doc_for(table) if doc is None else doc, rels)
            except Refusal as e:
                return ("refused", str(e))

    def gate(widgets, **kw):
        """A judgement, or an arm failure naming the refusal. A refusal here
        must fail the ARM, never escape as a traceback, or the arm that
        should have caught a mutant is not the thing that caught it."""
        got = attempt(widgets, **kw)
        if got[0] == "refused":
            arm("a fixture expected to be JUDGED was judged (refused: "
                + got[1] + ")", False)
            return [("<refused>", "<refused>", "-", got[1])], {
                "conforming": {}, "widgets": {}}
        return got[1], got[2]

    def refuses(because, **kw):
        """True only for a refusal whose message names `because`: two
        refusals can fire on one fixture, and the arm must see its own."""
        got = attempt(**kw)
        return got[0] == "refused" and because in got[1]

    # Refusals first: a gate that cannot measure must never read as clean.
    arm("an empty population REFUSES",
        refuses("no workspace YAML files", widgets=None, tracked=set()))
    arm("a tracked file the walk did not find REFUSES",
        refuses("not found by the walk", widgets=clean,
                tracked={"workspace/panels/p.yaml", "workspace/panels/gone.yaml"}))
    arm("an unparseable file REFUSES",
        refuses("unparseable YAML", widgets=clean,
                extra={"workspace/panels/bad.yaml": "a: [1, 2\n"}))
    arm("a value kind with no widget anywhere REFUSES",
        refuses("no widget of kind toggle anywhere",
                widgets=[w for w in clean if w["type"] != "toggle"]))
    arm("a tree with no behavior on any value kind REFUSES",
        refuses("census read nothing", widgets=[{"type": k} for k in table]))
    arm("a document with no table REFUSES",
        refuses("exactly one table", widgets=clean, doc="# t\n"))
    arm("a document with two tables REFUSES",
        refuses("exactly one table", widgets=clean, doc=_doc_for(table) * 2))
    arm("a table line with no colon REFUSES",
        refuses("is not 'kind: events'", widgets=clean,
                doc=_doc_for(table).replace("toggle: click, change",
                                            "toggle click, change")))
    arm("a table naming a kind twice REFUSES",
        refuses("names 'toggle' twice", widgets=clean,
                doc=_doc_for(table).replace("checkbox:", "toggle:")))
    arm("an empty table REFUSES",
        refuses("table is empty", widgets=clean,
                doc="\n".join([TABLE_BEGIN, "```", "```", TABLE_END])))

    # Green.
    findings, report = gate(clean + [outside])
    arm("the clean fixture is GREEN", findings == [])
    arm("the clean fixture's count is the count it was built to have",
        sum(report["conforming"].values()) == built)
    arm("every kind was seen", all(n >= 1 for n in report["widgets"].values()))

    # Red, one planted violation at a time.
    for kind in table:
        foreign = next(e for e in ("keydown", "click", "commit", "bogus")
                       if e not in table[kind])
        bad = clean + [{"type": kind, "id": "x",
                        "behavior": [{"event": foreign}]}]
        f, _ = gate(bad)
        arm(f"{kind} with event '{foreign}' is RED",
            len(f) == 1 and f[0][1] == "x" and f"'{foreign}'" in f[0][3])
    nested = clean + [{"type": "container", "children": [{"foreach": {}, "do": {
        "type": "number_input", "id": "deep", "behavior": [{"event": "input"}]}}]}]
    f, _ = gate(nested)
    arm("a violation nested under foreach/do is RED",
        [x[1] for x in f] == ["deep"])
    for label, behavior in (("behavior not a list", {"event": "commit"}),
                            ("an entry not a mapping", ["commit"]),
                            ("an entry with no event", [{"effects": []}]),
                            ("an entry with a non-string event", [{"event": 1}])):
        f, _ = gate(clean + [{"type": "select", "id": "m", "behavior": behavior}])
        arm(f"{label} is RED, not skipped", [x[1] for x in f] == ["m"])
    mixed = clean + [{"type": "toggle", "id": "two", "behavior": [
        {"event": "click"}, {"event": "commit"}, {"event": "change"}]}]
    f, rep = gate(mixed)
    arm("one bad entry among good ones is exactly one finding, and the good "
        "ones still count",
        len(f) == 1 and sum(rep["conforming"].values()) == built + 2)

    # The document must equal the module, in order.
    for label, doc in (
            ("an event missing from the document",
             _doc_for(table).replace("toggle: click, change", "toggle: click")),
            ("an event added to the document",
             _doc_for(table).replace("\nselect: commit, change\n",
                                     "\nselect: commit, change, click\n")),
            ("two events swapped in the document",
             _doc_for(table).replace("checkbox: click, change",
                                     "checkbox: change, click")),
            ("a kind missing from the document",
             _doc_for({k: v for k, v in table.items() if k != "combo_box"})),
            ("a kind the module does not have",
             _doc_for({**table, "slider": ("change",)}))):
        # A replace anchor that hits two lines (`select:` is inside
        # `icon_select:`) mutates twice; count the changed lines.
        changed = set(doc.splitlines()) ^ set(_doc_for(table).splitlines())
        mutated = 1 <= len(changed) <= 2
        f, _ = gate(clean, doc=doc)
        arm(f"{label} is RED (and the mutation happened)",
            mutated and len(f) == 1 and f[0][0] == "WIDGET_EVENTS.md")

    # Every string this gate prints must survive the Windows lane's cp1252
    # console. Docstrings are exempt because nothing prints them.
    tree = ast.parse(pathlib.Path(__file__).read_text(encoding="utf-8"))
    docstrings = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)):
            b = n.body
            if (b and isinstance(b[0], ast.Expr) and isinstance(b[0].value, ast.Constant)
                    and isinstance(b[0].value.value, str)):
                docstrings.add(id(b[0].value))
    strings = [n for n in ast.walk(tree)
               if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    bad = []
    for n in strings:
        if id(n) in docstrings:
            continue
        try:
            n.value.encode("cp1252")
        except UnicodeEncodeError:
            bad.append(n.lineno)
    arm("every printed string survives a cp1252 console", not bad)
    arm("that console arm read this file's strings", len(strings) > 50)

    if failures:
        print(f"check_widget_event_contract SELF-TEST: FAILED {len(failures)} "
              f"of {arms} arm(s)")
        return 1
    print(f"check_widget_event_contract SELF-TEST: PASSED {arms} arm(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    return self_test() if args.self_test else main_live()


if __name__ == "__main__":
    sys.exit(main())
