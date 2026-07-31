#!/usr/bin/env python3
"""A deferral that states its own precondition must be checked against reality.

WHY THIS EXISTS, AND WHY IT IS DELIBERATELY SMALL
--------------------------------------------------
Most of this project's recent defects were not mistakes. They were decisions
that were CORRECT WHEN MADE, whose premise later moved, with nothing watching
the premise:

  the Layers type filter parsed the row LABEL     correct while only Layers
                                                  could carry a name
  LYR-091's deferral                              "we can't construct a named
                                                  non-layer descendant"
  the swift:dropdown exemption                    Swift genuinely lacked it
  an anti-vacuity floor with slack                the test count was lower
  three str(Path) fixes with no gate              "a gate will police the class"

The proposal was to make EVERY exemption and ledger row state a machine-checked
expiry. It was scored twice and killed twice -- Starbuck at arbitration (1 of 5),
Flask independently (0 of 3 as built), and JYH ruled the generalization dead.

WHAT SURVIVED IS THIS ONE POPULATION, and it survived for a precise reason. An
expiry gate needs TWO things: a durable row, and someone who KNEW the premise
was a premise and wrote it down. Both hold BY CONSTRUCTION for a deferral --
writing "revisit when X lands" is exactly the act of recording an expiry. Three
of the five above had their condition written in English in this repo; LYR-091
says it outright. Nobody connected the sentence to the commit that satisfied it,
because that was nobody's job and no machine's.

Everywhere else the authoring step is the missing one, and no gate fixes that.
This is the narrow slice where the writing has already happened.

THE CONVENTION
--------------
A deferral declares its expiry as an HTML comment -- invisible in rendered
markdown, trivially machine-readable:

    <!-- expires-when: {"port": "swift",
                        "file": "JasSwift/Sources/.../X.swift",
                        "lacks": "if case .layer"} -->

PER PORT, and that is not decoration. Flask's letter 11 made the point that
killed the general version: a {file, contains|lacks} claim is a claim about ONE
FILE'S TEXT IN ONE PORT, while a premise like LYR-091's is a claim about
BEHAVIOUR ACROSS PORTS. At the commit that expired LYR-091 the rename gate was
spelled four different ways and JasSwift had no `is_layer` token at all -- a
single cross-port grep would have fired on Rust and OCaml and silently missed an
active port. So a cross-port premise gets one claim PER PORT, and the gate reds
when ANY of them lapses.

WHAT IT DOES NOT COVER
----------------------
* It reaches only premises someone wrote down. That is the whole known limit,
  measured: 1 of the 5 instances above, and the four it misses need other
  instruments (a forbidden-pattern gate, a derived floor, container-seeding).
* It checks text, not behaviour. A claim can hold while the feature is broken.
* Frozen ports are out of scope by POLICY.md section 1.
"""

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
TRANSCRIPTS = REPO / "transcripts"

MARKER = re.compile(r"<!--\s*expires-when:\s*(\{.*?\})\s*-->", re.S)

# EXACT anti-vacuity floor. Guards a PARSE (did the marker regex match?), so it
# cannot be derived from that same parse -- see check_lane_coverage.py's note on
# which floors may be derived and which must not.
MIN_DECLARED = 1


# A marker spanning several lines inside a `#`-comment block carries a comment
# lead on every continuation line, which lands INSIDE the JSON. Stripped before
# parsing. Anchored at line start, so a `#` inside a JSON string (a colour like
# "#fff") is untouched — and JSON strings cannot contain a literal newline, so
# there is no line whose start is inside one.
COMMENT_LEAD = re.compile(r"^[ \t]*#[ \t]?", re.M)


def declarations(sources):
    """[(relpath, line, claim_dict)] for every expiry marker found."""
    out = []
    for rel, text in sorted(sources.items()):
        for m in MARKER.finditer(text):
            line = text[:m.start()].count("\n") + 1
            body = COMMENT_LEAD.sub("", m.group(1))
            try:
                out.append((rel, line, json.loads(body)))
            except json.JSONDecodeError as e:
                out.append((rel, line, {"__malformed__": str(e)}))
    return out


