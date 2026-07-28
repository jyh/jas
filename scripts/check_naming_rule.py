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

SCOPE: every git-tracked file whose CONTENT is text. Nothing is skipped on its
name -- no extension whitelist, no size cap, no exception for generated files.
Tracking is the honest definition of "what this project authors": it excludes
build trees and vendored dependencies by construction rather than by a
hand-maintained skip list, which is the kind of list that rots. (Measured:
`jas_ocaml/_build/` and `jas_flask/.venv/` between them hold dozens of matches
and not one line of them was written here.)

  TEXT means: no NUL byte, and the bytes decode as UTF-8. Judged over the WHOLE
  file, never a prefix. The rule was chosen against a real counter-example: the
  `assets/icons/*.ai` artwork sources were PDF containers whose first NUL byte
  landed at offset 379756, so an 8 KB NUL sniff called them TEXT; they were
  recognised as binary only because they failed to decode as UTF-8, at byte 9.
  They were the ONLY two files in the tree on which the two criteria disagreed,
  and they were deleted 2026-07-28 -- so the whole-file rule now has no live
  example arguing for it. It is kept anyway: the file has to be read to be
  scanned, so a prefix buys nothing and is a guess.

  Files skipped as binary are PRINTED, grouped by suffix, on a passing run: 56
  today (.png 32, .bin 21, .ico 2, .icns 1). A skip nobody can see is precisely
  how this gate's scope came to be wrong in the first place.

  This replaced a 24-suffix WHITELIST whose docstring described it as excluding
  binary assets. Censused: it silently skipped 39 tracked text files, among
  them BUILD, MODULE.bazel, .bazelrc, LICENSE, Package.resolved,
  requirements.txt.lock, a 341 KB results .csv and 8 .gitignore files. 16 of
  those were outside the exempt trees and are now scanned; the count went 1342
  -> 1358. A new kind of text file is now in scope BY DEFAULT rather than by
  someone remembering to add a suffix.

  COST, measured on this tree (1896 files, 37.8 MB, 489,326 lines scanned):
  298 ms, against 217 ms for the narrower predecessor. A size cap was
  considered and REJECTED: the largest file in scope is the 1.4 MB generated
  `workspace/workspace.json`, which is exactly where a violation authored in a
  `workspace/*.yaml` would surface.

