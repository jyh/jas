#!/usr/bin/env python3
"""A path becomes text with `as_posix()`, never with `str()` -- the separator
defect policed as a CLASS instead of one site at a time.

WHY THIS EXISTS
---------------
`str(pathlib.Path)` renders the NATIVE separator. On macOS and Linux that is
"/" and the string is indistinguishable from a POSIX key; on Windows it is "\\"
and the same expression yields different text. Any gate that KEYS findings,
baselines, or exclusions on that text therefore agrees with itself on the two
platforms that cannot see the difference and disagrees with everything on the
one that can.

This has now been found THREE TIMES, each time fixed as an instance:

  * scripts/check_swift_copy_sites.py:387 -- the original. Findings were keyed
    on `str(path)` while `swift_copy_sites_baseline.json` held POSIX keys, so
    on Windows all 25 known sites were reported simultaneously as NEW debt
    (backslash keys absent from the baseline) and as RETIRED debt (POSIX
    baseline rows matching nothing). The gate had been wrong for its whole
    life and CI never noticed: it was wired only into the ubuntu job, the one
    platform whose paths cannot express the defect.
  * scripts/genericity_check.py:187 -- the same separator, a different sink.
    Every `exclude_pattern` is "/"-anchored, so on Windows the exclusions
    silently no-opped and every count came back high by exactly the number of
    files they should have dropped. A wrong number, not an error.
  * scripts/check_element_dispatch.py:252 -- the same hazard, recorded where a
    key gets designed rather than where one broke. Its comment is the clearest
    statement of the class we have: "would ... miss every row both ways at
    once".

Three sightings, three local fixes, and NOTHING THAT FORBIDS THE FOURTH. The
lane-coverage gate (check_lane_coverage.py) answers the level above this one --
that every gate is watched on a platform where it could be wrong -- and it is
deliberately separator-blind, saying so in its own header. So the pattern
itself has been unpoliced. This file is the missing half: coverage says the
gate RUNS where it could break; this says the gate CANNOT break that way.

The defect is worth stating as a rule, because the instances look nothing alike:

    A path is a location; its text is a RENDERING of that location, and the
    rendering is platform-dependent. The moment rendered text is used as an
    IDENTITY -- a dict key, a baseline row, a regex subject, a comparison --
    the identity is platform-dependent too, and every platform still agrees
    with itself. Nothing fails. The numbers are merely wrong.

`as_posix()` renders the same text everywhere, which is why every fix above
was the same three-word edit.

WHAT IT SCANS
-------------
Git-tracked `*.py` under this repository, minus the FROZEN ports `jas/` and
`jas_ocaml/` (POLICY.md §1 -- they honour their tag, not HEAD). The file list
comes from `git ls-files`, which emits POSIX separators on every platform;
that is deliberate and is the same choice check_element_dispatch.py documents.
This gate must not commit the defect it polices, so no rendered path is ever
used as a key here: findings are keyed on the `git ls-files` string, and line
numbers are REPORTED but never keyed on (a key that moves when code moves is
its own kind of drift -- see check_element_dispatch.py's `key()`).

WHAT IT FLAGS
-------------
A path-valued expression turned into text, in any of five spellings:

    str(p)              "%s" % p            f"...{p}..."
    "{}".format(p)      os.fspath(p)

"Path-valued" is inferred structurally, not by NAME. That distinction is load-
bearing in this repository: `workspace_interpreter/effects.py` is full of
`str(path_expr)` where `path` means an ELEMENT path (a list of child indices in
the document tree) and has nothing to do with the filesystem. A name-matching
rule would report seven false positives there on its first run and be turned
off by the end of the week; self-test case (v) pins that file's shape green
forever. What the inference does understand is listed under WHAT IT DOES NOT
CATCH below -- read that section before trusting a green run.

The gate does not try to prove the text becomes a key. Proving that needs
dataflow, and sighting 1 renders in `scan_all` and keys in `baseline_problems`
two functions away. It forbids the RENDERING instead, because in this tree
there is always a better spelling: `as_posix()` when the string is DATA, and
passing the `Path` itself when it is an argument to the OS (`open`,
`read_text`, `subprocess.run(..., cwd=p)`). Outside the nine messages below,
no site in this tree renders a path for any purpose -- which is what makes the
blanket rule affordable here.

The one carve-out is a MESSAGE. Text printed for a human is read on the
platform that printed it, and native separators are correct there -- a Windows
reader wants to paste the path into a Windows shell. So a stringification
lying inside `print(...)`, `sys.stdout/stderr.write(...)`, a `logging` call,
`warnings.warn(...)`, a `raise`, or an `assert` message is allowed. All nine
allowed sites in the tree today are exactly that shape -- every one of them a
`print`, e.g. check_swift_copy_sites.py:483
`print(f"check_swift_copy_sites: no baseline at {BASELINE}")`. The green
summary line reports the count, so a jump in it is worth a look.

That carve-out carries its own guard, because a carve-out that can hide the
class is worse than no rule. If the rendering sits in a KEYING position -- a
dict subscript, a comparison, a `re.` subject, a `.startswith`/`.get`/`.pop`
argument -- it is flagged even inside a message. `print(known[f"{p}"])` reds.

WHAT IT DOES NOT CATCH -- read this before trusting it
------------------------------------------------------
* UNANNOTATED PARAMETERS. `def key(p: pathlib.Path): return str(p)` reds;
  `def key(p): return str(p)` does NOT. The inference is single-file and reads
  bindings and annotations, so a Path arriving through an unannotated
  parameter is invisible. This is the largest hole in the gate and it is
  cheap to close at the call site: annotate.
* LAUNDERING THROUGH A VALUE. A path stringified in one place and keyed in
  another; a rendering stored in a dict and read back out (self-test case (h)
  pins that miss deliberately). The analysis sees the RENDERING, not the
  journey -- which is enough for all three sightings, each of which rendered
  and keyed within a few lines, but is not a dataflow analysis.
* RENDERING PERFORMED BY A LIBRARY. `sorted(paths, key=str)` -- which silently
  makes the SORT ORDER platform-dependent, and is the nastiest member of this
  family -- and `"".join(map(str, paths))`. The `str` is not applied to a path
  expression at the site, so nothing here sees it. Neither occurs today.
* DYNAMIC CONSTRUCTION. `getattr(p, "__str__")()`, or `"%s" % p` where the
  format string is a variable rather than a literal.
* NON-PYTHON PORTS. Rust and Swift have their own version of this hazard
  (`Path::display()`, `URL.path`) and this gate says nothing about them.
* NON-PATH IDENTITIES that are equally platform-dependent: filesystem case
  folding, Unicode normalisation of filenames on macOS, `\\r\\n` in a golden.
  check_encoding_hygiene.py owns some of that ground; nobody owns the rest.
* WHETHER THE RENDERING IS EVEN A KEY. It does not try to prove that; see
  WHAT IT FLAGS. `f"{p!r}"` is flagged too -- `repr` is as separator-native as
  `str`, and if the intent was debugging output it belongs in a message, where
  the carve-out already allows it.
* WHETHER `as_posix()` IS RIGHT. It renders "/" always, which is correct for a
  key and wrong for an argument handed to `cmd.exe`. This gate cannot tell
  those apart; it only insists that `str()` is not the answer to either.

Deliberately NOT flagged, because their text is platform-INDEPENDENT by
construction: `PurePosixPath` and `PureWindowsPath` have a fixed flavour, so
`str(PurePosixPath("a/b"))` is "a/b" on every platform. `PurePosixPath` is the
right tool when a path-shaped key must be manipulated as a path.

EXEMPTIONS
----------
`scripts/path_keying_exemptions.json`, in the shape of
`scripts/widget_dispatch_exemptions.json`: keyed `relpath::expression` -- the
`git ls-files` relpath and the expression source, never the line number, which
moves when unrelated code moves. Two identical expressions in one file share a
key and are excused together; that is deliberate, and it means the reason must
be true of both. Each row carries a NON-EMPTY `reason`. A blank reason excuses
nothing (self-test case (y)) and a row matching no current finding is STALE and
reds (case (z)).
That second arm is not tidiness -- `swift:dropdown` in the widget file asserted
something false for months and cost this seat an evening building what already
existed. A declared exemption that outlives its condition is a claim that reads
as a decision.

The file is EMPTY today, and that is the strongest statement it can make: the
tree needs no exceptions to this rule.

ANTI-VACUITY FLOORS
-------------------
See FLOORS below. They are set EXACTLY at reality, per the house law proved by
mutation on 2026-07-29 (check_selection_invariant.py:63): "A floor with slack
is a floor with a hole exactly the size of the slack, and the hole admits
precisely the move the assertion exists to forbid." A scan that reaches no
files, or whose path-type inference silently stops recognising `Path(...)`,
reports zero findings -- which is byte-identical to a clean tree, and is how
every defect above survived every green suite it ever ran under.
"""