def expired(decls, read_file):
    """[(where, why)] for every declaration whose premise no longer holds."""
    out = []
    for rel, line, claim in decls:
        where = f"{rel}:{line}"
        if "__malformed__" in claim:
            out.append((where, f"the expires-when block is not valid JSON: "
                               f"{claim['__malformed__']}"))
            continue
        target = claim.get("file")
        if not target:
            out.append((where, "no `file` -- an expiry with no subject checks nothing"))
            continue
        src = read_file(target)
        if src is None:
            out.append((where, f"names {target}, which is not readable -- a renamed "
                               f"file must not silently retire a deferral"))
            continue
        # A DECLARATION MUST NOT BE ITS OWN EVIDENCE. When a marker sits in the
        # very file it makes a claim about -- which is the normal case once
        # `workspace/**/*.yaml` is in scope, since a tool's deferral is written
        # in that tool's header -- the marker's own text is part of the file.
        # A claim of `lacks: "event.modifiers.alt"` then reads as LAPSED the
        # instant it is written, because the words are right there in the
        # comment. The claim is about the CODE, so the declarations come out
        # first. Caught by this gate on the first deferral ever written into a
        # workspace YAML, which was mine.
        src = MARKER.sub("", src)
        port = claim.get("port", "?")
        if "contains" in claim and claim["contains"] not in src:
            out.append((where, f"[{port}] expected {target} to CONTAIN "
                               f"{claim['contains']!r} and it does not -- the "
                               f"precondition has LAPSED"))
        if "lacks" in claim and claim["lacks"] in src:
            out.append((where, f"[{port}] expected {target} to LACK "
                               f"{claim['lacks']!r} and it is present -- the "
                               f"precondition has LAPSED"))
        if "contains" not in claim and "lacks" not in claim:
            out.append((where, "states neither `contains` nor `lacks`"))
    return out


def read_repo_file(rel):
    try:
        return (REPO / rel).read_text(encoding="utf-8")
    except OSError:
        return None


