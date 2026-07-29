#!/usr/bin/env python3
"""§16.4 — a selection never holds an element AND its own descendant.

WHY THIS EXISTS
---------------
LAYER_STRUCTURE.md §16.4 asked for "a rule that makes a defect impossible"
rather than a fix that makes one instance go away. This is that rule, asserted
over every fixture in the tree.

The shape it forbids produced EIGHT defects in one day, every one invisible in
jas_dioxus and live in JasSwift. The clearest is `copy_selection`: given a group
and its own member as PEERS, it copies the group whole AND copies each member
INTO the source, so marquee-then-duplicate left the SOURCE group holding four
children instead of two. `move_selection` and `delete_selection` survived the
same shape only by accident -- delete sorts paths descending, and move writes
absolute positions read from a pristine document.

FOUR PRODUCERS had to be closed before this could be asserted at all, and each
was found only after the previous one was fixed and the census was RE-RUN:

  1. `doc.set_selection` expanded every named container to all its descendants,
     so the Layers panel would mark a group's child rows.
  2. `Controller::select_element` wrote the group AND EVERY SIBLING when a child
     was clicked.
  3. `add_to_selection` appended without an ancestor check.
  4. `toggle_selection` likewise -- and that is the one shift-click runs, so it
     was the reachable producer.

The artist's experience is unchanged. JYH at council 2026-07-29: *"when we
select a group on the canvas, it should be as if the children are selected
too."* AS IF is the design -- the shorthand is expanded at the point of USE
(`map_paintable` for operations, `path_is_selected_or_under` for the panel
marker), never written into the stored selection where no operation reads it
coherently.

WHAT THIS GATE DOES
-------------------
Walks every `selection` array in `test_fixtures/**/*.json` and fails if any two
entries stand in an ancestor/descendant relation. Paths are compared
ELEMENT-WISE: `[0,1]` is not an ancestor of `[0,10]`.

WHAT IT DOES NOT COVER
----------------------
* It gates the CORPUS, not the running application. A code path that builds the
  shape at runtime without a fixture to witness it is invisible here -- the
  per-port tests (`the_extend_seams_cannot_build_an_ancestor_descendant_selection`
  and its Swift twin) are what watch the producers.
* It says nothing about selection ORDER, which §10/D6 governs separately.
"""

import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = REPO / "test_fixtures"

# Anti-vacuity floors. A walk that found no selections reports no violations,
# which is indistinguishable from a clean corpus.
MIN_FILES = 200
MIN_SELECTIONS = 40


def paths_of(sel):
    """Path tuples from a selection array, in either spelling the corpus uses:
    `{"kind": ..., "path": [...]}` entries, or a bare `[...]` path."""
    out = []
    for e in sel:
        if isinstance(e, dict) and isinstance(e.get("path"), list):
            out.append(tuple(e["path"]))
        elif isinstance(e, list) and all(isinstance(x, int) for x in e):
            out.append(tuple(e))
    return out


