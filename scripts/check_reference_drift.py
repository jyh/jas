#!/usr/bin/env python3
"""Gate: the Python REFERENCE may not drift from the shared corpus uncounted.

WHY THIS EXISTS
---------------
POLICY.md section 1 names the Python reference interpreter the executable
definition of the spec's semantics. The reference interpreter
(`workspace_interpreter/`) computes every document operation through the
shared domain layer under `jas/` (`document`, `geometry`, `algorithms`). The
five-port-parity freeze (2026-07-22) pinned the frozen Qt app. Its CI lane
checks out the tag, so the domain layer's own corpus harness,
`jas/cross_language_test.py`, has only ever been run against the TAG's corpus.

Since the tag, the active ports' domain and geometry layers took 192 commits,
and the reference's domain layer took one. Nothing noticed. Measured on
2026-09-21, the reference's own harness is 0/84 red at the tag and 29/84 red
at HEAD, and HEAD's reference code passes the tag's corpus 84/84. So every red
is the corpus moving on without the reference. A Group selected as one entry
could not be moved in the reference for seven weeks, and no lane could see it.

The rulings: council 2026-09-18 (the reference IS the spec's executable
meaning, so drift is a defect to close, and the reference carries a detector)
and council 2026-09-21 (the freeze protects the Qt APP; the shared domain
layer the live reference imports is not frozen by it).

WHAT IT ASSERTS
---------------
1. It runs the reference's corpus harness at HEAD, PER CASE, in a child
   `python -X utf8`. The corpus is UTF-8, and the harness opens fixtures with
   the locale codec, which is cp1252 on Windows.
2. The set of failing cases must equal `scripts/reference_drift_baseline.json`
   EXACTLY, counted per key:
     * a NEW failure is drift, and it reds at the commit that causes it;
     * a RETIRED failure is a stale baseline, and it stays red until the
       baseline is lowered with --write-baseline. So the drift count in the
       repo is always the true one. --write-baseline only SHRINKS: it refuses
       to add a key, and a new known failure is a hand edit a reviewer sees.
3. SCOPE is derived at run time, never listed by hand. The shared domain layer
   is the set of `jas/` PACKAGES the live reference imports: every import in
   `workspace_interpreter/` (tests excepted, lazy imports included), loaded,
   and the loaded modules read back. A harness method that reaches any OTHER
   `jas/` package (the frozen app: `workspace/`, `tools/`, `menu/`, ...),
   directly or through a helper, is labelled APP-REACHING.
   An app-reaching method is still RUN. Skipping it would hide shared-layer
   drift that the action and gesture corpora reach THROUGH the app, and
   silence is the failure this gate exists to prevent. Its cases are COUNTED
   SEPARATELY. The 2026-09-21 ruling lets the frozen app fall behind, so those
   cases are recorded and not owed. A NEW one still reds, because only a
   reader can tell app drift from shared-layer drift reached through the app.
   The derived closure and the derived app-reaching set must both equal the
   baseline's recorded ones, so scope cannot move silently.
4. Anti-vacuity: every harness method ran, at least one assertion was made,
   and the set of methods that made NO assertion equals the recorded set.

WHAT IT DOES NOT COVER -- printed beside every verdict
------------------------------------------------------
* Fixtures the harness does not enumerate. Its lists were written at the tag,
  and fixtures added since are not run.
* Behaviour the corpus never reaches. The three hand-confirmed divergences of
  row RO (GROUPMOVE, IDENTITY, clear_ids) were all outside it, so each fix
  lands its own fixture.
* Only `assertEqual` continues past a failure. Any other failing assertion,
  `fail()`, or exception stops its method and is recorded ONCE. Continuing
  would compare a variable left over from the previous case, and a per-case
  driver that did so read 73 phantom mismatches on 2026-09-21.
* Static scope: a method that reaches the app through `getattr` or data is not
  labelled app-reaching.

    python3 scripts/check_reference_drift.py --self-test
    python3 scripts/check_reference_drift.py
    python3 scripts/check_reference_drift.py --write-baseline   # shrink only
"""

