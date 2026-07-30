#!/usr/bin/env python3
"""Every `set_document` caller sits inside a transaction.

WHY THIS EXISTS
---------------
`Model::set_document` carries a debug assertion:

    debug_assert!(self.in_txn,
        "set_document outside a transaction: undoable edits use begin_txn/
         commit_txn or with_txn; Controller mutators use edit_document;
         non-undoable writes (selection, preview, live-drag, test setup) use
         set_document_unbracketed.")

The assertion landed 2026-06-19 with the OP_LOG consolidation. IT DID NOT SWEEP
THE EXISTING CALLERS. One of them -- the Layers row click, syncing
`doc.selected_layer`, written 2026-05-01 when the call was legal -- was left
outside a transaction.

From that day, clicking any row in the Layers panel PANICKED a debug build. And
because the panic fires while `AppState` is mutably borrowed and the guard never
unwinds in wasm, the RefCell stayed poisoned for the life of the tab: every
subsequent event then failed with `RefCell already borrowed`, at five different
sites. The first panic is the only one that meant anything; the rest were echoes.

It survived six weeks because it is a `debug_assert`. Release strips it and
falls through to a self-bracketing path, which does not panic -- it silently
spends AN UNDO STEP ON A CLICK. Two unintended behaviours, and no test could see
either: this is wasm event-loop code behind a Dioxus runtime. 2824 Rust tests,
17 gates and a green CI had nothing to say. JYH found it by clicking, 2026-07-30.

A RUNTIME ASSERTION IS NOT A GATE. It fires only if someone runs the debug build
and reaches the line. This is the same claim, checked statically, on every build.

WHAT THIS GATE ASSERTS
----------------------
Every `.set_document(` call in jas_dioxus is BRACKETED: the enclosing function
opens a transaction (`begin_txn`, `with_txn`, `edit_document`, or is itself a
`*_txn` helper) before the call. A caller that is not gets flagged, and may only
pass by carrying a declared exemption with a reason.

WHAT IT DOES NOT COVER
----------------------
* Function-scoped, not path-scoped. A `begin_txn` inside one branch and a
  `set_document` in another reads as bracketed here. Narrowing that needs real
  control-flow analysis, and the runtime assertion still backs it up.
* It cannot tell an intent apart: `set_document_unbracketed` with the WRONG
  `NonUndoableIntent` is invisible here (the intent validators cover that).
* JasSwift's `setDocument` mirrors both halves of the discipline and is not
  scanned; a Swift twin is worth having and does not exist.
"""

import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "jas_dioxus" / "src"
LEDGER = REPO / "scripts" / "set_document_exemptions.json"

# Anything that opens a transaction, or means the caller is itself the bracket.
OPENERS = ("begin_txn", "with_txn", "edit_document", "journal_", "commit_txn")

# Calls that are NOT the bracketed channel and must not be counted as callers.
NOT_A_CALLER = re.compile(
    r"fn set_document|set_document_unbracketed|set_document_for_test")

CALL = re.compile(r"\.set_document\(")
FN_START = re.compile(r"^\s*(?:pub(?:\([a-z]+\))?\s+)?(?:async\s+)?fn\s+(\w+)")

# EXACT anti-vacuity floor -- guarding a PARSE, so it cannot be derived from
# that same parse without circularity (see check_lane_coverage.py's note on
# which floors may be derived and which must not).
MIN_CALLERS = 55


def enclosing_fn(lines, idx):
    """(name, start_line) of the function containing line `idx`."""
    for j in range(idx, -1, -1):
        m = FN_START.match(lines[j])
        if m:
            return m.group(1), j
    return "<file scope>", 0


def scan(sources):
    """sources: {relpath: text} -> (unbracketed, total_callers)."""
    unbracketed, total = [], 0
    for rel, text in sorted(sources.items()):
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if not CALL.search(line) or NOT_A_CALLER.search(line):
                continue
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            total += 1
            name, start = enclosing_fn(lines, i)
            # INCLUSIVE of the call's own line: `m.with_txn(|m| m.set_document(d))`
            # opens and uses the bracket in one expression, and excluding the
            # line made the most idiomatic bracketed form read as unbracketed.
            body = "\n".join(lines[start:i + 1])
            # The caller is bracketed if its enclosing function opens a
            # transaction before this line, or IS a journal/txn helper.
            if any(o in body for o in OPENERS) or any(o in name for o in OPENERS):
                continue
            unbracketed.append((rel, i + 1, name))
    return unbracketed, total


def load_exemptions():
    if not LEDGER.exists():
        return {}
    return json.loads(LEDGER.read_text(encoding="utf-8")).get("exemptions", {})