import ast
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SELF_REL = "scripts/check_path_keying.py"
EXEMPTIONS = REPO / "scripts" / "path_keying_exemptions.json"

# POLICY.md §1: frozen ports honour the parity tag, not HEAD. Matched on the
# first POSIX segment so `jas_flask` and `jas_dioxus` are NOT swept up.
FROZEN_PORTS = frozenset({"jas", "jas_ocaml"})

# --------------------------------------------------------------------------
# FLOORS -- exact, not slack. Each is the true count on the tree that
# introduced this gate; the comparison is `<`, so ADDING files or path
# constants stays green and losing them reds. Raise a number in the same
# commit that legitimately shrinks the tree, and be suspicious while you do it.
#
# EXPECTED_FILES guards the file walk: a `git ls-files` that returns a subset
# (wrong cwd, a pathspec typo, a submodule) reports a clean tree.
# EXPECTED_PATH_FILES and EXPECTED_PATH_NAMES guard the part that actually
# decides -- the path-type inference. If it stops recognising `Path(...)` (a
# renamed import, a new spelling, a bug in this file), every finding
# disappears and nothing else in this gate would notice. These two numbers are
# the only witness that the analysis is still awake.
#
# The counts INCLUDE this file (see tracked_python), so they do not move when
# it is staged. Verified by mutation on 2026-07-30: each of the three, lowered
# by one, reds -- self-test case (ab).
EXPECTED_FILES = 105
EXPECTED_PATH_FILES = 18
EXPECTED_PATH_NAMES = 60