import ast
import collections
import importlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
HARNESS_REL = ("jas", "cross_language_test.py")
HARNESS_CLASS = "CrossLanguageTest"
REFERENCE_DIR = "workspace_interpreter"
BASELINE_REL = ("scripts", "reference_drift_baseline.json")
KEY_MAX = 240

NOT_COVERED = (
    "NOT COVERED: fixtures the harness does not enumerate (its lists date from "
    "the tag); behaviour the corpus never reaches; a non-assertEqual failure "
    "stops its method")

BASELINE_DOC = [
    "Known failing cases of jas/cross_language_test.py at HEAD, per case.",
    "Written by scripts/check_reference_drift.py; see its docstring.",
    "A key is '<method> :: <first line of the failure>'; the value is how many",
    "times that key failed in one run.",
    "--write-baseline only SHRINKS this file. Adding a key is a hand edit.",
]


# ---------------------------------------------------------------- helpers

def _ascii(text: str) -> str:
    """Printable, deterministic ASCII: escapes, addresses masked, one line."""
    line = str(text).split("\n", 1)[0].strip()
    line = re.sub(r"0x[0-9a-fA-F]+", "0x?", line)
    return line.encode("ascii", "backslashreplace").decode("ascii")


def _key(method: str, label: str) -> str:
    return f"{method} :: {_ascii(label)}"[:KEY_MAX]


def _app_packages(jas_dir: pathlib.Path) -> set:
    return {p.name for p in jas_dir.iterdir()
            if p.is_dir() and (p / "__init__.py").is_file()}


