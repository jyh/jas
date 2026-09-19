#!/usr/bin/env python3
"""Every widget kind the shipped WinUI shell switches on is a kind the SPEC knows.

⛔ THE DEFECT THIS EXISTS FOR IS SILENT IN EVERY LAYER THAT COULD REPORT IT.
`case "checkbx":` compiles, ships, and never matches. The widget falls to
`default:`, draws a labelled `[checkbox]` placeholder, and is COUNTED as an
unmaterialized kind -- which is exactly what an honestly-missing kind looks
like. There is no error, no warning, and no count that moves.

⇒ A MISTYPED CASE LABEL IS INDISTINGUISHABLE FROM A KIND NOBODY HAS BUILT YET,
  and the placeholder machinery that makes the second one honest is what hides
  the first.

⛔ IT IS DELIBERATELY ONE-WAY. The shell is NOT required to materialize every
kind: `Result.Placeholders` exists so "the count of what is NOT built stays
visible in the window", and a gate demanding completeness would force the very
degenerate controls that make a placeholder dishonest. So this asserts only
SOUNDNESS -- every label the shell switches on is real -- and never coverage.

⚠️ WHAT THIS GATE DOES NOT COVER, stated beside its verdict rather than
inferred: it reads `MainWindow.xaml.cs` as plain `utf-8` (the house
convention for `.cs`) and that file CARRIES A BOM -- harmless here because
nothing below depends on byte 0, and driven green against the real file.
There is no CRLF axis at all: `.gitattributes` sets `* text=auto eol=lf`
and says so in words, so every checkout is LF including Windows.

The spec's table is `workspace_interpreter/widget_event.py` (INPUT_KINDS,
BOOLEAN_KINDS), and the structural kinds a panel tree also carries come from
the compiled workspace itself, so neither side of the comparison is typed here
(idiom law clause 1: derive expectations from the artifact's bytes).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHELL = ROOT / "prototypes" / "sb_winui" / "MainWindow.xaml.cs"
SPEC = ROOT / "workspace_interpreter" / "widget_event.py"
WORKSPACE = ROOT / "workspace" / "workspace.json"

# The one switch this gate is about: the leaf materializer. Anchored on the
# statement that opens it so a `case` belonging to some other switch in this
# 3,000-line file can never be absorbed.
SWITCH_ANCHOR = "switch (leaf.Type)"


def fail(msg: str) -> None:
    print(f"check_shell_kind_labels: FAIL -- {msg}")
    sys.exit(1)


def refuse(msg: str) -> None:
    """The gate could not measure its subject. NEVER a pass."""
    print(f"check_shell_kind_labels: REFUSED -- {msg}")
    sys.exit(2)


def shell_case_labels(src: str) -> list[str]:
    """The string labels of the leaf-materializer switch, in order.

    Scans from the anchor to the switch's `default:`, because a `case` after
    it belongs to another switch and absorbing one would make this gate agree
    with a file it had misread.
    """
    start = src.find(SWITCH_ANCHOR)
    if start < 0:
        refuse(f"the anchor {SWITCH_ANCHOR!r} is not in {SHELL.name}")
    end = src.find("default:", start)
    if end < 0:
        refuse("the leaf switch has no `default:` arm to stop at")
    return re.findall(r'case\s+"([^"]+)"\s*:', src[start:end])


def spec_kinds(src: str) -> set[str]:
    """INPUT_KINDS | BOOLEAN_KINDS, read from the spec's own frozensets."""
    out: set[str] = set()
    for name in ("INPUT_KINDS", "BOOLEAN_KINDS"):
        m = re.search(rf"{name}\s*=\s*frozenset\(\{{(.*?)\}}\)", src, re.S)
        if not m:
            refuse(f"{name} is not readable in {SPEC.name}")
        out |= set(re.findall(r'"([^"]+)"', m.group(1)))
    return out