# --------------------------------------------------------------------------
# Path-type inference
# --------------------------------------------------------------------------

# Constructors whose instances render with the NATIVE separator. PurePosixPath
# and PureWindowsPath are absent on purpose -- fixed flavour, platform-stable
# text, and PurePosixPath is the sanctioned way to hold a "/"-spelled key.
PATH_CTORS = frozenset({"Path", "PurePath", "PosixPath", "WindowsPath"})

# Methods that return another Path when called on one.
PATH_METHODS = frozenset({
    "resolve", "absolute", "expanduser", "with_suffix", "with_name",
    "with_stem", "joinpath", "relative_to", "readlink",
})

# Classmethods on a constructor name: `Path.cwd()`, `pathlib.Path.home()`.
PATH_CLASSMETHODS = frozenset({"cwd", "home"})

# Iteration over these yields Paths whatever the receiver is.
PATH_ITER_METHODS = frozenset({"glob", "rglob", "iterdir"})

# Attributes that are STRINGS, not Paths. Listing them is what keeps
# `str(p.name)` and `f"{p.suffix}"` green: `.name` is already text, and its
# text is the same on every platform.
STR_ATTRS = frozenset({"name", "stem", "suffix", "as_posix", "drive", "root"})

# Expressions that prove a name holds TEXT. A name bound to one of these
# anywhere in the module is never treated as a Path, however else it is bound.
# This is the false-positive guard that lets `workspace_interpreter/effects.py`
# keep its element-path variables.
STR_METHODS = frozenset({
    "as_posix", "join", "format", "strip", "lstrip", "rstrip", "lower",
    "upper", "replace", "removeprefix", "removesuffix",
})


def _dotted(node):
    """`sys.stderr.write` for an Attribute chain rooted at a Name, else None."""
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return ".".join(reversed(parts))
    return None


def _is_path_annotation(text):
    """True for `Path`, `pathlib.Path`, `Path | None`, `Optional[Path]`.

    False for `dict[str, pathlib.Path]` -- a container OF paths is not a path,
    and treating it as one is how a structural inference starts inventing
    findings. That exact annotation appears in check_swift_copy_sites.py.
    """
    t = text.strip().strip("'\"")
    if t.startswith("Optional[") and t.endswith("]"):
        t = t[len("Optional["):-1]
    parts = [p.strip() for p in t.split("|")]
    parts = [p for p in parts if p and p != "None"]
    return bool(parts) and all(p.rsplit(".", 1)[-1] in PATH_CTORS for p in parts)