def _import_targets(tree: ast.AST) -> list:
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out.extend(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            out.append(node.module)
    return out


# ---------------------------------------------------------------- the child

def closure_packages(root: pathlib.Path, app_pkgs: set) -> list:
    """The jas/ packages the live reference loads. Must run in the child."""
    ref = root / REFERENCE_DIR
    files = sorted(p for p in ref.rglob("*.py")
                   if "tests" not in p.relative_to(ref).parts)
    targets = set()
    modules = []
    for f in files:
        tree = ast.parse(f.read_text(encoding="utf-8"), filename=str(f))
        targets.update(t for t in _import_targets(tree)
                       if t.split(".")[0] in app_pkgs)
        rel = f.relative_to(root).with_suffix("")
        parts = rel.parts[:-1] if rel.name == "__init__" else rel.parts
        modules.append(".".join(parts))
    for name in modules + sorted(targets):
        importlib.import_module(name)
    jas_dir = os.path.realpath(root / "jas") + os.sep
    return sorted({n.split(".")[0] for n, m in list(sys.modules.items())
                   if getattr(m, "__file__", None)
                   and os.path.realpath(m.__file__).startswith(jas_dir)})


def harness_scope(harness: pathlib.Path, app_pkgs: set, in_pkgs: set):
    """(test methods, {app-reaching method: reason}) by static reading."""
    tree = ast.parse(harness.read_text(encoding="utf-8"), filename=str(harness))
    imported = {}
    for node in tree.body:
        if isinstance(node, ast.Import):
            for a in node.names:
                imported[(a.asname or a.name).split(".")[0]] = a.name.split(".")[0]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            for a in node.names:
                imported[a.asname or a.name] = node.module.split(".")[0]
    funcs = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    cls = next(n for n in tree.body
               if isinstance(n, ast.ClassDef) and n.name == HARNESS_CLASS)
    methods = {n.name: n for n in cls.body if isinstance(n, ast.FunctionDef)}

    def direct(fn):
        deps, calls = set(), set()
        for node in ast.walk(fn):
            if isinstance(node, ast.Name):
                if node.id in imported:
                    deps.add(imported[node.id])
                if node.id in funcs:
                    calls.add(("f", node.id))
            elif (isinstance(node, ast.Attribute)
                  and isinstance(node.value, ast.Name)
                  and node.value.id == "self" and node.attr in methods):
                calls.add(("m", node.attr))
        deps.update(t.split(".")[0] for t in _import_targets(fn))
        return deps, calls

    table = {("f", k): direct(v) for k, v in funcs.items()}
    table.update({("m", k): direct(v) for k, v in methods.items()})
    tests = sorted(k for k in methods if k.startswith("test_"))
    app_reaching = {}
    for t in tests:
        seen, stack, deps = set(), [("m", t)], set()
        while stack:
            node = stack.pop()
            if node in seen:
                continue
            seen.add(node)
            d, c = table[node]
            deps |= d
            stack.extend(c)
        frozen = sorted((deps & app_pkgs) - in_pkgs)
        if frozen:
            app_reaching[t] = "reaches jas/" + ", jas/".join(frozen) + " (the frozen app)"
    return tests, app_reaching


class _Abort(Exception):
    pass


def run_driver(root: pathlib.Path, out: pathlib.Path) -> int:
    root = root.resolve()
    jas_dir = root / "jas"
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(jas_dir))
    os.chdir(jas_dir)
    app_pkgs = _app_packages(jas_dir)
    closure = closure_packages(root, app_pkgs)
    harness = root.joinpath(*HARNESS_REL)
    tests, app_reaching = harness_scope(harness, app_pkgs, set(closure))

    spec = importlib.util.spec_from_file_location(harness.stem, harness)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[harness.stem] = mod
    spec.loader.exec_module(mod)
    cls = getattr(mod, HARNESS_CLASS)
    runtime = sorted(n for n in dir(cls)
                     if n.startswith("test_") and callable(getattr(cls, n)))
    if runtime != tests:
        raise SystemExit(f"harness methods differ: static {len(tests)}, "
                         f"runtime {len(runtime)}")

    state = {"method": None, "ordinal": 0}
    failing = collections.Counter()
    calls = collections.Counter()

    def assert_equal(self, first, second, msg=None):
        calls[state["method"]] += 1
        state["ordinal"] += 1
        if first == second:
            return
        label = msg if msg else f"assertEqual#{state['ordinal']}"
        failing[_key(state["method"], label)] += 1

    def fail(self, msg=None):
        calls[state["method"]] += 1
        raise _Abort(msg if msg else "fail()")

    def counted(orig):
        def wrapper(self, *args, **kwargs):
            calls[state["method"]] += 1
            return orig(self, *args, **kwargs)
        return wrapper

    for name in dir(cls):
        if (name.startswith("assert") and name != "assertEqual"
                and callable(getattr(cls, name))):
            setattr(cls, name, counted(getattr(cls, name)))
    cls.assertEqual = assert_equal
    cls.fail = fail

    executed = []
    for m in tests:
        state["method"], state["ordinal"] = m, 0
        inst = cls(m)
        try:
            inst.setUp()
            getattr(inst, m)()
        except _Abort as e:
            failing[_key(m, f"ABORT: {e}")] += 1
        except AssertionError as e:
            failing[_key(m, f"ASSERT: {type(e).__name__}: {_ascii(e)}")] += 1
        except Exception as e:  # noqa: BLE001 -- every exception is a case
            failing[_key(m, f"EXCEPTION: {type(e).__name__}: {_ascii(e)}")] += 1
        finally:
            try:
                inst.tearDown()
            except Exception as e:  # noqa: BLE001
                failing[_key(m, f"TEARDOWN: {type(e).__name__}: {_ascii(e)}")] += 1
        executed.append(m)

    result = {
        "closure_packages": closure,
        "harness_methods": tests,
        "app_reaching": app_reaching,
        "executed": executed,
        "assert_calls": sum(calls[m] for m in tests),
        "zero_assert_methods": sorted(m for m in tests if calls[m] == 0),
        "failing": dict(sorted(failing.items())),
    }
    out.write_text(json.dumps(result, indent=1, sort_keys=True, ensure_ascii=True)
                   + "\n", encoding="utf-8", newline="")
    return 0


# ---------------------------------------------------------------- the parent

def measure(root: pathlib.Path):
    """(result, None) or (None, why-unmeasurable)."""
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "result.json"
        proc = subprocess.run(
            [sys.executable, "-X", "utf8", str(pathlib.Path(__file__).resolve()),
             "--driver", str(root), str(out)],
            capture_output=True)
        if proc.returncode != 0 or not out.is_file():
            tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
            return None, (f"driver exited {proc.returncode}: "
                          + " | ".join(_ascii(t) for t in tail))
        return json.loads(out.read_text(encoding="utf-8")), None


