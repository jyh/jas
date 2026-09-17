#!/usr/bin/env python3
"""FFI counter-lock gate: a Rust test that crosses a recording export holds the lock.

WHY THIS EXISTS
---------------
`jas_dioxus/src/ffi_instr.rs` counts every crossing of the C surface in
process-global atomics. Its `test_lock::lock()` is the one lock over them, and
its own documentation states the law: every test that touches the counters,
in any module, holds the guard for its body. Nothing enforced that. Nine tests
created engines without it, and on 2026-09-17 jas main went red on Linux when
one of them (the widget-event corpus, 28 engines) crossed `jas_engine_new`
between the two reads of `ffi_instr`'s panicking-restore arm: EngineNew read 3
against a pre-read of 2. The same tree had passed on its PR. A race is a red
that only sometimes happens, so the law has to be checked where it is written.

WHAT IT ASSERTS
---------------
Over every `*.rs` under `jas_dioxus/src/`:

* A RECORDING EXPORT is an `extern "C" fn jas_*` whose body calls
  `ffi_instr::record`, `record_out` or `record_engine`.
* A RECORDING HELPER is any other non-test fn, in the same file, whose body
  calls a recording export by name.
* Every `#[test]` fn whose body calls a recording export, or a recording
  helper of its own file, also calls `test_lock::lock()` (or `serial()`,
  `ffi_instr`'s own alias for it).
* The recording-export count, the helper count, and the counts of locked and
  crossing tests are DERIVED and printed, and never compared to a typed number.

WHAT IT DOES NOT COVER, and why
-------------------------------
* One level of helper indirection, within one file. A helper that calls a
  helper is not followed.
* Macros are not expanded, and `#[cfg]` is not evaluated. A Windows-only test
  is checked as well, which is the intent: its lane races the same way.
* It checks that the lock is TAKEN, not that it is held for the whole body.

Run `python scripts/check_ffi_counter_lock.py`; `--self-test` proves the gate
can still go red.
"""

import argparse
import ast
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = pathlib.Path("jas_dioxus") / "src"

RECORD_CALL = re.compile(r"\bffi_instr::record(?:_out|_engine)?\s*\(")
EXPORT_FN = re.compile(r'extern\s+"C"\s+fn\s+(jas_\w+)\s*\(')
ANY_FN = re.compile(r"\bfn\s+(\w+)\s*(?:<[^>]*>)?\s*\(")
TEST_FN = re.compile(r"#\[test\]\s*(?:#\[[^\]]*\]\s*)*(?:pub\s+)?fn\s+(\w+)\s*\(")
LOCK_CALL = re.compile(r"\btest_lock::lock\s*\(\s*\)|\bserial\s*\(\s*\)")
RAW_STR = re.compile(r'b?r(#*)"')
CHAR_LIT = re.compile(r"b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]{1,6}\}|.)|[^\\'\n])'")


class Refusal(Exception):
    """The gate cannot judge. Never reported as a clean tree."""


def _skip(src: str, i: int) -> int:
    """If a comment or a string/char literal starts at `i`, the index just past
    it; otherwise `i`. Braces inside these are text, not structure."""
    if src.startswith("//", i):
        j = src.find("\n", i)
        return len(src) if j < 0 else j
    if src.startswith("/*", i):
        depth, j = 0, i
        while j < len(src):
            if src.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif src.startswith("*/", j):
                depth, j = depth - 1, j + 2
                if depth == 0:
                    return j
            else:
                j += 1
        return len(src)
    m = RAW_STR.match(src, i)
    if m:
        close = '"' + m.group(1)
        j = src.find(close, m.end())
        return len(src) if j < 0 else j + len(close)
    if src.startswith('"', i) or src.startswith('b"', i):
        j = i + (2 if src[i] == "b" else 1)
        while j < len(src):
            if src[j] == "\\":
                j += 2
            elif src[j] == '"':
                return j + 1
            else:
                j += 1
        return len(src)
    m = CHAR_LIT.match(src, i)
    if m:
        return m.end()
    return i


def body_after(src: str, pos: int) -> str:
    """The brace-matched body of the fn whose signature starts at `pos`, with
    comments and literals skipped."""
    i, depth, open_ = pos, 0, -1
    while i < len(src):
        j = _skip(src, i)
        if j != i:
            i = j
            continue
        c = src[i]
        if c == ";" and open_ < 0:
            return ""  # a declaration with no body
        if c == "{":
            if open_ < 0:
                open_ = i
            depth += 1
        elif c == "}" and open_ >= 0:
            depth -= 1
            if depth == 0:
                return src[open_:i + 1]
        i += 1
    raise Refusal(f"unbalanced braces after offset {pos}")