class PathTypes:
    """Which names in ONE LEXICAL SCOPE hold a Path.

    Flow-INSENSITIVE within the scope: a name is path-typed if any binding
    makes it one and no binding makes it text. Coarser than real type
    inference, and chosen on purpose -- it needs no import resolution and
    works on a single file.

    SCOPED, though, and that part is not optional. The first draft resolved
    names across the whole module and immediately conflated
    check_swift_copy_sites.py's two `p`s: a Path in `load_fields` and a
    problem STRING in `check_baseline`. It reported the second as a rendered
    path, and the only thing hiding the false positive was that the line
    happens to sit inside a `print`. A gate whose accuracy depends on where
    its mistakes land is not accurate.
    """

    def __init__(self, nodes, params=(), inherited=(), inherited_lists=()):
        self.names = set(inherited)
        # Names holding a COLLECTION of Paths. Tracked separately because the
        # real sighting-2 shape is two statements: `files = sorted(p.glob(..))`
        # and then `[f for f in files if rx.search(str(f))]`. Without this the
        # comprehension target is untyped and the historical defect reads green
        # -- which the self-test caught on the first run of this gate.
        self.lists = set(inherited_lists)
        self._resolve(list(nodes), list(params))

    def _resolve(self, nodes, params):
        declared, textual = set(), set()
        for a in params:
            if a.annotation and _is_path_annotation(ast.unparse(a.annotation)):
                declared.add(a.arg)
        for node in nodes:
            if isinstance(node, ast.AnnAssign) and isinstance(
                    node.target, ast.Name) and _is_path_annotation(
                    ast.unparse(node.annotation)):
                declared.add(node.target.id)
            for tgt, val in self._bindings(node):
                if isinstance(tgt, ast.Name) and self._is_text(val):
                    textual.add(tgt.id)
        self.names = (self.names | declared) - textual
        # Fixpoint: `A = Path(x)` then `B = A / "y"` then `C = B.parent`
        # resolves regardless of the order the statements are walked in.
        for _ in range(8):
            grown, grown_lists = set(self.names), set(self.lists)
            for node in nodes:
                for tgt, val in self._bindings(node):
                    if not isinstance(tgt, ast.Name):
                        continue
                    if self.is_path(val):
                        grown.add(tgt.id)
                    elif self.is_path_iterable(val):
                        grown_lists.add(tgt.id)
                if isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                    if isinstance(node.target, ast.Name) and self.is_path_iterable(
                            node.iter):
                        grown.add(node.target.id)
            grown -= textual
            if grown == self.names and grown_lists == self.lists:
                break
            self.names, self.lists = grown, grown_lists

    @staticmethod
    def _bindings(node):
        if isinstance(node, ast.Assign):
            return [(t, node.value) for t in node.targets]
        if isinstance(node, (ast.AnnAssign, ast.AugAssign)) and node.value:
            return [(node.target, node.value)]
        if isinstance(node, ast.NamedExpr):
            return [(node.target, node.value)]
        if isinstance(node, ast.withitem) and node.optional_vars is not None:
            return [(node.optional_vars, node.context_expr)]
        return []

    def is_path_iterable(self, it):
        """Does iterating this expression yield Paths?"""
        if isinstance(it, ast.Call) and isinstance(it.func, ast.Name) \
                and it.func.id in ("sorted", "list", "set", "reversed", "tuple") \
                and it.args:
            it = it.args[0]
        if isinstance(it, ast.Call) and isinstance(it.func, ast.Attribute) \
                and it.func.attr in PATH_ITER_METHODS:
            return True
        if isinstance(it, (ast.ListComp, ast.SetComp, ast.GeneratorExp)):
            return self.is_path(it.elt)
        if isinstance(it, (ast.List, ast.Set, ast.Tuple)):
            return bool(it.elts) and all(self.is_path(e) for e in it.elts)
        if isinstance(it, ast.Name):
            return it.id in self.lists
        return False

    def _is_text(self, node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return True
        if isinstance(node, ast.JoinedStr):
            return True
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod):
            return isinstance(node.left, ast.Constant) and isinstance(
                node.left.value, str)
        if isinstance(node, ast.Attribute):
            return node.attr in STR_ATTRS
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Name) and f.id == "str":
                return True
            if isinstance(f, ast.Attribute) and f.attr in STR_METHODS:
                return True
        return False

    def is_path(self, node):
        """Is this expression a native-separator Path?"""
        if isinstance(node, ast.Name):
            return node.id in self.names
        if isinstance(node, ast.Attribute):
            return node.attr == "parent" and self.is_path(node.value)
        if isinstance(node, ast.Subscript):
            v = node.value
            return (isinstance(v, ast.Attribute) and v.attr == "parents"
                    and self.is_path(v.value))
        if isinstance(node, ast.IfExp):
            return self.is_path(node.body) or self.is_path(node.orelse)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            return self.is_path(node.left) or self.is_path(node.right)
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Name):
                return f.id in PATH_CTORS
            if isinstance(f, ast.Attribute):
                if f.attr in PATH_CTORS:
                    return True
                if f.attr in PATH_CLASSMETHODS:
                    base = _dotted(f.value)
                    return bool(base) and base.rsplit(".", 1)[-1] in PATH_CTORS
                if f.attr in PATH_METHODS:
                    return self.is_path(f.value)
            return False
        return False


# --------------------------------------------------------------------------
# Context classification
# --------------------------------------------------------------------------

# Sinks whose text a human reads on the platform that produced it.
MESSAGE_CALLS = frozenset({
    "print", "sys.stdout.write", "sys.stderr.write", "warnings.warn",
    "pytest.fail", "pytest.skip", "pytest.xfail",
})
LOG_ROOTS = frozenset({"logging", "log", "logger", "LOG", "LOGGER", "_log"})
LOG_METHODS = frozenset({
    "debug", "info", "warning", "warn", "error", "exception", "critical", "log",
})

# Methods that make their subject an IDENTITY -- lookup, containment, prefix
# and regex matching. A rendering reaching one of these is the defect even
# when it happens inside a message.
KEYING_METHODS = frozenset({
    "startswith", "endswith", "match", "search", "fullmatch", "sub", "subn",
    "split", "rsplit", "findall", "finditer", "index", "find", "count",
    "get", "pop", "setdefault", "add", "discard", "remove",
})


def _parent_map(tree):
    parents = {}
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parents[id(child)] = node
    return parents


def _is_message_call(node):
    if not isinstance(node, ast.Call):
        return False
    f = node.func
    if isinstance(f, ast.Name):
        return f.id in MESSAGE_CALLS
    if isinstance(f, ast.Attribute):
        dotted = _dotted(f)
        if dotted in MESSAGE_CALLS:
            return True
        root = dotted.split(".")[0] if dotted else None
        return f.attr in LOG_METHODS and root in LOG_ROOTS
    return False