def problems(result: dict, base: dict) -> list:
    """[(kind, message)] with kind in NEW / STALE / SCOPE / VACUOUS."""
    out = []
    if not result["executed"] or result["assert_calls"] == 0:
        out.append(("VACUOUS", f"{len(result['executed'])} method(s) ran, "
                               f"{result['assert_calls']} assertion(s) made"))
    if sorted(result["executed"]) != sorted(result["harness_methods"]):
        out.append(("VACUOUS", "the methods that ran are not the harness's methods"))
    if result["zero_assert_methods"] != base.get("zero_assert_methods", []):
        out.append(("VACUOUS", "methods making NO assertion changed: now "
                               f"{result['zero_assert_methods']}, baseline "
                               f"{base.get('zero_assert_methods', [])}"))
    if result["closure_packages"] != base.get("closure_packages"):
        out.append(("SCOPE", f"the live reference's jas/ packages are now "
                             f"{result['closure_packages']}, baseline "
                             f"{base.get('closure_packages')}"))
    if result["app_reaching"] != base.get("app_reaching"):
        now, was = set(result["app_reaching"]), set(base.get("app_reaching") or {})
        out.append(("SCOPE", f"app-reaching methods changed: +{sorted(now - was)} "
                             f"-{sorted(was - now)} (or a reason changed)"))
    cur, known = result["failing"], base.get("failing", {})
    for k in sorted(set(cur) | set(known)):
        c, b = cur.get(k, 0), known.get(k, 0)
        if c > b:
            where = ("THROUGH THE FROZEN APP -- decide: shared-layer drift (a "
                     "defect to close) or the app behind (record it by hand)"
                     if _method(k) in result["app_reaching"]
                     else "the shared layer: drift")
            out.append(("NEW", f"{k}  (x{c}, baseline x{b}) -- {where}"))
        elif c < b:
            out.append(("STALE", f"{k}  (x{c}, baseline x{b}) -- repaired; "
                                 "lower the baseline with --write-baseline"))
    return out


def _method(key: str) -> str:
    return key.split(" :: ", 1)[0]


def split_counts(result: dict) -> tuple:
    """(cases in shared-layer methods, cases in app-reaching methods)."""
    app = sum(v for k, v in result["failing"].items()
              if _method(k) in result["app_reaching"])
    return sum(result["failing"].values()) - app, app


def _summary(result: dict) -> str:
    owed, app = split_counts(result)
    return (f"{len(result['harness_methods'])} harness methods, all run "
            f"({len(result['app_reaching'])} reach the frozen app); "
            f"{result['assert_calls']} assertion call(s); failing cases: "
            f"{owed} in the SHARED LAYER (owed) + {app} through the FROZEN APP "
            f"(recorded, not owed); shared layer = "
            f"jas/{', jas/'.join(result['closure_packages'])}")


def check(root: pathlib.Path) -> int:
    base_path = root.joinpath(*BASELINE_REL)
    if not base_path.is_file():
        print(f"check_reference_drift: NO BASELINE at {'/'.join(BASELINE_REL)} "
              "-- run --write-baseline once")
        return 1
    result, why = measure(root)
    if result is None:
        print(f"check_reference_drift: UNMEASURABLE -- {why}")
        return 2
    base = json.loads(base_path.read_text(encoding="utf-8"))
    found = problems(result, base)
    print(f"check_reference_drift: {_summary(result)}")
    for kind, msg in found:
        print(f"  {kind}: {msg}")
    if found:
        kinds = sorted({k for k, _ in found})
        print(f"check_reference_drift: FAIL ({len(found)} problem(s): "
              f"{', '.join(kinds)})")
    else:
        print("check_reference_drift: OK -- the failing set equals the baseline exactly")
    print(f"  {NOT_COVERED}")
    return 1 if found else 0