def load_sources():
    """Every place a deferral can be WRITTEN, not just the prose ones.

    The first cut globbed `transcripts/*.md` alone. That missed the one
    population where deferrals matter most: `workspace/**/*.yaml` is the SPEC —
    it is what every port compiles against — so a "reserved for a later phase"
    there is a statement about shipped behaviour, not a note about a document.

    Found by JYH hitting one. Shift-to-constrain had been deferred in
    `ellipse.yaml`'s header since Phase 1 ("reserved for a later phase"); the
    tool shipped, the phase never came, and the first anyone heard of it was an
    artist unable to draw a circle. 39 such lines were sitting in 19 workspace
    YAML files, none of them reachable by this gate.

    An HTML comment is a legal YAML comment body, so the marker syntax needs no
    change to work in both.
    """
    out = {}
    for base, pat in ((TRANSCRIPTS, "*.md"), (REPO / "workspace", "**/*.yaml")):
        for p in sorted(base.glob(pat)):
            try:
                out[p.relative_to(REPO).as_posix()] = p.read_text(encoding="utf-8")
            except OSError:
                continue
    return out


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test():
    failures = []
    fake = {"a.swift": "if case .layer(let l) = elem {\n", "b.rs": "let can_rename = true;\n"}
    read = lambda p: fake.get(p)

    def check(name, md, want_red, want_sub=None):
        d = declarations({"t.md": md})
        got = expired(d, read)
        if bool(got) != want_red:
            failures.append(f"  {name}: expected {'RED' if want_red else 'GREEN'}, got {got}")
        if want_sub and not any(want_sub in w for _, w in got):
            failures.append(f"  {name}: message should mention {want_sub!r}, got {got}")

    # (a) A premise that STILL HOLDS is silent -- the deferral is legitimate.
    check("a/still deferred",
          '<!-- expires-when: {"port":"swift","file":"a.swift","contains":"if case .layer"} -->',
          False)

    # (b) THE CASE THIS EXISTS FOR: the precondition lapsed. LYR-091's shape --
    #     "only Layers are renameable" stops being true.
    check("b/lapsed",
          '<!-- expires-when: {"port":"swift","file":"a.swift","lacks":"if case .layer"} -->',
          True, want_sub="LAPSED")

    # (c) PER PORT. One premise, two claims: the gate reds when EITHER lapses,
    #     which is the failure a single cross-port grep would have missed --
    #     Rust moved and Swift did not, and one grep would have answered for
    #     both (Flask, letter 11 §3).
    two = ('<!-- expires-when: {"port":"rust","file":"b.rs","lacks":"can_rename = true"} -->\n'
           '<!-- expires-when: {"port":"swift","file":"a.swift","contains":"if case .layer"} -->')
    got = expired(declarations({"t.md": two}), read)
    if len(got) != 1 or "[rust]" not in got[0][1]:
        failures.append(f"  c: exactly the rust claim should lapse, got {got}")

    # (d) A renamed file must not silently retire a deferral.
    check("d/file gone",
          '<!-- expires-when: {"port":"swift","file":"gone.swift","lacks":"x"} -->',
          True, want_sub="not readable")

    # (e) Malformed and subjectless blocks are refused, not skipped.
    check("e/malformed", '<!-- expires-when: {not json} -->', True)
    check("f/no file", '<!-- expires-when: {"port":"swift","lacks":"x"} -->', True)
    check("g/no predicate", '<!-- expires-when: {"port":"s","file":"a.swift"} -->', True)

    # (h) Prose that merely mentions the words is not a declaration.
    if declarations({"t.md": "Revisit when Group names land (expires-when someday)."}):
        failures.append("  h: prose must not be read as a declaration")

    # (i) The live tree's own declarations must hold right now.
    live = expired(declarations(load_sources()), read_repo_file)
    if live:
        failures.append(f"  i: the shipping transcripts have lapsed deferrals: {live}")
    n = len(declarations(load_sources()))
    if n < MIN_DECLARED:
        failures.append(f"  i: only {n} declared expiry markers, floor is {MIN_DECLARED} "
                        f"-- a regex that stopped matching reports nothing lapsed")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: a live premise is silent, a LAPSED one reds, per-port "
          f"claims lapse independently (the case a single cross-port grep would "
          f"have missed), and a renamed file / malformed block / missing subject "
          f"/ missing predicate are each REFUSED rather than skipped; prose is "
          f"not a declaration; {n} live declaration(s) all still hold.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    decls = declarations(load_sources())
    if len(decls) < MIN_DECLARED:
        print(f"ERROR: only {len(decls)} declared expiry marker(s), below the "
              f"floor of {MIN_DECLARED}.", file=sys.stderr)
        print("A regex that stopped matching reports nothing lapsed, which is "
              "indistinguishable from every deferral still being valid.",
              file=sys.stderr)
        return 1

    lapsed = expired(decls, read_repo_file)
    if not lapsed:
        print(f"deferral expiry: {len(decls)} deferral(s) declare a "
              f"precondition, all still hold.")
        return 0

    print(f"ERROR: {len(lapsed)} deferral(s) rest on a precondition that has "
          f"LAPSED.", file=sys.stderr)
    print(file=sys.stderr)
    for where, why in lapsed:
        print(f"  {where}: {why}", file=sys.stderr)
    print(file=sys.stderr)
    print("The deferral was correct when it was written. The world moved and", file=sys.stderr)
    print("nobody re-read it -- which is the single most common shape of defect", file=sys.stderr)
    print("this project has found in itself. Do the deferred work, or rewrite", file=sys.stderr)
    print("the deferral with the precondition that is actually blocking now.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