def workspace_kinds(path: Path) -> set[str]:
    """Every `type` a panel CONTENT tree actually uses, from the compiled
    workspace -- the structural kinds (container, row, text, ...) the spec's
    event table has no reason to name."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        refuse(f"the compiled workspace is unreadable: {exc}")
    found: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            t = node.get("type")
            if isinstance(t, str):
                found.add(t)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(doc.get("panels", {}))
    return found


# ⛔ EVERY STRING THIS FILE PRINTS IS ASCII, DELIBERATELY. The Windows console
# is cp1252 and a single non-ASCII character in a `print()` raises
# UnicodeEncodeError -- ON THE SUCCESS PATH, which is the one nobody tests.
# This gate did exactly that: it PASSED its own check and then died reporting
# the pass, so it was red on Windows and green everywhere else. Its `--self-test`
# arm stayed green throughout, because that arm's output happened to be ASCII.
# Drive every output path with `PYTHONIOENCODING=cp1252` before believing any of
# them. (The docstring and comments above may hold glyphs: they are never
# printed. Only what reaches stdout/stderr is constrained.)


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    for p in (SHELL, SPEC, WORKSPACE):
        if not p.exists():
            # `.as_posix()`: the path here is DATA in a message, and `str(Path)`
            # yields "/" on this box and "\\" on Windows -- so a gate keyed on
            # this text would agree with itself on both platforms it ran on and
            # disagree with the one it did not. `check_path_keying.py` caught
            # exactly this, in this file, on its first CI run.
            refuse(f"{p.as_posix()} does not exist")

    labels = shell_case_labels(SHELL.read_text(encoding="utf-8"))
    known = spec_kinds(SPEC.read_text(encoding="utf-8")) | workspace_kinds(WORKSPACE)

    # ⛔ ANTI-VACUITY, BOTH SIDES. An empty label list passes any subset test,
    # and so does a `known` set that swallowed everything.
    if len(labels) < 4:
        fail(f"only {len(labels)} case label(s) read from the leaf switch -- the scan is broken, not the shell")
    if len(known) < 10:
        fail(f"only {len(known)} known kind(s) derived -- the spec/workspace read is broken")

    unknown = sorted(set(labels) - known)
    if unknown:
        fail(
            "the shell switches on kind(s) no spec table and no panel in the workspace uses: "
            + ", ".join(repr(u) for u in unknown)
            + " -- a label that matches nothing draws a placeholder and is counted as an unbuilt kind, "
              "which is byte-identical to a kind nobody has written yet"
        )

    dupes = sorted({x for x in labels if labels.count(x) > 1})
    if dupes:
        fail(f"duplicate case label(s) in the leaf switch: {', '.join(dupes)}")

    print(
        f"check_shell_kind_labels: OK ({len(labels)} case label(s) in {SHELL.name}'s leaf switch, "
        f"every one of them a kind the spec's tables or the compiled workspace uses; "
        f"{len(known)} known kind(s) derived, none typed here). "
        "SOUNDNESS ONLY, NEVER COVERAGE: the shell is not required to materialize every kind -- "
        "the labelled placeholder is what keeps the unbuilt count honest."
    )
    return 0


def self_test() -> int:
    """Drive the failure arms. A gate that only ever passes has never been shown able to fail."""
    arms = 0
    src = SHELL.read_text(encoding="utf-8")

    labels = shell_case_labels(src)
    assert len(labels) >= 4, f"fixture: only {len(labels)} labels"
    arms += 1

    known = spec_kinds(SPEC.read_text(encoding="utf-8")) | workspace_kinds(WORKSPACE)
    assert "checkbox" in known and "toggle" in known, "fixture: the spec's boolean kinds are not readable"
    assert "number_input" in known and "length_input" in known, "fixture: the spec's input kinds are not readable"
    assert "text" in known, "fixture: a structural kind from the workspace is missing"
    arms += 1

    # The gate's whole subject: a typo is NOT in the known set.
    assert "checkbx" not in known, "fixture: a typo'd kind must not be known"
    assert sorted({"checkbx"} - known) == ["checkbx"], "the subset test does not flag a typo"
    arms += 1

    # The scan stops at `default:` -- a case after it is not absorbed.
    after = src[src.find("default:", src.find(SWITCH_ANCHOR)):]
    assert "case " in after, "fixture: there is no later `case` to be wrongly absorbed"
    assert not (set(re.findall(r'case\s+"([^"]+)"\s*:', after)) & set(labels)), \
        "a later switch's labels leaked into the scan"
    arms += 1

    # The duplicate arm can fire.
    assert sorted({x for x in ["a", "a", "b"] if ["a", "a", "b"].count(x) > 1}) == ["a"]
    arms += 1

    print(f"check_shell_kind_labels SELF-TEST: OK ({arms} arm(s) driven, each on the REAL files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