def write_baseline(root: pathlib.Path) -> int:
    base_path = root.joinpath(*BASELINE_REL)
    result, why = measure(root)
    if result is None:
        print(f"check_reference_drift: UNMEASURABLE -- {why}")
        return 2
    if base_path.is_file():
        base = json.loads(base_path.read_text(encoding="utf-8"))
        refused = [(k, m) for k, m in problems(result, base) if k != "STALE"]
        if refused:
            print("check_reference_drift: REFUSED -- --write-baseline only SHRINKS; "
                  "these need a hand edit a reviewer can see:")
            for kind, msg in refused:
                print(f"  {kind}: {msg}")
            return 1
    body = {
        "doc": BASELINE_DOC,
        "closure_packages": result["closure_packages"],
        "app_reaching": result["app_reaching"],
        "zero_assert_methods": result["zero_assert_methods"],
        "failing": result["failing"],
    }
    base_path.write_text(json.dumps(body, indent=1, sort_keys=True, ensure_ascii=True)
                         + "\n", encoding="utf-8", newline="")
    print(f"check_reference_drift: baseline written -- {_summary(result)}")
    return 0


# ---------------------------------------------------------------- self-test

FIXTURE = {
    "jas/inpkg/__init__.py": "",
    # read by a BARE open(), as the real harness reads its fixtures
    "jas/utf8.txt": "caf\u00e9\n",
    "jas/inpkg/core.py": "def value():\n    return 1\n",
    "jas/apppkg/__init__.py": "",
    "jas/apppkg/ui.py": "def layout():\n    return 'app'\n",
    "workspace_interpreter/__init__.py": "",
    # the ONLY road to inpkg is a lazy import: a module-level scan misses it
    "workspace_interpreter/effects.py":
        "def run():\n    from inpkg.core import value\n    return value()\n",
    # a TEST importing the app must not widen the closure
    "workspace_interpreter/tests/__init__.py": "",
    "workspace_interpreter/tests/test_x.py": "from apppkg.ui import layout\n",
    "jas/cross_language_test.py": '''import unittest
from inpkg.core import value
from apppkg.ui import layout


def _helper_app():
    return layout()


class CrossLanguageTest(unittest.TestCase):
    def test_pass(self):
        self.assertEqual(value(), 1)

    def test_loop_two_fail(self):
        for name, got in [("a", 1), ("b", 2), ("c", 3)]:
            self.assertEqual(got, 1, f"case '{name}' failed")

    def test_abort_midloop(self):
        expected = {"known": 1, "unknown": 2, "known2": 1}
        actual = None
        for fn in ["known", "unknown", "known2"]:
            if fn.startswith("known"):
                actual = 1
            else:
                self.fail(f"Unknown function: {fn}")
            self.assertEqual(actual, expected[fn], f"vector {fn}")

    def test_exception(self):
        raise ValueError("boom at 0x7f00dead")

    def test_uses_app(self):
        self.assertEqual(layout(), "app")

    def test_helper_app(self):
        self.assertEqual(self._via(), "app")

    def _via(self):
        return _helper_app()

    def test_dup(self):
        for _ in range(2):
            self.assertEqual(1, 2, "same message")

    def test_nomsg(self):
        self.assertEqual(1, 1)
        self.assertEqual(1, 2)

    def test_zero(self):
        pass

    def test_app_fails(self):
        self.assertEqual(layout(), "qt", "app case")

    def test_reads_utf8(self):
        import os
        with open(os.path.join(os.path.dirname(__file__), "utf8.txt")) as f:
            self.assertEqual(f.read().strip(), "caf\\u00e9", "utf8 fixture")

    def test_other_assert(self):
        self.assertTrue(False, "truth")

    def test_unicode(self):
        self.assertEqual("x", "y", "caf\\u00e9 case")
''',
}

EXPECTED_FAILING = {
    "test_abort_midloop :: ABORT: Unknown function: unknown": 1,
    "test_app_fails :: app case": 1,
    "test_dup :: same message": 2,
    "test_exception :: EXCEPTION: ValueError: boom at 0x?": 1,
    "test_loop_two_fail :: case 'b' failed": 1,
    "test_loop_two_fail :: case 'c' failed": 1,
    "test_nomsg :: assertEqual#2": 1,
    "test_other_assert :: ASSERT: AssertionError: False is not true : truth": 1,
    "test_unicode :: caf\\xe9 case": 1,
}


def _build(td: pathlib.Path, files: dict) -> pathlib.Path:
    for rel, text in files.items():
        p = td / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8", newline="")
    (td / "scripts").mkdir(exist_ok=True)
    return td