def find_selections(node, out):
    """Every `selection` array anywhere in the document, at any nesting."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "selection" and isinstance(v, list):
                out.append(v)
            find_selections(v, out)
    elif isinstance(node, list):
        for v in node:
            find_selections(v, out)


def is_ancestor(a, b):
    """True when `a` is a STRICT ancestor of `b`.

    Element-wise, never a string prefix: `[0,1]` is not an ancestor of `[0,10]`.
    """
    return len(a) < len(b) and b[:len(a)] == a


def violations(sel):
    """Ancestor/descendant pairs within one selection array."""
    ps = paths_of(sel)
    out = []
    for i, a in enumerate(ps):
        for b in ps[i + 1:]:
            if is_ancestor(a, b):
                out.append((a, b))
            elif is_ancestor(b, a):
                out.append((b, a))
    return out


def scan(docs):
    """docs: {relpath: parsed json} -> (violations, n_selections)."""
    found = []
    n_selections = 0
    for rel, doc in sorted(docs.items()):
        sels = []
        find_selections(doc, sels)
        for sel in sels:
            if len(paths_of(sel)) > 1:
                n_selections += 1
            for anc, desc in violations(sel):
                found.append((rel, list(anc), list(desc)))
    return found, n_selections


def below_floor(n_files, n_selections):
    return n_files < MIN_FILES or n_selections < MIN_SELECTIONS


def load_fixtures():
    docs = {}
    for p in sorted(FIXTURES.rglob("*.json")):
        try:
            docs[p.relative_to(FIXTURES).as_posix()] = json.loads(
                p.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
    return docs


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test():
    """Prove the gate goes RED on each class it claims to cover."""
    failures = []

    def sel(*paths):
        return [{"kind": "all", "path": list(p)} for p in paths]

    cases = {
        # (a) THE FORBIDDEN SHAPE, in the order the marquee produced it.
        "a.json": {"selection": sel([0, 1], [0, 1, 0])},
        # (b) The same pair in the OPPOSITE order -- `toggle_selection` produced
        #     it this way round (member first, then the group).
        "b.json": {"selection": sel([0, 1, 0], [0, 1])},
        # (c) Two levels apart, not just parent/child.
        "c.json": {"selection": sel([0], [0, 1, 2, 3])},
        # (d) Disjoint siblings are FINE -- the ordinary multi-selection.
        "d.json": {"selection": sel([0, 0], [0, 1], [1, 0])},
        # (e) A single entry cannot violate anything.
        "e.json": {"selection": sel([0, 1])},
        # (f) An empty selection is fine.
        "f.json": {"selection": []},
        # (g) ELEMENT-WISE, NOT STRING PREFIX. [0,1] is NOT an ancestor of
        #     [0,10] -- a `startswith` on a joined string would call this a
        #     violation and the gate would cry wolf on a legitimate selection.
        "g.json": {"selection": sel([0, 1], [0, 10], [0, 11, 3])},
        # (h) The BARE PATH spelling, which some fixtures use.
        "h.json": {"selection": [[0, 1], [0, 1, 0]]},
        # (i) NESTED occurrence -- a `selection` inside a journal entry, not at
        #     the document root. A root-only reader would miss it.
        "i.json": {"journal": [{"txns": [{"after": {"selection": sel([2], [2, 0])}}]}]},
        # (j) An exact DUPLICATE is not an ancestor/descendant pair. It may be a
        #     defect (D6 dedup owns it) but it is not THIS gate's business, and
        #     claiming it would make the gate's message wrong.
        "j.json": {"selection": sel([0, 1], [0, 1])},
    }
    found, _ = scan(cases)
    got = {rel for rel, _, _ in found}
    want = {"a.json", "b.json", "c.json", "h.json", "i.json"}
    for rel in want - got:
        failures.append(f"  MISSED a violation in {rel}")
    for rel in got - want:
        failures.append(f"  FALSE POSITIVE in {rel}: {[v for r, *v in found if r == rel]}")

    # Both orderings must report the pair ANCESTOR-FIRST, so the message reads
    # the same however the fixture happened to store it.
    for rel in ("a.json", "b.json"):
        pair = [(a, d) for r, a, d in found if r == rel]
        if pair != [([0, 1], [0, 1, 0])]:
            failures.append(f"  {rel}: expected ([0,1], [0,1,0]) ancestor-first, got {pair}")

    # The anti-vacuity floor is itself a class this gate must get right.
    for nf, ns, want_rejected in [
        (0, 0, True),                          # nothing walked
        (1, 100, True),                         # a truncated file walk
        (500, 1, True),                          # selections stopped being found
        (MIN_FILES - 1, MIN_SELECTIONS, True),   # just under on files
        (MIN_FILES, MIN_SELECTIONS - 1, True),   # just under on selections
        (MIN_FILES, MIN_SELECTIONS, False),      # exactly at both lines
        (417, 66, False),                        # the real tree, 2026-07-29
    ]:
        if below_floor(nf, ns) != want_rejected:
            verb = "reject" if want_rejected else "accept"
            failures.append(f"  floor: {nf} files / {ns} selections should {verb}")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: {len(want)} violation-classes detected (both orderings, "
          f"two levels apart, the bare-path spelling and a NESTED selection), "
          f"5 legitimate shapes silent including [0,1] vs [0,10] compared "
          f"element-wise, anti-vacuity floor holds at {MIN_FILES} files / "
          f"{MIN_SELECTIONS} selections -- gate proven RED where it must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    docs = load_fixtures()
    found, n_selections = scan(docs)

    if below_floor(len(docs), n_selections):
        print(f"ERROR: walked {len(docs)} fixture file(s) and found "
              f"{n_selections} multi-entry selection(s), below the anti-vacuity "
              f"floor of {MIN_FILES}/{MIN_SELECTIONS}.", file=sys.stderr)
        print(file=sys.stderr)
        print("This is not a pass. A walk that finds no selections reports no", file=sys.stderr)
        print("violations, which is indistinguishable from a clean corpus.", file=sys.stderr)
        return 1

    if not found:
        print(f"selection invariant: {n_selections} multi-entry selection(s) "
              f"across {len(docs)} fixture file(s), no selection holds an "
              f"element and its own descendant (§16.4).")
        return 0

    print(f"ERROR: {len(found)} selection(s) hold an element AND its own "
          f"descendant, which §16.4 forbids.", file=sys.stderr)
    print(file=sys.stderr)
    for rel, anc, desc in found:
        print(f"  {rel}: {anc} contains {desc}", file=sys.stderr)
    print(file=sys.stderr)
    print("This shape produced eight defects in one day. `copy_selection` reads", file=sys.stderr)
    print("it as 'copy the group, then copy each member INTO the source', so a", file=sys.stderr)
    print("duplicate DAMAGES the original.", file=sys.stderr)
    print(file=sys.stderr)
    print("Selecting a group still affects every member and still marks every", file=sys.stderr)
    print("member's row -- that expansion belongs at the point of USE", file=sys.stderr)
    print("(`map_paintable`, `path_is_selected_or_under`), never in the stored", file=sys.stderr)
    print("selection. If a NEW producer wrote this, fix the producer; do not", file=sys.stderr)
    print("regenerate the golden.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