HOW A NAME IS RECOGNISED: as an identifier SEGMENT, case-insensitively. Every
run of [A-Za-z0-9_] is split on underscores, on CamelCase humps and on
letter/digit transitions, and a segment that IS a banned word is the violation.
Plain prose spellings fall out of the same rule, because spaces, hyphens and
punctuation end a run.

  This replaced a word-boundary pattern that returned False for every natural
  code spelling. Measured, on all of: <Vendor>RGB1998, to<Vendor>RGB(),
  <Product>Importer, <vendor>_rgb, <VENDOR>_RGB, <product>_compat. The old
  docstring conceded only "deliberate obfuscation" -- but CamelCase and
  snake_case are not obfuscation, they are how a word is written in code, in
  the one gate whose whole job is reading code. The segment rule is a strict
  superset of the word-boundary rule: if a word is bounded by non-word
  characters then the run IS the word, so the segment is the word.

  Being exact about the evidence, because that is this file's whole point: NO
  identifier-spelled violation exists in the tree today. The frozen ports do
  carry a colour-profile string, but with a SPACE in it, so the old pattern
  already saw it -- what holds it back is exemption class 3, not the pattern.
  This change closes a class the old rule could not have seen IF it appeared;
  it did not uncover a live breach. What it did find is 16 formerly unscanned
  text files, listed above, which were also clean.

  FALSE POSITIVES, and what they cost. Both banned words are ordinary English
  in another sense -- one names a sun-dried mud brick, the other a person who
  draws. The segment rule flags those uses too, and that is a deliberate trade:
    * a false positive costs one line marker or one rephrase, paid by the
      author of the line, at the moment they write it, with file:line printed
      -- the cheapest moment available;
    * a miss costs what already happened once: a naming breach live on a public
      repository for an unknown length of time;
    * `article/`, the one tree where prose about people who draw is likely, is
      exempt already.
  Measured over the whole tree with every exemption switched off, the segment
  rule adds exactly 3 lines beyond the word-boundary rule -- all 3 inside
  `article/`, all 3 the same BibTeX citation key. Zero false positives in live
  code or docs today. Derived forms are not flagged by construction:
  "illustration", "illustrated", "illustrative" and "illustrators" are
  different segments, and the self-test pins that they stay clean.

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

  * BINARY CONTENT. Re-censused 2026-07-28 after the artwork deletions, over
    all 37 tracked PNGs (32 reach the binary classifier; the other 5 live in
    `article/` and are skipped as an exempt tree first): 7 contain the vendor
    token, 0 contain the product token, and 0 carry a `CreatorTool` field of
    any kind. Every one of the 27 vendor matches is an XMP namespace URI in the
    vendor's own domain, inside an iTXt chunk -- ISO-standard metadata emitted
    by a screenshot tool, not authored prose, and not removable without
    breaking the standard.
    (An earlier version of this docstring asserted that these PNGs carry "a
    `CreatorTool` field". They do not, and the claim had never been measured.
    It is recorded here rather than quietly deleted, because a gate's own
    self-description is the worst place in a repository for a claim wider than
    its evidence, and this file is meant to be the house's example of the
    opposite.)
    THE ONE REAL EXPOSURE IS NOW GONE. Two `.ai` artwork sources carried both
    tokens as prose inside their XMP packets -- 32 and 37 matches, 69 in all,
    invisible to this gate by design. JYH deleted them 2026-07-28 once it was
    established that the shipping icons are genuine `<path>` SVG (measured: no
    embedded raster), so the vector sources were editable without them and
    nothing was lost. The provenance question that hung over them is closed by
    deletion rather than by exemption.
    (`.svg` IS in scope: an SVG exported from that product embeds a plain-text
    `Generator:` comment, which is both readable prose and safe to delete.)
  * A SEPARATOR-FREE RUN. A banned word fused to another word in a single case
    -- <VENDOR>RGB, <vendor>rgb -- is one segment and is not flagged. Splitting
    inside a same-case run would need a dictionary, and a dictionary would
    start flagging ordinary words.
  * DERIVED FORMS. The plural of the product word is ordinary English for
    people who draw, and is deliberately not flagged; see the trade above.
  * DELIBERATE OBFUSCATION. Spaced-out letters, string concatenation, encoding.
    This gate stops forgetting, not intent.
  * NON-UTF-8 TEXT. A Latin-1 or UTF-16 prose file would be classified binary
    and skipped. Measured: zero such files today -- every tracked NUL-free file
    decodes as UTF-8. (Until 2026-07-28 the two `.ai` containers were the sole
    exception; they are deleted.) The binary-skip line printed on a passing run
    is what would expose a new one.
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

BANNED_TOKENS = frozenset({"adobe", "illustrator"})  # naming-rule-exempt: the rule must spell what it forbids

# A run of identifier characters, and the segments inside one. Splitting a run
# into segments is what lets the rule see a name that is spelled the way code
# spells names -- see "HOW A NAME IS RECOGNISED" in the module docstring.
IDENT_RUN = re.compile(r"[A-Za-z0-9_]+")
SEGMENT = re.compile(r"[A-Z]+(?![a-z])|[A-Z][a-z]+|[a-z]+|[0-9]+")

# Cheap necessary condition, to keep the split off the 99.99% of lines that
# cannot match. SOUND because a segment equal to a token is, letter for letter,
# a substring of the line -- so no substring, no segment. DERIVED from
# BANNED_TOKENS on purpose (unlike the test fixtures, which are spelled out):
# a hand-written copy would silently stop covering a token added later.
# Measured over the 489,326 lines this gate reads: 884 ms without it, 240 ms
# with it, same 21 lines found.
_PREFILTER = re.compile("|".join(sorted(BANNED_TOKENS)), re.IGNORECASE)

# Line-scoped escape hatch; see exemption class 4.
MARKER = "naming-rule-exempt"

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