def classify(node, parents):
    """"key", "message" or "plain" for where a rendering ends up.

    The NEAREST enclosing context wins, walking outward, so a keying position
    inside a message is still keying -- that is the guard on the carve-out.
    """
    child = node
    parent = parents.get(id(node))
    while parent is not None:
        if isinstance(parent, ast.Compare):
            if child is parent.left or child in parent.comparators:
                return "key"
        if isinstance(parent, ast.Subscript) and child is parent.slice:
            return "key"
        if isinstance(parent, ast.Dict) and child in parent.keys:
            return "key"
        if isinstance(parent, ast.Set):
            return "key"
        if isinstance(parent, ast.Attribute) and parent.attr in KEYING_METHODS:
            if child is parent.value:
                return "key"
        if isinstance(parent, ast.Call):
            f = parent.func
            if isinstance(f, ast.Attribute) and f.attr in KEYING_METHODS \
                    and child in parent.args:
                return "key"
            if _is_message_call(parent):
                return "message"
        if isinstance(parent, ast.Raise):
            return "message"
        if isinstance(parent, ast.Assert) and child is parent.msg:
            return "message"
        child, parent = parent, parents.get(id(parent))
    return "plain"


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------

class ParseFailure(Exception):
    """A scanned file did not parse.

    Raised rather than skipped: a file this gate cannot read contributes no
    findings, which is indistinguishable from a file with none.
    """


def _oneline(text, limit=110):
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[:limit - 3] + "..."


SCOPE_NODES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


def _own_nodes(scope):
    """(nodes belonging to this scope, nested scopes to recurse into).

    A `class` body is folded into the enclosing scope -- imprecise, but its
    methods are still visited as nested scopes, which is where the code is.
    """
    if isinstance(scope, ast.Lambda):
        stack = [scope.body]
    else:
        stack = list(scope.body)
    own, nested = [], []
    while stack:
        n = stack.pop()
        if isinstance(n, SCOPE_NODES):
            nested.append(n)
            continue
        own.append(n)
        stack.extend(ast.iter_child_nodes(n))
    return own, nested


def scan_source(rel, src):
    """Findings, allowed message renderings, and the inferred-name count."""
    try:
        tree = ast.parse(src, filename=rel)
    except SyntaxError as e:
        raise ParseFailure(f"{rel}: {e}") from e
    parents = _parent_map(tree)
    hits, seen = [], set()
    n_names = 0

    def add(node, value_node, form):
        # Keyed on the git-tracked POSIX relpath plus the expression source --
        # never on the line number, which moves when unrelated code moves.
        expr = _oneline(ast.unparse(node))
        key = f"{rel}::{expr}"
        if key in seen:
            return
        seen.add(key)
        hits.append({
            "file": rel, "key": key, "expr": expr, "form": form,
            "value": _oneline(ast.unparse(value_node), 60),
            "line": getattr(node, "lineno", 0),
            "context": classify(node, parents),
        })

    def visit_scope(scope, inherited, inherited_lists):
        nonlocal n_names
        own, nested = _own_nodes(scope)
        params = []
        if isinstance(scope, SCOPE_NODES):
            a = scope.args
            params = list(a.posonlyargs) + list(a.args) + list(a.kwonlyargs)
        types = PathTypes(own, params, inherited, inherited_lists)
        n_names += len(types.names - set(inherited))
        for node in own:
            scan_node(node, types)
        for child in nested:
            visit_scope(child, types.names, types.lists)

    def scan_node(node, types):
        if isinstance(node, ast.Call) and node.args:
            f = node.func
            name = f.id if isinstance(f, ast.Name) else _dotted(f)
            if name == "str" and types.is_path(node.args[0]):
                add(node, node.args[0], "str()")
            elif name in ("os.fspath", "fspath") and types.is_path(node.args[0]):
                # os.fspath is str() spelled longer and means the same thing.
                # If a site really does want the OS-native string, that is what
                # an exemption is for -- say so once, in words.
                add(node, node.args[0], "os.fspath()")
            elif isinstance(f, ast.Attribute) and f.attr == "format" \
                    and isinstance(f.value, ast.Constant) \
                    and isinstance(f.value.value, str):
                for a in list(node.args) + [k.value for k in node.keywords]:
                    if types.is_path(a):
                        add(node, a, ".format()")
                        break
        elif isinstance(node, ast.JoinedStr):
            for v in node.values:
                if isinstance(v, ast.FormattedValue) and types.is_path(v.value):
                    add(node, v.value, "f-string")
                    break
        elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod) \
                and isinstance(node.left, ast.Constant) \
                and isinstance(node.left.value, str):
            rhs = (node.right.elts if isinstance(node.right, ast.Tuple)
                   else [node.right])
            for r in rhs:
                if types.is_path(r):
                    add(node, r, "%-format")
                    break

    visit_scope(tree, (), ())
    return {
        "findings": [h for h in hits if h["context"] != "message"],
        "messages": [h for h in hits if h["context"] == "message"],
        "path_names": n_names,
    }


