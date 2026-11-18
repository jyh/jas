#!/usr/bin/env python3
"""Every production reader of a journal transaction's `ops` is one this file names.

WHY (STATUS-jas row 154, ruled 2026-11-18 by the helm, arm B). Six engine
hosts write the document from a panel key with no `doc.*` verb: gradient,
stroke, properties, character, paragraph and opacity (`panel_behavior.rs`).
Their transactions journal with `ops: []` (OP_LOG.md, "Host-key transactions").
Undo does not read ops (whole-document snapshot stacks), so nothing a user can
undo changes. But a reader of `ops` sees those edits as EMPTY. Each reader named
in ALLOWED says how it treats `ops: []`. A NEW reader fails this gate, so the
person adding it must decide, here, whether empty ops are a correct answer for
it. If they are not, arm A (typed ops per host through `op_apply`) is required
first.

WHAT IS A READ: a line of production source matching `.ops` followed by a
non-identifier character. Excluded: `//` comments (`///` doc lines included),
Rust `#[cfg(test)] mod NAME { ... }` blocks (matched by brace span, ignoring
braces in strings, chars and comments), files declared `#[cfg(test)] mod X;` in
lib.rs, and everything outside `jas_dioxus/src` and `JasSwift/Sources`.

LIMITS, stated so a green is not read as more: the needle is textual. It also
counts other structs' `ops` fields (the live-element recorded ops are named in
ALLOWED for that reason), and it would miss a read spelled without `.ops`
(a destructuring `let Transaction { ops, .. }`). The count per file is EXACT
in both directions: a removed read fails too, so the list cannot go stale.

Usage: python scripts/check_ops_readers.py [--self-test]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

#: file (repo-relative) -> (exact count of read lines, how it treats `ops: []`).
ALLOWED = {
    "jas_dioxus/src/document/model.rs": (
        11, "the journal's own writer and transaction COALESCING: a transaction "
            "merges only when ops.len() == 1, so an empty-op transaction never "
            "coalesces (correct: a host-key edit is its own undo step); accept_proposal "
            "replays a PROPOSAL's ops (its own struct, op_apply-built)"),
    "JasSwift/Sources/Document/Model.swift": (
        20, "the same coalescing in Swift (ops.count == 1), the journal's writer, and "
            "acceptProposal replaying a proposal's ops"),
    "JasSwift/Sources/Document/OpLog.swift": (
        1, "the Transaction initialiser (stores ops; reads nothing)"),
    "jas_dioxus/src/recorder/core.rs": (
        1, "the RECORDER replays ops into a fixture and FLAGS an empty one as "
           "`opaque_transaction_without_ops` (a recorded host-key edit replays "
           "to nothing, loudly)"),
    "jas_dioxus/src/geometry/binary.rs": (
        1, "NOT the journal: a live element's recorded ops (its own struct)"),
    "jas_dioxus/src/geometry/live.rs": (
        1, "NOT the journal: a live element's recorded ops"),
    "jas_dioxus/src/geometry/test_json.rs": (
        1, "NOT the journal: a live element's recorded ops, serialised"),
    "JasSwift/Sources/Geometry/Binary.swift": (
        1, "NOT the journal: a live element's recorded ops"),
    "JasSwift/Sources/Geometry/LiveElement.swift": (
        2, "NOT the journal: a live element's recorded ops"),
    "JasSwift/Sources/Geometry/TestJson.swift": (
        1, "NOT the journal: a live element's recorded ops, serialised"),
}

READ_RE = re.compile(r"\.ops(?:[^A-Za-z0-9_]|$)")
TEST_MOD_DECL_RE = re.compile(r"#\[cfg\(test\)\]\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z0-9_]+)\s*;")


def strip_rust(src: str) -> str:
    """`src` with comments and every `#[cfg(test)] mod NAME { ... }` block
    blanked (newlines kept, so line numbers survive)."""
    out = list(src)
    n = len(src)
    i = 0
    # Pass 1: blank comments, and note string/char spans so braces in them are skipped.
    code = [True] * n
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "; code[k] = False
            i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
                code[k] = False
            i = j
        elif c == "r" and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")) \
                and re.match(r'r#*"', src[i:i + 40]):
            # a raw string r"..." / r#"..."#: no escapes, ends at `"` plus the same #s
            hashes = re.match(r'r(#*)"', src[i:]).group(1)
            close = '"' + hashes
            j = src.find(close, i + 2 + len(hashes))
            j = n if j < 0 else j + len(close)
            for k in range(i, j):
                code[k] = False
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            for k in range(i, min(j + 1, n)):
                code[k] = False
            i = j + 1
        elif c == "'" and i + 2 < n and (src[i + 2] == "'" or (src[i + 1] == "\\" and "'" in src[i + 2:i + 6])):
            j = src.find("'", i + 2 if src[i + 1] == "\\" else i + 2)
            for k in range(i, j + 1):
                code[k] = False
            i = j + 1
        else:
            i += 1
    # Pass 2: blank #[cfg(test)] mod NAME { ... } by brace span over code chars.
    for m in re.finditer(r"#\[cfg\(test\)\]\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+[A-Za-z0-9_]+\s*\{", src):
        if not code[m.start()]:
            continue
        depth, j = 0, m.end() - 1
        while j < n:
            if code[j] and src[j] == "{":
                depth += 1
            elif code[j] and src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        for k in range(m.start(), min(j + 1, n)):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def strip_swift(src: str) -> str:
    return "\n".join(re.sub(r"//.*$", "", line) for line in src.split("\n"))


def population(root: Path):
    """Production source files: (repo-relative path, stripped text)."""
    lib = root / "jas_dioxus/src/lib.rs"
    test_only = set()
    if lib.exists():
        for m in TEST_MOD_DECL_RE.finditer(lib.read_text(encoding="utf-8")):
            test_only.add(f"jas_dioxus/src/{m.group(1)}.rs")
    out = []
    for p in sorted((root / "jas_dioxus/src").rglob("*.rs")):
        rel = p.relative_to(root).as_posix()
        if rel in test_only:
            continue
        out.append((rel, strip_rust(p.read_text(encoding="utf-8"))))
    for p in sorted((root / "JasSwift/Sources").rglob("*.swift")):
        out.append((p.relative_to(root).as_posix(), strip_swift(p.read_text(encoding="utf-8"))))
    return out, sorted(test_only)


def reads(files):
    found = {}
    for rel, text in files:
        lines = [i + 1 for i, line in enumerate(text.split("\n")) if READ_RE.search(line)]
        if lines:
            found[rel] = lines
    return found


def check(root: Path, allowed=ALLOWED):
    files, test_only = population(root)
    if not files:
        return [f"FATAL: no production source found under {root.as_posix()} (an empty population passes everything)"], files, {}
    found = reads(files)
    problems = []
    for rel, lines in sorted(found.items()):
        if rel not in allowed:
            problems.append(f"NEW READER: {rel} reads a transaction's ops at line(s) {lines}. A host-key "
                            f"transaction journals with ops: [] (OP_LOG.md). Decide whether empty ops are a "
                            f"correct answer for this reader; if yes, add it to ALLOWED with that sentence; "
                            f"if no, arm A (typed ops per host) comes first (STATUS-jas row 154).")
        elif len(lines) != allowed[rel][0]:
            problems.append(f"COUNT MOVED: {rel} reads ops on {len(lines)} line(s) {lines}, ALLOWED says "
                            f"{allowed[rel][0]}. Restate the count and re-check the sentence.")
    for rel in sorted(set(allowed) - set(found)):
        problems.append(f"STALE: {rel} is ALLOWED ({allowed[rel][0]} read(s)) but reads none. Remove its row.")
    return problems, files, found


def self_test():
    import tempfile
    def tree(files):
        d = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            p = d / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text, encoding="utf-8", newline="")
        return d
    lib = "#[cfg(test)]\nmod cross_language_test;\n"
    base = {
        "jas_dioxus/src/lib.rs": lib,
        "jas_dioxus/src/model.rs": "fn f(t: &T) { t.ops.len(); }\n",
        "JasSwift/Sources/M.swift": "let n = t.ops.count\n",
    }
    allow = {"jas_dioxus/src/model.rs": (1, "x"), "JasSwift/Sources/M.swift": (1, "x")}
    arms = 0
    # 1. the clean tree passes
    p, f, _ = check(tree(base), allow); assert p == [], p; arms += 1
    # 2. a new reader in a new file fails, naming it
    t = dict(base, **{"jas_dioxus/src/replay.rs": "fn r(t: &T) { for o in &t.ops {} }\n"})
    p, _, _ = check(tree(t), allow); assert any("NEW READER: jas_dioxus/src/replay.rs" in x for x in p), p; arms += 1
    # 3. a read inside #[cfg(test)] mod tests { ... } is not counted, even past a brace in a string
    t = dict(base, **{"jas_dioxus/src/x.rs": 'fn a() {}\n#[cfg(test)]\nmod tests {\n    fn b() { let s = "}"; t.ops.len(); }\n}\n'})
    p, _, _ = check(tree(t), allow); assert p == [], p; arms += 1
    # 4. ...but a read AFTER that test module, back in production code, is counted
    t = dict(base, **{"jas_dioxus/src/x.rs": '#[cfg(test)]\nmod tests {\n    fn b() { let s = "}"; }\n}\nfn c(t: &T) { t.ops.len(); }\n'})
    p, _, _ = check(tree(t), allow); assert any("NEW READER: jas_dioxus/src/x.rs" in x for x in p), p; arms += 1
    # 4b. a raw string holding quotes and a brace inside the test module does not end it early
    t = dict(base, **{"jas_dioxus/src/r.rs": '#[cfg(test)]\nmod tests {\n    fn b() { let s = r#"{"a": "}"}"#; }\n    fn c(t: &T) { t.ops.len(); }\n}\n'})
    p, _, _ = check(tree(t), allow); assert p == [], p; arms += 1
    # 5. comments do not count (Rust //, ///, /* */ and Swift //)
    t = dict(base, **{"jas_dioxus/src/c.rs": "/// t.ops\n// t.ops\n/* t.ops */ fn z() {}\n",
                      "JasSwift/Sources/C.swift": "/// tPrev.ops.last\n"})
    p, _, _ = check(tree(t), allow); assert p == [], p; arms += 1
    # 6. a file declared #[cfg(test)] mod X; in lib.rs is out of the population
    t = dict(base, **{"jas_dioxus/src/cross_language_test.rs": "fn t(x: &T) { x.ops.len(); }\n"})
    p, _, _ = check(tree(t), allow); assert p == [], p; arms += 1
    # 7. an extra read in an allowed file fails (COUNT MOVED), and so does a removed one
    t = dict(base, **{"jas_dioxus/src/model.rs": "fn f(t: &T) { t.ops.len(); }\nfn g(t: &T) { t.ops.len(); }\n"})
    p, _, _ = check(tree(t), allow); assert any("COUNT MOVED: jas_dioxus/src/model.rs" in x for x in p), p; arms += 1
    t = dict(base, **{"jas_dioxus/src/model.rs": "fn f() {}\n"})
    p, _, _ = check(tree(t), allow); assert any("STALE: jas_dioxus/src/model.rs" in x for x in p), p; arms += 1
    # 8. `.ops_count` / `.opsList` are not reads (identifier boundary)
    t = dict(base, **{"jas_dioxus/src/n.rs": "fn f(t: &T) { t.ops_count; t.opsList; }\n"})
    p, _, _ = check(tree(t), allow); assert p == [], p; arms += 1
    # 9. an empty population is fatal, not a pass
    p, _, _ = check(tree({"README": "x"}), allow); assert p and p[0].startswith("FATAL"), p; arms += 1
    print(f"check_ops_readers --self-test: OK ({arms} arms: clean passes; a new reader, a read after a test "
          f"module, an extra and a missing read each fail; test modules, comments, test-only files and "
          f"identifier prefixes are not reads; an empty population is fatal)")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return 0
    problems, files, found = check(ROOT)
    if problems:
        print("check_ops_readers: FAIL")
        for p in problems:
            print("  " + p)
        return 1
    total = sum(len(v) for v in found.values())
    print(f"check_ops_readers: OK -- {total} read line(s) in {len(found)} file(s), every one ALLOWED with how it "
          f"treats ops: []; population {len(files)} production file(s). LIMIT: textual needle; a read not "
          f"spelled `.ops` is not seen, and non-journal `ops` fields are listed by name.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
