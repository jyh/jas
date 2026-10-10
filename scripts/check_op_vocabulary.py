#!/usr/bin/env python3
"""The op vocabulary is declared once, as data, and both ports agree with it (node A3b).

WHY THIS EXISTS
---------------
A proposal (docs/AGENT_API.md) carries primitive document ops. Until A3b those
ops were declared nowhere but as two `match` statements, one per active port,
so the vocabulary an agent may use was a property of the code, not of the
spec, and nothing said the two matches agreed. They did (51 and 51, the same
set, measured 2026-10-09), which is exactly the state that rots unwatched:
adding a verb to one port is a complete, compiling, green change.

WHAT IT ASSERTS
---------------
* Rust's `op_apply` and Swift's `opApply` each accept EXACTLY the verbs that
  test_fixtures/operations/op_vocabulary.json lists.
* Rust's `is_selection_only_verb` and Swift's `isSelectionOnlyVerb` each name
  EXACTLY the verbs that file classes `selection`.
* Anti-vacuity: each scanned set must hold at least MIN_VERBS verbs. Two empty
  sets compare equal, and a scanner that stopped matching would otherwise
  report agreement.

WHAT IT DOES NOT COVER
----------------------
* Each op's ARGUMENTS (the file says why they are not declared yet).
* The `history` class is checked against the file only. Neither port names
  that set in one place, so there is nothing to compare it with.
* It reads source text. A verb dispatched by a computed string, rather than
  a literal match arm, is invisible to it.
"""
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VOCAB = "test_fixtures/operations/op_vocabulary.json"
RUST = "jas_dioxus/src/document/op_apply.rs"
SWIFT = "JasSwift/Sources/Document/OpApply.swift"
MIN_VERBS = 40
MIN_SELECTION = 3


class Refusal(Exception):
    pass


def _body(src, start, label):
    i = src.find(start)
    if i < 0:
        raise Refusal(f"{label}: cannot find `{start}`")
    j = src.find("\n}\n", i)
    if j < 0:
        raise Refusal(f"{label}: cannot find the end of `{start}`")
    return src[i:j]


def _names(groups):
    out = set()
    for g in groups:
        out |= set(re.findall(r'"([a-z_0-9.]+)"', g))
    return out


def rust_verbs(src):
    body = _body(src, "pub fn op_apply(model", "rust op_apply")
    return _names(re.findall(r'^\s*((?:"[a-z_0-9.]+"\s*\|?\s*)+)(?:if [^=]*)?=>', body, re.M))


def swift_verbs(src):
    body = _body(src, "public func opApply(", "swift opApply")
    return _names(re.findall(r'^\s*case\s+((?:"[a-z_0-9.]+"\s*,?\s*)+):', body, re.M))


def rust_selection(src):
    body = _body(src, "fn is_selection_only_verb(", "rust is_selection_only_verb")
    return _names([body])


def swift_selection(src):
    body = _body(src, "func isSelectionOnlyVerb(", "swift isSelectionOnlyVerb")
    return _names([body])


def check(root):
    """Return a list of finding strings; raise Refusal if a subject is unreadable."""
    vocab = json.loads((root / VOCAB).read_text(encoding="utf-8"))["verbs"]
    rs = (root / RUST).read_text(encoding="utf-8")
    sw = (root / SWIFT).read_text(encoding="utf-8")
    declared = set(vocab)
    declared_sel = {k for k, c in vocab.items() if c == "selection"}
    bad_class = sorted(k for k, c in vocab.items() if c not in ("history", "selection", "edit"))
    sets = {
        "rust op_apply": (rust_verbs(rs), declared, MIN_VERBS),
        "swift opApply": (swift_verbs(sw), declared, MIN_VERBS),
        "rust is_selection_only_verb": (rust_selection(rs), declared_sel, MIN_SELECTION),
        "swift isSelectionOnlyVerb": (swift_selection(sw), declared_sel, MIN_SELECTION),
    }
    findings = [f"{VOCAB}: unknown class for {k}" for k in bad_class]
    for label, (got, want, floor) in sets.items():
        if len(got) < floor:
            raise Refusal(f"{label}: scanned {len(got)} verb(s), below the floor {floor}; "
                          f"the scanner, not the code, is the likelier fault")
        for v in sorted(got - want):
            findings.append(f"{label} accepts `{v}`, which {VOCAB} does not declare")
        for v in sorted(want - got):
            findings.append(f"{label} lacks `{v}`, which {VOCAB} declares")
    return findings, {k: len(v[0]) for k, v in sets.items()}


def _self_test():
    def scratch(edit):
        d = Path(tempfile.mkdtemp())
        for rel in (VOCAB, RUST, SWIFT):
            p = d / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text((ROOT / rel).read_text(encoding="utf-8"), encoding="utf-8", newline="")
        if edit:
            rel, old, new = edit
            p = d / rel
            s = p.read_text(encoding="utf-8")
            if s.count(old) != 1:
                raise AssertionError(f"self-test anchor not unique in {rel}: {old!r}")
            p.write_text(s.replace(old, new), encoding="utf-8", newline="")
        return d

    findings, counts = check(scratch(None))
    assert findings == [], findings
    arms = [
        ("a verb only Rust accepts", (RUST, '        "select_by_ids" => {', '        "zz_rust_only" => {}\n        "select_by_ids" => {'), "rust op_apply accepts `zz_rust_only`"),
        ("a verb only Swift accepts", (SWIFT, 'case "snapshot":', 'case "zz_swift_only": break\n    case "snapshot":'), "swift opApply accepts `zz_swift_only`"),
        ("a declared verb no port accepts", (VOCAB, '"verbs": {', '"verbs": {\n    "zz_declared": "edit",'), "rust op_apply lacks `zz_declared`"),
        ("a selection verb moved to edit", (VOCAB, '"select_all": "selection"', '"select_all": "edit"'), "rust is_selection_only_verb accepts `select_all`"),
        ("an unknown class", (VOCAB, '"paste": "edit"', '"paste": "editing"'), "unknown class for paste"),
    ]
    for name, edit, needle in arms:
        got, _ = check(scratch(edit))
        assert any(needle in f for f in got), f"self-test arm '{name}' did not red: {got}"
    # The anti-vacuity floor: a scanner that matches nothing must REFUSE, not agree.
    try:
        check(scratch((RUST, "pub fn op_apply(model", "pub fn op_apply_renamed(model")))
        raise AssertionError("self-test: an unreadable subject did not refuse")
    except Refusal:
        pass
    print(f"check_op_vocabulary SELF-TEST: OK ({len(arms)} planted defects redded, "
          f"1 unreadable subject refused, the real tree clean: {counts})")


def main(argv):
    if "--self-test" in argv:
        _self_test()
        return 0
    try:
        findings, counts = check(ROOT)
    except Refusal as e:
        print(f"check_op_vocabulary: REFUSED -- {e}")
        return 2
    if findings:
        for f in findings:
            print(f"check_op_vocabulary: {f}")
        print(f"check_op_vocabulary: FAIL ({len(findings)} finding(s))")
        return 1
    print(f"check_op_vocabulary: OK ({counts}). Not covered: op arguments; the history class "
          f"beyond the file; a verb dispatched by a computed string.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