def tracked_python(repo=REPO):
    """Git-tracked `*.py` outside the frozen ports.

    `git ls-files` emits POSIX separators on every platform, which is the whole
    reason this gate can key on its own output without being an instance of
    what it forbids.
    """
    out = subprocess.run(
        ["git", "ls-files", "--", "*.py"], cwd=repo,
        capture_output=True, text=True, check=True).stdout
    files = [rel for rel in out.splitlines()
             if rel and rel.split("/")[0] not in FROZEN_PORTS]
    # This gate is shared Python and holds itself to its own rule, from the
    # run before it is staged. Including it unconditionally also keeps the
    # three floors below at ONE value across `git add`, instead of a value
    # that must be bumped by exactly one the moment the file is tracked --
    # which would be a floor edited for a reason unrelated to coverage, and
    # therefore a floor nobody reads carefully the next time.
    if SELF_REL not in files and (repo / SELF_REL).exists():
        files.append(SELF_REL)
    return sorted(files)


# --------------------------------------------------------------------------
# Exemptions and verdict
# --------------------------------------------------------------------------

def load_exemptions(path=EXEMPTIONS):
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    rows = data.get("exemptions", {})
    if not isinstance(rows, dict):
        raise ValueError("`exemptions` must be an object keyed 'relpath::expr'")
    return rows


def _reason(row):
    r = row.get("reason", "") if isinstance(row, dict) else ""
    return r.strip() if isinstance(r, str) else ""


def honoured(rows):
    """Only rows that actually say something suppress a finding.

    Separating this from the reason CHECK is not pedantry: the first draft of
    this gate suppressed on key presence alone, so a row with a blank reason
    reported "no reason given" AND hid the site it excused -- a row that
    excuses nothing was excusing everything. The self-test caught it.
    """
    return {k for k, v in rows.items() if _reason(v)}


def exemption_problems(rows, findings):
    out = []
    keys = {f["key"] for f in findings}
    for key, row in sorted(rows.items()):
        if not _reason(row):
            out.append(
                f"exemption {key!r} has no reason -- a blank reason excuses "
                f"nothing. Say why this rendering cannot be `as_posix()`, or "
                f"delete the row")
        elif key not in keys:
            out.append(
                f"exemption {key!r} matches no rendering in the tree -- the "
                f"site was fixed or moved. Delete the row: a declared "
                f"exception that outlives its condition reads as a decision "
                f"nobody has rechecked")
    return out


def floor_problems(n_files, n_path_files, n_path_names):
    out = []
    if n_files < EXPECTED_FILES:
        out.append(
            f"scanned {n_files} files, expected at least {EXPECTED_FILES}. "
            f"A short file list reports a clean tree. If Python files were "
            f"legitimately deleted, lower EXPECTED_FILES in the same commit")
    if n_path_files < EXPECTED_PATH_FILES or n_path_names < EXPECTED_PATH_NAMES:
        out.append(
            f"the path-type inference recognised {n_path_names} names in "
            f"{n_path_files} files, expected at least {EXPECTED_PATH_NAMES} in "
            f"{EXPECTED_PATH_FILES}. If it has stopped recognising `Path(...)` "
            f"this gate reports zero findings on any tree -- that is the "
            f"vacuous pass this floor exists to refuse, not a clean result")
    return out


def finding_problems(findings, rows):
    out = []
    excused = honoured(rows)
    for f in sorted(findings, key=lambda h: (h["file"], h["line"])):
        if f["key"] in excused:
            continue
        why = ("used as a key or comparison subject"
               if f["context"] == "key" else "rendered to text")
        out.append(
            f"{f['file']}:{f['line']}: {f['form']} on a path, {why} -- "
            f"`{f['expr']}` (the path is `{f['value']}`). On Windows this is "
            f"the same expression with backslashes. Use `.as_posix()` if the "
            f"text is data, or pass the Path itself if it is an argument")
    return out


# --------------------------------------------------------------------------
# self-test
# --------------------------------------------------------------------------

PRELUDE = """
import os, pathlib, re, subprocess, sys
from pathlib import Path, PurePosixPath
REPO = pathlib.Path(__file__).resolve().parent.parent
BASELINE = REPO / "scripts" / "baseline.json"
"""


def _findings(body, rel="probe.py"):
    return scan_source(rel, PRELUDE + body)["findings"]