def banned_segment(line: str) -> str | None:
    """Return the offending identifier segment in `line`, or None.

    Every maximal run of `[A-Za-z0-9_]` is split into segments -- on
    underscores, on CamelCase humps, and on letter/digit transitions -- and a
    segment that IS one of the banned words (any case) is the violation.
    Punctuation, spaces and hyphens end a run, so the plain prose spellings
    fall out of the same rule rather than needing a second one.

    The underscore split needs no code of its own: no SEGMENT alternative can
    match `_`, so `finditer` steps over it. An explicit `.split("_")` was
    written here first and then removed -- mutation testing showed deleting it
    changed no result, which is the definition of a line that is not doing
    anything.
    """
    if not _PREFILTER.search(line):
        return None
    for run in IDENT_RUN.finditer(line):
        for seg in SEGMENT.finditer(run.group(0)):
            if seg.group(0).lower() in BANNED_TOKENS:
                return seg.group(0)
    return None


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
        # NOTHING is skipped on its name. Scope is decided by content below.
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
            seg = banned_segment(line)
            if seg is None:
                continue
            if MARKER in line:
                exempted.append(f"  {rel}:{n}")
                continue
            hits.append(f"  {rel}:{n}: [{seg}] {line.strip()[:110]}")

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
        # (i) a real binary is out of scope -- decided by CONTENT, not by name.
        # A PNG: the NUL byte in its signature is the giveaway. The vendor
        # string here is verbatim what the 10 tracked PNGs that match actually
        # contain -- an XMP namespace URI, not authored prose.
        "assets/icons/x.png": b'\x89PNG\r\n\x1a\n\x00\x00\x00\riTXtXML:com.adobe.xmp\x00<x:xmpmeta xmlns:x="adobe:ns:meta/">',  # naming-rule-exempt: scope fixture
        # (j) a clean file stays clean
        "docs/clean.md": b"a vector illustration application\n",

        # ---- CLASS A: text files with no suffix, or an unlisted one --------
        # These are ordinary authored text and must be scanned. Before this,
        # a 24-entry suffix whitelist silently skipped 37 tracked text files
        # including these very paths.
        # (k) an extension-less build file
        "BUILD": b'# ported from the Illustrator plugin layout\n',  # naming-rule-exempt: fail-path fixture
        # (l) a dotfile
        ".gitattributes": b"*.ai binary   # Illustrator sources\n",  # naming-rule-exempt: fail-path fixture
        # (m) an unlisted-suffix text file
        "requirements.txt.lock": b"# pinned for Adobe RGB conversion\n",  # naming-rule-exempt: fail-path fixture
        # (n) an unlisted-suffix text file that is CLEAN stays clean and
        #     still counts as scanned -- widening scope must not invent hits.
        "prototypes/p/results/run.csv": b"t,x,y\n0,1,2\n",

        # ---- CLASS A': a binary whose NAME looks like text ----------------
        # (o) The `.ai` artwork sources are PDF containers. Measured: their
        #     first NUL byte is at offset 379756, so an 8 KB NUL sniff calls
        #     them TEXT; they fail UTF-8 at byte 9. Spelled here with that
        #     real header so a prefix-sniff regression is caught.
        "assets/icons/pen tools.ai": b"%PDF-1.6\r%\xe2\xe3\xcf\xd3\r\n1 0 obj\r<</Metadata 2 0 R>>\n" + b"x" * 900 + b'<xmp:CreatorTool>Adobe Illustrator</xmp:CreatorTool>\n',  # naming-rule-exempt: scope fixture

        # ---- CLASS B: the names as they appear in IDENTIFIERS -------------
        # A word-boundary pattern misses every one of these. They are not
        # obfuscation; they are how a word is spelled in code.
        # (p) CamelCase, leading
        "jas_dioxus/src/color.rs": b'const P: &str = "AdobeRGB1998";\n',  # naming-rule-exempt: fail-path fixture
        # (q) CamelCase, interior (lowercase-to-uppercase hump)
        "JasSwift/Sources/C.swift": b"func toAdobeRGB() -> Color {}\n",  # naming-rule-exempt: fail-path fixture
        # (r) CamelCase, the product name as a type prefix
        "workspace_interpreter/io.py": b"class IllustratorImporter:\n",  # naming-rule-exempt: fail-path fixture
        # (s) snake_case
        "jas_dioxus/src/cs.rs": b"let adobe_rgb = 1;\n",  # naming-rule-exempt: fail-path fixture
        # (t) SCREAMING_SNAKE_CASE
        "workspace/tests/t.yaml": b"  profile: ADOBE_RGB\n",  # naming-rule-exempt: fail-path fixture
        # (u) snake_case, the product name, non-leading segment
        "JasSwift/Sources/D.swift": b"let mode = illustrator_compat\n",  # naming-rule-exempt: fail-path fixture

        # ---- CLASS B': innocent words must NOT be flagged -----------------
        # Both banned words are ordinary English in other senses. The rule
        # matches an identifier SEGMENT, so derived and compound forms that
        # are not the bare word pass. If any of these ever start failing, a
        # contributor is being punished for correct English.
        "docs/innocent.md": (
            b"This is a vector illustration application.\n"
            b"The behaviour is illustrated by the figure below.\n"
            b"See the illustrations, and the illustrative example.\n"
            b"Several illustrators contributed the icon set.\n"
            b"The adobelike texture shader is unrelated.\n"
        ),
    }
    hits, exempted, scanned, skipped_binary = scan(sorted(corpus), corpus.__getitem__)
    got = sorted(h.split(":")[0].strip() for h in hits)

    failures = []
    # Pin the marker's spelling: POLICY.md and this file's docstring both name
    # it, so a rename must break loudly rather than silently widen nothing.
    if MARKER != "naming-rule-exempt":
        failures.append(f"MARKER renamed to {MARKER!r}; update POLICY.md and the docstring")

    # Every fixture that must be caught, spelled out. Anything absent here and
    # present in `got` is a FALSE POSITIVE, which is just as much a bug.
    want = [
        ".gitattributes",                # (l) dotfile
        "BUILD",                         # (k) no suffix at all
        "JasSwift/Sources/C.swift",      # (q) CamelCase hump
        "JasSwift/Sources/D.swift",      # (u) snake_case, non-leading segment
        "assets/i.svg",                  # (c) SVG generator comment
        "docs/live.md",                  # (a) prose
        "jas_dioxus/src/color.rs",       # (p) CamelCase, leading
        "jas_dioxus/src/cs.rs",          # (s) snake_case
        "jas_dioxus/src/x.rs",           # (b) code comment
        "requirements.txt.lock",         # (m) unlisted suffix
        "workspace/tests/t.yaml",        # (t) SCREAMING_SNAKE_CASE
        "workspace_interpreter/io.py",   # (r) CamelCase type prefix
    ]
    if got != want:
        missed = [w for w in want if w not in got]
        extra = [gg for gg in got if gg not in want]
        failures.append(f"caught {len(got)}, expected {len(want)}; MISSED {missed}; FALSE POSITIVES {extra}")
    if len(exempted) != 1 or "POLICY.md:1" not in exempted[0]:
        failures.append(f"line-marker exemption wrong: {exempted}")

    want_binary = ["assets/icons/pen tools.ai", "assets/icons/x.png"]
    if skipped_binary != want_binary:
        failures.append(f"binary skips {skipped_binary}, expected {want_binary}")

    # 22 fixtures, minus 4 in exempt trees, minus 2 binary by CONTENT.
    if scanned != 16:
        failures.append(f"scanned {scanned}, expected 16 (22 - 4 exempt - 2 binary)")

    if failures:
        print("naming-rule SELF-TEST: FAILED")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"naming-rule SELF-TEST: OK (22 cases, {scanned} scanned, {len(got)} caught, "
          f"{len(exempted)} line-exempt, {len(skipped_binary)} binary)")
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
    if skipped_binary:
        # Every skip is REPORTED. A file leaving scope because its bytes are
        # binary is a decision, and a decision nobody can see is the failure
        # mode that made this gate's own scope wrong in the first place.
        by_suffix: dict[str, int] = {}
        for rel in skipped_binary:
            key = pathlib.PurePosixPath(rel).suffix.lower() or "(no suffix)"
            by_suffix[key] = by_suffix.get(key, 0) + 1
        shape = ", ".join(f"{k} ({n})" for k, n in sorted(by_suffix.items()))
        print(f"  {len(skipped_binary)} file(s) skipped as binary by content: {shape}")
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