def _run_cli(root: pathlib.Path, *args, env_extra=None):
    env = dict(os.environ, **(env_extra or {}))
    proc = subprocess.run(
        [sys.executable, str(pathlib.Path(__file__).resolve()), "--root", str(root),
         *args], capture_output=True, env=env)
    return (proc.returncode, proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def self_test() -> int:
    arms = []

    def arm(name, ok, detail=""):
        arms.append((name, bool(ok), detail))

    with tempfile.TemporaryDirectory() as td:
        root = _build(pathlib.Path(td), FIXTURE)
        result, why = measure(root)
        arm("driver measures the fixture", result is not None, why or "")
        if result is None:
            result = {"closure_packages": [], "app_reaching": {}, "executed": [],
                      "failing": {}, "zero_assert_methods": [],
                      "assert_calls": 0, "harness_methods": []}
        arm("closure = the lazy import, and a test's import does not widen it",
            result["closure_packages"] == ["inpkg"], result["closure_packages"])
        arm("app-reaching methods labelled, directly and through a helper",
            sorted(result["app_reaching"])
            == ["test_app_fails", "test_helper_app", "test_uses_app"]
            and all("jas/apppkg" in r for r in result["app_reaching"].values()),
            result["app_reaching"])
        arm("every in-scope method ran",
            result["executed"] == result["harness_methods"]
            and len(result["executed"]) == 13, result["executed"])
        arm("an app-reaching method is RUN, and its failure is COUNTED apart",
            result["failing"].get("test_app_fails :: app case") == 1
            and split_counts(result) == (sum(EXPECTED_FAILING.values()) - 1, 1),
            split_counts(result))
        arm("the failing set is exactly the expected one",
            result["failing"] == EXPECTED_FAILING,
            sorted(set(result["failing"]) ^ set(EXPECTED_FAILING)))
        arm("fail() STOPS its method: no stale-variable phantom",
            not any("vector unknown" in k or "vector known2" in k
                    for k in result["failing"]), sorted(result["failing"]))
        arm("a repeated key is COUNTED, not collapsed",
            result["failing"].get("test_dup :: same message") == 2)
        arm("zero-assertion methods are named",
            result["zero_assert_methods"] == ["test_exception", "test_zero"],
            result["zero_assert_methods"])
        arm("every key is ASCII",
            all(k.isascii() for k in result["failing"]))

        base = {"closure_packages": result["closure_packages"],
                "app_reaching": result["app_reaching"],
                "zero_assert_methods": result["zero_assert_methods"],
                "failing": dict(result["failing"])}
        arm("identical baseline: no problem", problems(result, base) == [])

        def kinds(b):
            return sorted({k for k, _ in problems(result, b)})

        missing = dict(base, failing={k: v for k, v in base["failing"].items()
                                      if "case 'c'" not in k})
        arm("a failure absent from the baseline is NEW", kinds(missing) == ["NEW"])
        extra = dict(base, failing=dict(base["failing"], **{"test_pass :: gone": 1}))
        arm("a baseline key that no longer fails is STALE", kinds(extra) == ["STALE"])
        lower = dict(base, failing=dict(base["failing"], **{"test_dup :: same message": 1}))
        arm("a count rising is NEW", kinds(lower) == ["NEW"])
        higher = dict(base, failing=dict(base["failing"], **{"test_dup :: same message": 3}))
        arm("a count falling is STALE", kinds(higher) == ["STALE"])
        arm("a moved closure is SCOPE",
            kinds(dict(base, closure_packages=["apppkg", "inpkg"])) == ["SCOPE"])
        arm("a moved app-reaching set is SCOPE",
            kinds(dict(base, app_reaching={"test_uses_app": "x"})) == ["SCOPE"])
        arm("a changed zero-assertion set is VACUOUS",
            kinds(dict(base, zero_assert_methods=["test_zero"])) == ["VACUOUS"])
        arm("nothing executed is VACUOUS",
            "VACUOUS" in {k for k, _ in problems(dict(result, executed=[]), base)})
        arm("ONE method silently not run is VACUOUS",
            "VACUOUS" in {k for k, _ in problems(
                dict(result, executed=result["executed"][:-1]), base)})
        arm("zero assertions is VACUOUS",
            "VACUOUS" in {k for k, _ in problems(dict(result, assert_calls=0), base)})

        # end to end through the CLI: the gate can pass, and it can fail
        rc, out, err = _run_cli(root, "--write-baseline")
        arm("--write-baseline creates the baseline", rc == 0, out + err)
        rc, out, err = _run_cli(root)
        arm("POSITIVE CONTROL: the gate passes on its own baseline",
            rc == 0 and "OK" in out and "NOT COVERED" in out, out + err)
        # Witnesses `-X utf8` wherever a Latin-1 locale exists (macOS has one);
        # where it does not, Python falls back to UTF-8 and the arm passes blind.
        rc, out, err = _run_cli(root, env_extra={"LC_ALL": "en_US.ISO8859-1",
                                                 "LANG": "en_US.ISO8859-1"})
        arm("the child reads the corpus as UTF-8 under a Latin-1 locale",
            rc == 0 and "OK" in out, out + err)
        bpath = root.joinpath(*BASELINE_REL)
        written = json.loads(bpath.read_text(encoding="utf-8"))
        arm("the written baseline is the driver's failing set",
            written["failing"] == EXPECTED_FAILING)
        trimmed = dict(written, failing={k: v for k, v in written["failing"].items()
                                         if "case 'b'" not in k})
        bpath.write_text(json.dumps(trimmed), encoding="utf-8", newline="")
        rc, out, err = _run_cli(root, env_extra={"PYTHONIOENCODING": "cp1252"})
        arm("NEW drift reds the gate, under cp1252, with no traceback",
            rc == 1 and "NEW: test_loop_two_fail :: case 'b' failed" in out
            and "NOT COVERED" in out and "Traceback" not in err, out + err)
        rc, out, err = _run_cli(root, "--write-baseline")
        arm("--write-baseline REFUSES to add a key",
            rc == 1 and "REFUSED" in out
            and "case 'b'" not in bpath.read_text(encoding="utf-8"), out + err)
        padded = dict(written, failing=dict(written["failing"], **{"test_pass :: gone": 1}))
        bpath.write_text(json.dumps(padded), encoding="utf-8", newline="")
        rc, out, err = _run_cli(root)
        arm("a repaired case reds until the baseline is lowered",
            rc == 1 and "STALE: test_pass :: gone" in out, out + err)
        rc, out, err = _run_cli(root, "--write-baseline")
        arm("--write-baseline SHRINKS",
            rc == 0 and "test_pass :: gone" not in bpath.read_text(encoding="utf-8"),
            out + err)

        broken = _build(pathlib.Path(td) / "broken", dict(
            FIXTURE, **{"workspace_interpreter/effects.py": "raise ImportError('no')\n"}))
        (broken / "scripts" / BASELINE_REL[1]).write_text(
            json.dumps(written), encoding="utf-8", newline="")
        rc, out, err = _run_cli(broken, env_extra={"PYTHONIOENCODING": "cp1252"})
        arm("an unimportable reference is UNMEASURABLE (rc 2), never a pass, "
            "and says so under cp1252 with no traceback",
            rc == 2 and "UNMEASURABLE" in out and "Traceback" not in err, out + err)

    failed = [a for a in arms if not a[1]]
    for name, ok, detail in arms:
        line = f"  {'ok  ' if ok else 'FAIL'} {name}"
        if not ok and detail:
            line += f"  -- {_ascii(detail)}"
        print(line)
    print(f"check_reference_drift self-test: {len(arms) - len(failed)}/{len(arms)} arms pass")
    return 1 if failed else 0


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--driver"]:
        return run_driver(pathlib.Path(args[1]), pathlib.Path(args[2]))
    root = REPO
    if "--root" in args:
        i = args.index("--root")
        root = pathlib.Path(args[i + 1]).resolve()
        del args[i:i + 2]
    if args == ["--self-test"]:
        return self_test()
    if args == ["--write-baseline"]:
        return write_baseline(root)
    if args:
        print(f"check_reference_drift: unknown arguments {args}")
        return 2
    return check(root)


if __name__ == "__main__":
    sys.exit(main())