def self_test():
    """Prove the gate reds on each class it claims and greens on the rest."""
    bad = []

    def check(name, body, want_red, expect_in=None):
        got = _findings(body)
        if bool(got) != want_red:
            verb = "RED" if want_red else "GREEN"
            bad.append(f"  {name}: expected {verb}, got "
                       f"{[g['expr'] for g in got] or 'GREEN'}")
        if expect_in and not any(expect_in in g["expr"] for g in got):
            bad.append(f"  {name}: message should mention {expect_in!r}, "
                       f"got {[g['expr'] for g in got]}")
        return got

    # ---- RED: the three spellings the task names, plus two more ----------
    check("a/str()", 'key = str(BASELINE)', True, "str(BASELINE)")
    check("b/f-string", 'rel = f"{BASELINE.relative_to(REPO)}"', True)
    check("c/%-format", 'rel = "%s" % BASELINE', True)
    check("d/.format()", 'rel = "{}".format(BASELINE)', True)
    check("e/os.fspath", 'rel = os.fspath(BASELINE)', True)

    # ---- the three sightings, in their historical shapes ------------------
    # Verbatim in shape, and checked against the real files by mutation on
    # 2026-07-30: restoring `str(path.relative_to(REPO))` in
    # check_swift_copy_sites.py and `exclude_re.search(str(f))` in
    # genericity_check.py both red on the actual source, at the actual lines.
    # (f) check_swift_copy_sites: a relpath rendered, then used as a baseline
    #     key. The rendering is what this gate sees; the keying is downstream.
    got = check("f/sighting-1 baseline key", """
def scan_all(fields):
    findings = []
    for path in sorted(REPO.rglob("*.swift")):
        rel = str(path.relative_to(REPO))
        findings.append({"file": rel})
    return findings
""", True)
    if got and got[0]["context"] != "plain":
        bad.append(f"  f: expected a plain rendering, got {got[0]['context']}")

    # (g) genericity_check: a "/"-anchored regex applied to a rendered path.
    got = check("g/sighting-2 regex subject", """
def measure():
    files = sorted(REPO.glob("jas_flask/*.py"))
    rx = re.compile("/tests/")
    return [f for f in files if not rx.search(str(f))]
""", True)
    if got and got[0]["context"] != "key":
        bad.append(f"  g: a regex subject is a key, got {got[0]['context']}")

    # (h) THE LIMIT, asserted rather than left to be discovered. Sighting 3's
    #     shape -- a path stored in a dict and rendered out of it later -- is
    #     GREEN here, because `site['file']` is a Subscript this analysis
    #     cannot type. Pinning the miss keeps WHAT IT DOES NOT CATCH honest: if
    #     someone widens the inference, this case flips and the header must be
    #     rewritten in the same commit.
    check("h/LIMIT: laundered through a dict",
          'site = {"file": REPO / "a.rs"}\nk = f"rust:{site[\'file\']}::fn"',
          False)

    # ---- RED: keying positions, including inside a message ---------------
    check("i/subscript key", 'known = {}\nv = known[str(BASELINE)]', True)
    check("j/comparison", 'want = "x"\nif str(BASELINE) == want:\n    pass', True)
    check("k/startswith", 'ok = str(BASELINE).startswith("scripts")', True)
    got = check("l/key inside a message", 'known = {}\nprint(known[f"{BASELINE}"])',
                True)
    if got and got[0]["context"] != "key":
        bad.append("  l: the message carve-out must not swallow a keying "
                   "position -- that is the hole that would make it useless")

    # ---- RED: the inference reaches loop variables and annotated params ---
    check("m/rglob loop var", """
for q in REPO.rglob("*.py"):
    k = str(q)
""", True)
    check("n/annotated param", """
def load(p: pathlib.Path) -> str:
    return str(p)
""", True)
    check("o/derived path", """
def go():
    root = REPO / "scripts"
    child = root.parent / "workspace"
    return str(child)
""", True)

    # ---- GREEN: the legitimate spellings ---------------------------------
    check("p/as_posix", 'rel = BASELINE.relative_to(REPO).as_posix()', False)
    check("q/as_posix in an f-string", 'rel = f"{BASELINE.as_posix()}"', False)
    check("r/PurePosixPath", 'rel = str(PurePosixPath("a/b"))', False)
    check("s/path used as a path", """
def go():
    text = BASELINE.read_text(encoding="utf-8")
    subprocess.run(["git", "status"], cwd=REPO, check=True)
    with open(BASELINE, "rb") as fh:
        return fh.read(), text
""", False)
    check("t/string attributes", 'n = str(BASELINE.name) + str(BASELINE.suffix)',
          False)
    check("u/human message", """
def go():
    print(f"no baseline at {BASELINE}")
    sys.stderr.write("wrote %s" % BASELINE)
    raise SystemExit(f"missing {BASELINE}")
""", False)

    # (v) THE FALSE POSITIVE THAT WOULD HAVE KILLED THIS GATE. In
    #     workspace_interpreter/effects.py a "path" is a list of child indices
    #     in the document tree. A name-matching rule reds here seven times on
    #     its first run and gets switched off; a structural one must not.
    check("v/element paths are not filesystem paths", """
def apply_effect(effect, ctx):
    path_expr = effect.get("path")
    path_val = evaluate(str(path_expr) if path_expr is not None else "", ctx)
    paths_expr = effect.get("paths")
    return ctx.get(str(path_val)), evaluate(str(paths_expr), ctx)
""", False)

    # (w) A name that holds a Path in one branch and text in another is not
    #     treated as a Path -- the demotion rule, without which (v) breaks the
    #     moment someone writes `path = Path(x)` elsewhere in that module.
    check("w/name reused for text", """
def go(flag):
    p = REPO / "a"
    p = "already/posix"
    return str(p)
""", False)

    # ---- the exemption mechanism -----------------------------------------
    finding = _findings('key = str(BASELINE)')[0]
    cases = [
        ("x/exemption with a reason",
         {finding["key"]: {"reason": "the OS wants native separators here"}},
         [finding], 0),
        ("y/blank reason excuses nothing",
         {finding["key"]: {"reason": "   "}}, [finding], 2),
        ("z/stale exemption reds",
         {"scripts/gone.py::str(P)": {"reason": "real words"}}, [finding], 2),
    ]
    for name, rows, finds, want in cases:
        n = len(exemption_problems(rows, finds)) + len(
            finding_problems(finds, rows))
        if n != want:
            bad.append(f"  {name}: expected {want} problem(s), got {n}")

    # ---- the anti-vacuity floors -----------------------------------------
    if floor_problems(EXPECTED_FILES, EXPECTED_PATH_FILES, EXPECTED_PATH_NAMES):
        bad.append("  aa/floor: exact reality must be GREEN")
    for label, args in (
            ("files", (EXPECTED_FILES - 1, EXPECTED_PATH_FILES, EXPECTED_PATH_NAMES)),
            ("path files", (EXPECTED_FILES, EXPECTED_PATH_FILES - 1, EXPECTED_PATH_NAMES)),
            ("path names", (EXPECTED_FILES, EXPECTED_PATH_FILES, EXPECTED_PATH_NAMES - 1))):
        if not floor_problems(*args):
            bad.append(f"  ab/floor: one fewer {label} must RED -- a floor "
                       f"with slack is a floor with a hole")

    # ---- REFUSAL rather than a clean report ------------------------------
    try:
        scan_source("broken.py", "def f(:\n")
        bad.append("  ac/refusal: an unparseable file must raise, not skip")
    except ParseFailure:
        pass

    if bad:
        print("SELF-TEST FAILED -- the gate does not do what it claims:")
        print("\n".join(bad))
        return 1
    print("self-test: 29 cases -- five renderings (str, f-string, %, .format, "
          "os.fspath), two historical sightings in their original shapes and "
          "the third pinned as a KNOWN MISS, keying positions including one "
          "hidden inside a message, inference through glob loops, path lists "
          "and annotated params, the legitimate spellings (as_posix, "
          "PurePosixPath, a Path used as a path, a human message), the "
          "element-path false positive that would have killed this gate, the "
          "exemption mechanism with blank and stale rows, all three exact "
          "floors mutated down by one, and refusal on an unparseable file.")
    return 0