def calls(body: str, names) -> list:
    return sorted(n for n in names if re.search(r"\b" + re.escape(n) + r"\s*\(", body))


def census(files: dict):
    """files: {relpath: source}. Returns (findings, report)."""
    exports = set()
    for src in files.values():
        for m in EXPORT_FN.finditer(src):
            if RECORD_CALL.search(body_after(src, m.start())):
                exports.add(m.group(1))
    if not exports:
        raise Refusal("no recording export found; the census read nothing")
    findings, helpers_total, crossing, locked = [], 0, 0, 0
    for rel, src in sorted(files.items()):
        try:
            findings_rel = _file(rel, src, exports)
        except Refusal as e:
            raise Refusal(f"{rel}: {e}")
        findings += findings_rel[0]
        helpers_total += findings_rel[1]
        crossing += findings_rel[2]
        locked += findings_rel[3]
    return findings, {"exports": len(exports), "helpers": helpers_total,
                      "crossing": crossing, "locked": locked}


def _file(rel, src, exports):
    findings, crossing, locked = [], 0, 0
    tests = {m.start(): m.group(1) for m in TEST_FN.finditer(src)}
    test_names = set(tests.values())
    helpers = set()
    for m in ANY_FN.finditer(src):
        name = m.group(1)
        if name in test_names or name in exports:
            continue
        if calls(body_after(src, m.start()), exports):
            helpers.add(name)
    for pos, name in tests.items():
        body = body_after(src, pos)
        hit = calls(body, exports) + calls(body, helpers)
        if not hit:
            continue
        crossing += 1
        if LOCK_CALL.search(body):
            locked += 1
        else:
            findings.append((rel, name, ", ".join(hit[:3])))
    return findings, len(helpers), crossing, locked


def read_tree(root: pathlib.Path) -> dict:
    base = root / SRC
    files = {p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
             for p in sorted(base.rglob("*.rs"))}
    if not files:
        raise Refusal(f"no .rs files under {SRC.as_posix()}")
    return files


def main_live() -> int:
    try:
        findings, rep = census(read_tree(ROOT))
    except Refusal as e:
        print(f"check_ffi_counter_lock: REFUSED: {e}")
        return 2
    if findings:
        print(f"check_ffi_counter_lock: FAIL: {len(findings)} test(s) cross a "
              "recording export without ffi_instr::test_lock::lock()")
        for rel, name, hit in findings:
            print(f"  {rel}  {name}  (calls {hit})")
        print("  Take the guard first: let _counters = "
              "crate::ffi_instr::test_lock::lock();")
        return 1
    print(f"check_ffi_counter_lock: PASS: {rep['crossing']} test(s) cross one of "
          f"{rep['exports']} recording exports (or {rep['helpers']} same-file "
          f"helpers), and all {rep['locked']} hold the counter lock.")
    print("  LIMITS: one level of helper indirection, within a file; macros "
          "unexpanded and #[cfg] unevaluated; checks the lock is taken, not "
          "held for the whole body.")
    return 0