def load_sources():
    out = {}
    try:
        listed = subprocess.run(
            ["git", "ls-files", "jas_dioxus/src/*.rs", "jas_dioxus/src/**/*.rs"],
            cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        listed = [str(p.relative_to(REPO)) for p in SRC.rglob("*.rs")]
    for rel in listed:
        try:
            out[rel] = (REPO / rel).read_text(encoding="utf-8")
        except OSError:
            continue
    return out


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

def self_test():
    failures = []

    def check(name, src, want_flagged):
        flagged, _ = scan({"x.rs": src})
        got = [f[2] for f in flagged]
        if bool(got) != want_flagged:
            failures.append(f"  {name}: expected {'FLAG' if want_flagged else 'clean'}, got {got}")
        return got

    # (a) THE HISTORICAL DEFECT, in the shape it actually had: a document write
    #     inside an event handler, no bracket anywhere.
    check("a/the row-click defect", '''
fn on_row_click(st: &mut AppState) {
    if let Some(tab) = st.tab_mut() {
        let mut new_doc = tab.model.document().clone();
        new_doc.selected_layer = 3;
        tab.model.set_document(new_doc);
    }
}''', True)

    # (b) Properly bracketed -- every neighbour in that same panel.
    check("b/bracketed", '''
fn toggle_lock(st: &mut AppState) {
    tab.model.begin_txn();
    let doc = tab.model.document().toggling_element_lock(&p);
    tab.model.set_document(doc);
    tab.model.commit_txn();
}''', False)

    # (c) with_txn is a bracket too.
    check("c/with_txn", '''
fn edit(m: &mut Model) {
    m.with_txn(|m| m.set_document(doc));
}''', False)

    # (d) The unbracketed channel is a DIFFERENT function and must not be
    #     counted -- flagging it would make the honest call look like the bug.
    check("d/unbracketed channel", '''
fn sync(st: &mut AppState) {
    tab.model.set_document_unbracketed(new_doc, NonUndoableIntent::ActiveLayer);
}''', False)

    # (e) The definition itself is not a caller.
    check("e/definition", '''
impl Model {
    pub fn set_document(&mut self, doc: Document) {
        self.write_document(doc);
    }
}''', False)

    # (f) A mention in a COMMENT is not a call.
    check("f/comment", '''
fn note(st: &mut AppState) {
    // then commit via tab.model.set_document() so undo/redo works
    do_something();
}''', False)

    # (g) The live tree must be clean, or the production run below is the
    #     first anyone hears of it.
    live_unbracketed, live_total = scan(load_sources())
    ex = load_exemptions()
    undeclared = [f for f in live_unbracketed if f"{f[0]}::{f[2]}" not in ex]
    if undeclared:
        failures.append(f"  g: the live tree has undeclared unbracketed callers: {undeclared}")
    if live_total < MIN_CALLERS:
        failures.append(f"  g: only {live_total} callers found, floor is {MIN_CALLERS} "
                        f"-- a parse that stopped matching flags nothing")

    if failures:
        print("SELF-TEST FAILED -- the gate does not detect what it claims:")
        print("\n".join(failures))
        return 1
    print(f"self-test: the historical row-click defect is flagged in its real "
          f"shape; begin_txn / with_txn / journal helpers read as brackets; the "
          f"unbracketed channel, the definition and a comment mention are all "
          f"correctly NOT callers; {live_total} live callers parsed against a "
          f"floor of {MIN_CALLERS} -- gate proven RED where it must be.")
    return 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    unbracketed, total = scan(load_sources())
    ex = load_exemptions()

    if total < MIN_CALLERS:
        print(f"ERROR: only {total} `set_document` caller(s) found, below the "
              f"floor of {MIN_CALLERS}.", file=sys.stderr)
        print("A parse that stopped matching flags nothing, which is "
              "indistinguishable from a clean tree.", file=sys.stderr)
        return 1

    undeclared = [f for f in unbracketed if f"{f[0]}::{f[2]}" not in ex]
    if not undeclared:
        print(f"set_document bracketing: {total} caller(s), all inside a "
              f"transaction"
              + (f" ({len(ex)} declared exemption(s))" if ex else "") + ".")
        return 0

    print(f"ERROR: {len(undeclared)} `set_document` caller(s) are NOT inside a "
          f"transaction.", file=sys.stderr)
    print(file=sys.stderr)
    for rel, line, fn in undeclared:
        print(f"  {rel}:{line}  in `{fn}`", file=sys.stderr)
    print(file=sys.stderr)
    print("In a DEBUG build this panics -- and the panic fires while AppState is", file=sys.stderr)
    print("mutably borrowed, so the RefCell stays poisoned and every subsequent", file=sys.stderr)
    print("event in the tab fails too, at sites that have nothing to do with the", file=sys.stderr)
    print("cause. In RELEASE it silently spends an undo step.", file=sys.stderr)
    print(file=sys.stderr)
    print("Bracket it (begin_txn/commit_txn, with_txn, edit_document) if the edit", file=sys.stderr)
    print("is undoable. If it is NOT -- selection, preview, live-drag, the active", file=sys.stderr)
    print("layer -- use set_document_unbracketed with the matching intent.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