# --------------------------------------------------------------------------

def main():
    if "--self-test" in sys.argv:
        return self_test()

    try:
        files = tracked_python()
    except (OSError, subprocess.CalledProcessError) as e:
        print(f"ERROR: cannot list git-tracked Python: {e}", file=sys.stderr)
        return 1

    findings, messages, n_path_files, n_path_names = [], 0, 0, 0
    try:
        for rel in files:
            result = scan_source(
                rel, (REPO / rel).read_text(encoding="utf-8"))
            findings += result["findings"]
            messages += len(result["messages"])
            n_path_names += result["path_names"]
            n_path_files += 1 if result["path_names"] else 0
        rows = load_exemptions()
    except (OSError, UnicodeDecodeError, ParseFailure, ValueError,
            json.JSONDecodeError) as e:
        print(f"ERROR: the scan could not complete: {e}", file=sys.stderr)
        print(file=sys.stderr)
        print("This gate REFUSES rather than passing when it cannot read its "
              "subject. A file it skips contributes no findings, which is "
              "byte-identical to a file with none -- and that silence is "
              "exactly how three separator defects survived every green suite "
              "they ever ran under.", file=sys.stderr)
        return 1

    problems = (floor_problems(len(files), n_path_files, n_path_names)
                + exemption_problems(rows, findings)
                + finding_problems(findings, rows))

    if not problems:
        print(f"path keying: {len(files)} shared Python files, "
              f"{n_path_names} path-typed names in {n_path_files} of them, "
              f"no path rendered to text outside a human message "
              f"({messages} allowed), {len(rows)} exemption(s).")
        return 0

    print("ERROR: a path is being rendered to text where the text is data.",
          file=sys.stderr)
    print(file=sys.stderr)
    for p in problems:
        print(f"  * {p}", file=sys.stderr)
    print(file=sys.stderr)
    print("`str(Path)` yields \"/\" here and \"\\\\\" on Windows. Every gate "
          "that keyed on it agreed with itself on both platforms it ran on "
          "and disagreed with the one it did not. See this file's header for "
          "the three sightings.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