def self_test() -> int:
    failures, arms = [], 0

    def arm(name, ok):
        nonlocal arms
        arms += 1
        if not ok:
            failures.append(name)
            print(f"  FAILED: {name}")

    export = ('pub extern "C" fn jas_rec(x: u8) -> u8 {\n'
              '    ffi_instr::record(Crossing::X, 0, 0);\n    x\n}\n'
              'pub extern "C" fn jas_quiet() -> u8 { 0 }\n')

    def tree(tests: str, extra: str = "") -> dict:
        return {"jas_dioxus/src/ffi.rs": export + extra + "\nmod tests {\n" + tests + "}\n"}

    def judge(files):
        try:
            return census(files)
        except Refusal as e:
            return [("<refused>", str(e), "")], {}

    locked = ("    #[test]\n    fn ok() {\n        let _g = crate::ffi_instr::test_lock::lock();\n"
              "        jas_rec(1);\n    }\n")
    f, rep = judge(tree(locked))
    arm("a locked crossing test is GREEN", f == [])
    arm("its counts are the ones the fixture was built with",
        rep == {"exports": 1, "helpers": 0, "crossing": 1, "locked": 1})

    for label, tests, extra, want in (
            ("an unlocked direct crossing is RED",
             "    #[test]\n    fn bad() { jas_rec(1); }\n", "", ["bad"]),
            ("an unlocked crossing through a same-file helper is RED",
             "    #[test]\n    fn via() { go(); }\n",
             "fn go() { jas_rec(2); }\n", ["via"]),
            ("a test attribute with a second attribute is still read",
             "    #[test]\n    #[ignore]\n    fn late() { jas_rec(1); }\n", "", ["late"])):
        f, _ = judge(tree(tests, extra))
        arm(label, [x[1] for x in f] == want)

    for label, tests in (
            ("a test that calls only a non-recording export is GREEN",
             "    #[test]\n    fn q() { jas_quiet(); }\n"),
            ("ffi_instr's `serial()` alias counts as the lock",
             "    #[test]\n    fn s() { let _g = serial(); jas_rec(1); }\n"),
            ("a test that crosses nothing is GREEN",
             "    #[test]\n    fn n() { let x = 1; }\n")):
        f, _ = judge(tree(tests))
        arm(label, f == [])

    f, _ = judge({"jas_dioxus/src/ffi.rs": 'pub extern "C" fn jas_quiet() -> u8 { 0 }\n'
                  "#[test]\nfn t() { jas_quiet(); }\n"})
    arm("a tree with no recording export REFUSES",
        len(f) == 1 and "no recording export" in f[0][1])
    f, _ = judge({"jas_dioxus/src/ffi.rs": 'pub extern "C" fn jas_rec() {\n'
                  "    ffi_instr::record(Crossing::X, 0, 0);\n"})
    arm("unbalanced braces REFUSE", len(f) == 1 and "unbalanced" in f[0][1])
    with tempfile.TemporaryDirectory() as d:
        try:
            read_tree(pathlib.Path(d))
            refused = False
        except Refusal as e:
            refused = "no .rs files" in str(e)
    arm("an empty tree REFUSES", refused)

    # The live tree is read too, so a renamed record function cannot turn the
    # census into silence.
    _, live = judge(read_tree(ROOT))
    arm("the live tree has recording exports and locked crossing tests",
        live.get("exports", 0) > 0 and live.get("locked", 0) > 0)
    for label, text in (
            ("a brace in a string literal is text",
             'fn a() { let s = "{"; jas_rec(1); }'),
            ("a brace in a raw string is text",
             'fn a() { let s = r#"}"#; jas_rec(1); }'),
            ("a brace in a char literal is text, and a lifetime is not a char",
             "fn a<'x>(v: &'x u8) { let c = '{'; jas_rec(1); }"),
            ("an escaped quote in a char literal opens no string",
             "fn a() { let q = '" + chr(92) + "\"'; let o = '{'; jas_rec(1); }"),
            ("an escaped apostrophe in a char literal is one literal",
             "fn a() { let q = '" + chr(92) + "''; let o = '}'; jas_rec(1); }"),
            ("a brace in a comment is text",
             "fn a() { // }\n /* { */ jas_rec(1); }")):
        try:
            body = body_after(text, 0)
        except Refusal:
            body = "<refused>"
        arm(label, body.endswith("jas_rec(1); }"))

    # Every string this gate prints must survive the Windows lane's cp1252
    # console. Docstrings are exempt because nothing prints them.
    tree_ = ast.parse(pathlib.Path(__file__).read_text(encoding="utf-8"))
    docstrings = set()
    for n in ast.walk(tree_):
        if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef)):
            b = n.body
            if (b and isinstance(b[0], ast.Expr) and isinstance(b[0].value, ast.Constant)
                    and isinstance(b[0].value.value, str)):
                docstrings.add(id(b[0].value))
    bad = []
    strings = [n for n in ast.walk(tree_)
               if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    for n in strings:
        if id(n) in docstrings:
            continue
        try:
            n.value.encode("cp1252")
        except UnicodeEncodeError:
            bad.append(n.lineno)
    arm("every printed string survives a cp1252 console", not bad and len(strings) > 20)

    if failures:
        print(f"check_ffi_counter_lock SELF-TEST: FAILED {len(failures)} of {arms} arm(s)")
        return 1
    print(f"check_ffi_counter_lock SELF-TEST: PASSED {arms} arm(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    return self_test() if args.self_test else main_live()


if __name__ == "__main__":
    sys.exit(main())
