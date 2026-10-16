#!/usr/bin/env python3
"""No C# member in the WinUI shell carries two `/// <summary>` blocks.

When a member is inserted between another member's doc comment and that
member, the doc comment stays where it was: the new member then carries two
`<summary>` blocks (its own and the one that was displaced) and the member the
displaced one describes carries none. It compiles, nothing warns, and every
reader of the second member's doc is reading the first one's. It happened in
review twice in one evening (#452's `RemoveTab`, #465's `ApplyKey` and
`KeyWire`) and flask's census found four more (STATUS-flask 320).

The rule: after a line that closes a summary (`/// ... </summary>`), the next
line that is not blank and not another `///` doc line must not open a new
summary. A `///` line that opens one while a closed summary is still pending is
a finding, named `file:line` with both lines.

Population: every `*.cs` under `prototypes/sb_winui*/` (derived by walking,
never listed). The receipt counts the files and summary blocks examined, and a
run under the floor refuses: a walk that stopped finding files would otherwise
read as a clean zero.

NOT COVERED: a plain `//` comment between two summaries ends the pending
summary, so that shape passes; summaries outside `prototypes/sb_winui*/`.

    python3 scripts/check_cs_doc_summaries.py              # the gate
    python3 scripts/check_cs_doc_summaries.py --self-test  # can it fail?
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Measured on 2026-10-16: 9 files, 475 summary blocks. The floors sit well
# under that: they are MINIMUMS that prove the walk reached the population,
# never targets, and are raised by measurement, never to the count.
MIN_FILES = 5
MIN_SUMMARIES = 300


def scan_text(text: str) -> tuple[int, list[tuple[int, int, str]]]:
    """(summary blocks opened, findings) for one file's text. A finding is
    (closing line, opening line, the opening line's text), 1-based."""
    opened = 0
    findings: list[tuple[int, int, str]] = []
    pending: int | None = None
    for i, raw in enumerate(text.split("\n"), start=1):
        s = raw.strip()
        if s.startswith("///"):
            if "<summary>" in s:
                opened += 1
                if pending is not None:
                    findings.append((pending, i, s))
            if "</summary>" in s:
                pending = i
        elif s:
            pending = None
    return opened, findings


def files_under(root: str) -> list[str]:
    out = []
    proto = os.path.join(root, "prototypes")
    if not os.path.isdir(proto):
        return out
    for d in sorted(os.listdir(proto)):
        if not d.startswith("sb_winui"):
            continue
        for dirpath, dirnames, filenames in os.walk(os.path.join(proto, d)):
            dirnames[:] = sorted(n for n in dirnames if n not in ("bin", "obj"))
            out.extend(os.path.join(dirpath, f) for f in sorted(filenames) if f.endswith(".cs"))
    return out


def run(root: str, min_files: int = MIN_FILES, min_summaries: int = MIN_SUMMARIES) -> tuple[int, list[str]]:
    files = files_under(root)
    total = 0
    lines: list[str] = []
    for path in files:
        with open(path, encoding="utf-8-sig") as f:
            opened, findings = scan_text(f.read())
        total += opened
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        for closed, opens, text in findings:
            lines.append(f"{rel}:{opens}: a second <summary> (the first closes at line {closed}): {text}")
    if len(files) < min_files or total < min_summaries:
        print(f"check_cs_doc_summaries: REFUSED -- examined {len(files)} file(s) and {total} summary block(s), "
              f"under the floor ({min_files} files, {min_summaries} blocks): the walk did not reach its population")
        return 2, lines
    if lines:
        for line in lines:
            print(line)
        print(f"check_cs_doc_summaries: FAIL -- {len(lines)} member(s) carry two summaries "
              f"({len(files)} files, {total} summary blocks examined). Move the displaced summary down onto "
              "the member it describes, or delete it if it repeats the other.")
        return 1, lines
    print(f"check_cs_doc_summaries: OK ({len(files)} files, {total} summary blocks examined, 0 doubled). "
          "NOT COVERED: a plain // comment between two summaries; files outside prototypes/sb_winui*/.")
    return 0, lines


def self_test() -> int:
    cases = [
        ("two blocks, the shape #465 shipped",
         "/// <summary>\n/// A.\n/// </summary>\n/// <summary>\n/// B.\n/// </summary>\nvoid B() {}\n", [(3, 4)]),
        ("two one-line summaries",
         "    /// <summary>A.</summary>\n    /// <summary>B.</summary>\n    int B;\n", [(1, 2)]),
        ("a blank line between them",
         "/// <summary>A.</summary>\n\n/// <summary>B.</summary>\nint B;\n", [(1, 3)]),
        ("CRLF, as a Windows checkout holds it",
         "/// <summary>A.</summary>\r\n/// <summary>B.</summary>\r\nint B;\r\n", [(1, 2)]),
        ("param and returns after one summary are not a second",
         "/// <summary>A.</summary>\n/// <param name=\"x\">x</param>\n/// <returns>y</returns>\nint A(int x) => x;\n", []),
        ("an attribute between a summary and its member",
         "/// <summary>A.</summary>\n[DllImport(\"x\")]\nstatic extern int A();\n/// <summary>B.</summary>\nint B;\n", []),
        ("each member its own summary",
         "/// <summary>A.</summary>\nint A;\n/// <summary>B.</summary>\nint B;\n", []),
    ]
    failed = 0
    for name, text, want in cases:
        got = [(c, o) for c, o, _ in scan_text(text)[1]]
        ok = got == want
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}: {name} -- got {got} want {want}")
    # The gate end to end over a real directory: a planted double reds and
    # names the file and line; the floor refuses an empty population.
    with tempfile.TemporaryDirectory() as tmp:
        d = os.path.join(tmp, "prototypes", "sb_winui")
        os.makedirs(d)
        with open(os.path.join(d, "A.cs"), "w", encoding="utf-8-sig", newline="") as f:
            f.write("/// <summary>A.</summary>\r\n/// <summary>B.</summary>\r\nint B;\r\n")
        rc, lines = run(tmp, min_files=1, min_summaries=1)
        ok = rc == 1 and lines and lines[0].startswith("prototypes/sb_winui/A.cs:2:")
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}: a planted double reds and names prototypes/sb_winui/A.cs:2 -- rc {rc}")
        rc, _ = run(tmp)
        ok = rc == 2
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}: one file under the real floor is REFUSED, never OK -- rc {rc}")
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty)
        rc, _ = run(empty, min_files=1, min_summaries=1)
        ok = rc == 2
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}: no prototypes/ at all is REFUSED -- rc {rc}")
    n = len(cases) + 3
    print(f"check_cs_doc_summaries SELF-TEST: {'OK' if not failed else 'FAIL'} ({n - failed} of {n} arms)")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    return run(ROOT)[0]


if __name__ == "__main__":
    sys.exit(main())
