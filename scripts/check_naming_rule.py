#!/usr/bin/env python3
"""Enforce the house naming rule, with its documented exemptions.

THE RULE (POLICY.md section 5, standing): the incumbent vector-illustration
products are never named in the code, the schema, or any documentation. The
preferred term is "vector illustration application", or "the incumbent" when a
comparative claim genuinely needs a referent.

WHY THIS CHECK EXISTS: the rule was silently broken on PUBLIC main for an
unknown length of time -- 18 occurrences across 9 files, found on 2026-07-27
only because a pre-push audit happened to grep for it. A rule that depends on
everyone remembering it is not a rule; it is a hope. Eleven spec documents were
swept the same day. This gate is what stops the twelfth from appearing.

SCOPE: git-tracked text files. Tracking is the honest definition of "what this
project authors" -- it excludes build trees and vendored dependencies by
construction rather than by a hand-maintained skip list, which is the kind of
list that rots. (Measured: `jas_ocaml/_build/` and `jas_flask/.venv/` between
them hold dozens of matches and not one line of them was written here.)

FOUR EXEMPTION CLASSES, each deliberate:

  1. transcripts/TRANSCRIPT.md -- AN ARCHIVE. It records, verbatim, the prompts
     that started this project, including the founding instruction naming the
     product to imitate. Rewriting a quoted historical record would FALSIFY it,
     which is a categorically different act from honouring a naming rule in a
     live spec. JYH ruled 2026-07-27: leave the archive as-is. The file also
     carries its own protection in its header ("Claude, do not modify this
     file."), so it is doubly out of bounds. An archive edited to look tidier is
     worth less than one that is honest about where the project began.

  2. article/ -- PROSE ANALYSIS, where naming products is allowed and sometimes
     necessary to make a comparative argument.

  3. jas_ocaml/ and jas/ -- THE FROZEN PORTS, pinned at tag `five-port-parity`
     (POLICY.md section 1). Their CI lanes are tag-pinned toolchain canaries:
     the gate checks out the TAG, so an edit at HEAD could not fix their lane
     anyway, and editing a frozen tree to satisfy a rule adopted after the
     freeze would break the freeze to serve tidiness. Same reasoning as the
     archive -- fidelity to a pinned record outranks appearance. If either port
     is ever unfrozen, delete its line here first and sweep it.

  4. Lines carrying the marker `naming-rule-exempt` -- for the narrow case of
     THE RULE STATING ITSELF. POLICY.md must be able to name what it forbids
     (a policy a reader cannot check themselves is how this broke in the first
     place), and this file necessarily contains the words it searches for.
     Every marker in use is PRINTED on a passing run, so the escape hatch
     cannot grow quietly.

WHAT THIS CHECK DELIBERATELY CANNOT SEE -- stated because a gate whose blind
spots are unknown invites a claim wider than its evidence:

  * BINARY ASSETS. `assets/icons/*.ai` (the icon artwork sources) and the
    exported PNGs carry the vendor's name inside XMP format metadata -- an
    `xmlns` namespace URI and a `CreatorTool` field. That metadata is not
    authored prose and cannot be removed without corrupting the file, so
    binaries are out of scope by suffix. The separate question of whether
    proprietary-format artwork sources belong in a public repository is a
    provenance decision for JYH, not a naming-rule matter.
    (`.svg` IS in scope: an SVG exported from that product embeds a plain-text
    `Generator:` comment, which is both readable prose and safe to delete.)
  * WORD-BOUNDARY EVASION. Deliberate obfuscation ("A d o b e") passes. This
    gate stops forgetting, not intent.
  * UNTRACKED FILES. By construction -- and this bit once: while THIS file was
    itself untracked it passed the gate it defines, because its own pattern
    line was invisible to it. The line now carries a marker.

Exit 0 when clean, 1 with the offending file:line when not.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

BANNED = re.compile(r"\b(adobe|illustrator)\b", re.IGNORECASE)  # naming-rule-exempt: the pattern must spell what it forbids

# Line-scoped escape hatch; see exemption class 4.
MARKER = "naming-rule-exempt"

# Text we author. Binary assets are out of scope -- see the blind-spot note.
SUFFIXES = {
    ".rs", ".swift", ".py", ".ml", ".mli", ".yaml", ".yml", ".json",
    ".md", ".txt", ".html", ".css", ".js", ".mjs", ".ts", ".toml", ".sh",
    ".bib", ".svg", ".xml", ".plist", ".cfg", ".ini", ".rst",
}

EXEMPT_FILES = {
    "transcripts/TRANSCRIPT.md",   # class 1 -- the archive
}
EXEMPT_PREFIXES = (
    "article/",                    # class 2 -- prose analysis
    "jas_ocaml/",                  # class 3 -- FROZEN at five-port-parity
    "jas/",                        # class 3 -- FROZEN at five-port-parity
)


def tracked_files(root: pathlib.Path) -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root, capture_output=True, text=True, check=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def decode_if_text(data: bytes) -> str | None:
    """Decode `data` as text, or return None if it is binary.

    Decided from the CONTENT, over the whole buffer -- never from a prefix and
    never from the file's name. Binary means: contains a NUL byte, or does not
    decode as UTF-8.
    """
    if b"\x00" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def scan(rels, read):
    """Core rule, decoupled from git and the filesystem so it is testable.

    `read(rel)` returns the file's raw BYTES.
    Returns (hits, exempted, scanned, skipped_binary).
    """
    hits: list[str] = []
    exempted: list[str] = []
    skipped_binary: list[str] = []
    scanned = 0

    for rel in rels:
        if pathlib.PurePosixPath(rel).suffix not in SUFFIXES:
            continue
        if rel in EXEMPT_FILES or rel.startswith(EXEMPT_PREFIXES):
            continue
        try:
            data = read(rel)
        except OSError:
            continue
        text = decode_if_text(data)
        if text is None:
            skipped_binary.append(rel)
            continue
        scanned += 1
        for n, line in enumerate(text.splitlines(), 1):
            if not BANNED.search(line):
                continue
            if MARKER in line:
                exempted.append(f"  {rel}:{n}")
                continue
            hits.append(f"  {rel}:{n}: {line.strip()[:110]}")

    return hits, exempted, scanned, skipped_binary


def self_test() -> int:
    """Prove the gate FAILS on a violation -- the only property that matters.

    A gate is trusted for its red, not its green: one that can only pass is
    indistinguishable from no gate at all. Each case below is a class this
    check has to get right, driven through `scan` with a fake reader.
    """
    corpus = {
        # (a) a live tree must be caught ...
        "docs/live.md": b"fine line\nmatching Illustrator-style semantics\n",  # naming-rule-exempt: fail-path fixture
        # (b) ... in code as well as prose ...
        "jas_dioxus/src/x.rs": b'// Adobe RGB (1998)\n',  # naming-rule-exempt: fail-path fixture
        # (c) ... and in an SVG generator comment, the likeliest future leak.
        "assets/i.svg": b"<!-- Generator: Adobe Illustrator 30.2 -->\n",  # naming-rule-exempt: fail-path fixture
        # (d) the archive is exempt (JYH ruled: leave it as-is)
        "transcripts/TRANSCRIPT.md": b"an application like Illustrator\n",  # naming-rule-exempt: exemption fixture
        # (e) prose analysis is exempt
        "article/ARTICLE.md": b"compared with Illustrator\n",  # naming-rule-exempt: exemption fixture
        # (f) + (g) both frozen ports are exempt
        "jas_ocaml/lib/a.ml": b"(* Mirrors Illustrator *)\n",  # naming-rule-exempt: exemption fixture
        "jas/algorithms/t.py": b"# per Illustrator\n",  # naming-rule-exempt: exemption fixture
        # (h) a line-scoped marker suppresses just that line
        # The marker is spelled out LITERALLY here, never built from MARKER: a
        # fixture derived from the constant it tests cancels the mutation out.
        # (Measured -- an earlier version did exactly that and could not detect
        # marker handling being disabled.) This source line carries the literal,
        # so the gate scanning its own file exempts it too.
        "POLICY.md": b'Never use "Adobe" -- naming-rule-exempt\nbut this line is watched\n',
        # (i) binaries are out of scope by suffix, not by luck
        "assets/icons/pen tools.ai": b'xmlns:x="adobe:ns:meta/"\n',  # naming-rule-exempt: scope fixture
        # (j) a clean file stays clean
        "docs/clean.md": b"a vector illustration application\n",
    }
    hits, exempted, scanned, skipped_binary = scan(sorted(corpus), corpus.__getitem__)
    got = sorted(h.split(":")[0].strip() for h in hits)

    failures = []
    # Pin the marker's spelling: POLICY.md and this file's docstring both name
    # it, so a rename must break loudly rather than silently widen nothing.
    if MARKER != "naming-rule-exempt":
        failures.append(f"MARKER renamed to {MARKER!r}; update POLICY.md and the docstring")
    want = ["assets/i.svg", "docs/live.md", "jas_dioxus/src/x.rs"]
    if got != want:
        failures.append(f"caught {got}, expected {want}")
    if len(exempted) != 1 or "POLICY.md:1" not in exempted[0]:
        failures.append(f"line-marker exemption wrong: {exempted}")
    # 10 fixtures, minus 4 in exempt trees, minus 1 binary skipped on suffix
    # before it is ever read.
    if scanned != 5:
        failures.append(f"scanned {scanned}, expected 5 (10 - 4 exempt - 1 binary)")

    if failures:
        print("naming-rule SELF-TEST: FAILED")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"naming-rule SELF-TEST: OK (10 cases, {scanned} scanned, 3 caught, 1 line-exempt)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    root = pathlib.Path(__file__).resolve().parent.parent
    hits, exempted, scanned, skipped_binary = scan(
        tracked_files(root),
        lambda rel: (root / rel).read_bytes(),
    )

    if hits:
        print(f"naming-rule gate: FAILED -- {len(hits)} occurrence(s) in {scanned} tracked text files")
        print("The incumbent products are never named in code, schema, or documentation")
        print('(POLICY.md section 5). Use "vector illustration application", or "the')
        print('incumbent" for a comparative claim.')
        print("\n".join(hits))
        print("\nIf a line genuinely must name a product, see the exemption classes in")
        print(f"{pathlib.Path(__file__).name}'s docstring -- do not widen one without a reason.")
        return 1

    print(f"naming-rule gate: OK ({scanned} tracked text files scanned)")
    print("  exempt trees: transcripts/TRANSCRIPT.md (archive), article/ (prose),")
    print("                jas_ocaml/ + jas/ (frozen at five-port-parity)")
    if exempted:
        # Grouped by file, not line by line: most of them are this script's own
        # test fixtures, and a wall of line numbers hides the signal that
        # matters -- a NEW FILE appearing in this list.
        per_file: dict[str, int] = {}
        for e in exempted:
            per_file[e.strip().rsplit(":", 1)[0]] = per_file.get(e.strip().rsplit(":", 1)[0], 0) + 1
        summary = ", ".join(f"{f} ({n})" for f, n in sorted(per_file.items()))
        print(f"  {len(exempted)} line-scoped exemption(s) in {len(per_file)} file(s): {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
