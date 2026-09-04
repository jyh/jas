#!/usr/bin/env python3
"""State-read declaration gate (VISION.md §11, the validator cross-reference
layer's *every `$state` read has a declaration* sub-check).

WHY THIS EXISTS
---------------
VISION.md §11 names four sub-checks of that layer. Two have an instrument
(``check_action_refs.py``, ``check_workspace_ids.py``); this was the third, and
until this file it was built NOWHERE -- ``workspace_interpreter/validator.py``'s
docstring said exactly that.

THE ITEM'S WORDING IS OLDER THAN THE SPELLING IT NAMES. The literal ``$state``
appears in ZERO workspace YAML files (it is FLASK_PARITY-era syntax; the only
surviving ``$`` form is the scope-qualified WRITE target ``$tool.<id>.<key>``
that ``effects._set_by_scoped_target`` strips a leading ``$`` from). A state
READ today is a dotted path inside an expression string:

    state.<key>            the global table
    panel.<key>            the active panel's table
    tool.<id>.<key>        one named tool's table
    dialog.<key>           the open dialog's table

THERE IS NO SCOPE SEARCH, AND THAT IS THE WHOLE RESOLUTION RULE.
``expr_eval._eval_path`` (``workspace_interpreter/expr_eval.py:103-110``) takes
``obj = ctx.get(segments[0])`` -- the FIRST segment names the namespace, and
there is no fallback to any other. A missing namespace, or a missing key inside
it, returns ``Value.null()``. So a read with no declaration does not raise and
does not warn: it is null, and null is a legal value for most of these keys.
``expr.evaluate`` logs a null result at DEBUG only (``expr.py:59-60``), which in
CI and in a shipped app is silence. A checkbox bound to an undeclared key
renders unchecked; a ``visible:`` bound to one renders hidden; an
``enabled_when`` bound to one greys the menu item out forever.

WHERE THE DECLARATIONS ARE, read out of the code
------------------------------------------------
``StateStore.eval_context`` (``state_store.py:914-958``) builds the namespaces:

* ``ctx["state"]``  -- the global table (``state_store.py:920``), seeded from
  ``workspace/state.yaml``'s ``state:`` block through
  ``loader.state_defaults``. 
* ``ctx["panel"]``  -- the ACTIVE panel's table only (``state_store.py:921-924``),
  seeded by ``init_panel`` from that panel's own ``state:`` block through
  ``loader.panel_state_defaults``. The Flask reference renderer builds the same
  namespace directly from the panel being rendered
  (``jas_flask/renderer.py:1493-1498``), and jas's dock does it through
  ``init_panel`` (``jas/workspace/dock_panel.py:786``,
  ``jas/panels/yaml_panel_view.py:123-133``). All of them mean the SAME table:
  the panel's own.
* ``ctx["tool"]``   -- ``{tool_id: table}`` (``state_store.py:926``), so
  ``tool.<id>.<key>`` names its tool in the path itself and resolves the same
  from anywhere. Seeded by ``init_tool`` from that tool file's ``state:``.
* ``ctx["dialog"]`` -- the OPEN dialog's table (``state_store.py:928-953``),
  seeded by the ``open_dialog`` effect from the dialog's ``state:`` block
  (``effects.py:982-1000``) and then by its ``init:`` writes
  (``effects.py:1017-1021`` -> ``state_store.set_dialog``, ``state_store.py:365``,
  which creates the key).

WHAT THIS GATE ASSERTS
----------------------
For every expression string in the workspace YAML sources the loader actually
reads, every ``state.`` / ``tool.<id>.`` read resolves to a declaration, and
every ``panel.`` / ``dialog.`` read whose owner the SOURCE names resolves inside
that owner. A read with no declaration in the one namespace its head segment
selects is a FINDING, reported with its ``file:line``, its key path, and the
declaration site that was searched.

WHAT IT DOES NOT COVER, and why
-------------------------------
* ``panel.<key>`` OUTSIDE ``workspace/panels/`` and ``dialog.<key>`` OUTSIDE
  ``workspace/dialogs/`` -- AMBIENT. ``eval_context`` binds whichever panel is
  active and whichever dialog is open when the expression runs; an
  ``actions.yaml`` effect that reads ``panel.selected_library`` is correct for
  the Brushes panel and null for every other one, and nothing in the source
  says which. Counted and printed on every run so the size of the uncovered
  surface is visible rather than inferred.
* Every other namespace head: ``param.`` (supplied by the call site's
  ``open_dialog``/``dispatch`` params), ``data.`` (workspace reference data set
  by ``set_data``), ``active_document.`` (computed in
  ``_active_document_view``), ``event.`` (the live input event),
  ``preferences.``, ``theme.``, ``workspace.``, ``panels.``, ``panes.``,
  ``selection.``. None of them is state; each has its own producer, and a gate
  over them is a different gate.
* Bare identifiers. ``foreach`` item variables, ``fun`` parameters, ``let``
  names, and a dialog property's SIBLING keys (``state_store.py:340-356`` binds
  every dialog key as a bare name inside a ``get:``/``set:``) all resolve
  without a namespace head. They are lexically bound and out of scope here.
* Effect ``set:`` TARGETS as declarations. ``StateStore.set`` creates a global
  key on first write, so a target could be argued to declare one -- but only
  from the moment the effect runs, and a read before it is still null. They are
  deliberately NOT counted as declarations. (Zero of today's reads need them;
  see the run's census.)
* ``workspace/tests/**`` -- corpus fixtures the loader never reads, exactly as
  in ``check_workspace_ids.py``.
* ``workspace/workspace.json`` -- GENERATED from the sources scanned here.

WHICH STRINGS ARE EXPRESSIONS -- the position rule, and its known over-match
---------------------------------------------------------------------------
There is no field vocabulary here, and that is deliberate. Expressions live in
``bind:`` values, ``visible:``, ``enabled_when:``/``checked_when:``,
``condition:``, an effect's ``if:``, ``foreach.source``, ``{{ }}`` regions of
``content``/``label``, a dialog's ``init:`` values and property ``get:``/
``set:`` -- and in EVERY payload field of EVERY effect, whose key names are the
effect's own vocabulary (``dx``, ``x1``, ``keep_selected``, ``ref_point``, one
per effect). A hand-listed set of key names would go stale the first time an
effect grew a field, and it would go stale SILENTLY: the unlisted field's reads
would simply not be checked.

So the rule is the other way round. EVERY scalar in the loadable YAML is a
candidate except the ``description:``/``summary:`` prose, and a candidate is
examined only if it mentions a state namespace head. A candidate that mentions
one and does NOT parse is a REFUSAL, not a skip -- so a new prose field, or a
new literal payload that happens to name a namespace, fails loudly instead of
being silently mis-read.

The known cost of that rule is over-match: a payload field that is consumed
LITERALLY rather than evaluated is examined anyway. One such field exists today
-- ``data.list_sort``'s ``path:``, which the JS engine reads as a literal dotted
path (``jas_flask/static/js/engine/effects.mjs:182-186``), not as an expression.
The over-match is recorded here rather than papered over with an exception,
because the string it lands on is broken for its own reason.

TIERS AND WARNINGS (not findings)
---------------------------------
* A panel/dialog key declared ONLY in ``init:`` and not in ``state:`` is a
  WARNING, not a finding: it does exist at runtime (``set_dialog`` /
  ``set_panel`` create it) but only after the init pass runs, and the Flask
  reference renderer's first paint builds its panel scope from
  ``panel_state_defaults`` alone -- ``state:`` only -- so the first render reads
  null. Today's tree has ZERO of these; the arm is driven by the self-test, not
  by the live tree, and that is said here rather than left to be assumed.
* A ``foreach as:``, ``fun`` parameter or ``let`` name equal to a namespace head
  SHADOWS that whole namespace for its subtree (the evaluator's context is one
  flat dict). There is no runtime diagnostic for it -- a shadowed read is just a
  different value -- so it is a WARNING. Today's tree has ZERO of these. Note
  what the warning does NOT do: reads inside the shadowed subtree are still
  resolved against the DECLARED table, because the shadowing binding's contents
  are a runtime value this gate cannot know. The warning says the resolution
  below it is unreliable; it does not repair it.

Run ``python scripts/check_state_reads.py`` to verify, ``--self-test`` to prove
the gate can still refuse and still reject.

WHY --self-test EXISTS
----------------------
The live judgement is "count the reads that failed to resolve", and a count has
no failure mode: an extractor that finds no reads reports no failures, which is
byte-identical to a workspace with none. So the self-test asserts, BEFORE
anything else, that an empty scan REFUSES; then that a scan shorter than git's
index REFUSES; then that an unparseable FILE refuses and an unparseable
EXPRESSION refuses NAMING IT; only then that a clean fixture is green with every
collector non-empty, that a planted undeclared read reds in each of the four
read spellings, that a right-name/wrong-scope read reds, that the ambient and
prose exclusions stay green, and that the two WARNING tiers warn without
redding. Three mutants close it out: an extractor that finds nothing must be
refused as vacuous, a resolver that accepts everything must stop redding the
plants, and deleting the prose exclusion must start redding prose.
"""

import argparse
import dataclasses
import os
import pathlib
import re
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / "workspace"

# The gate parses expressions with the INTERPRETER'S OWN parser. A second
# grammar here would drift from the one that ships, and the drift would be
# invisible: this gate would judge a string the runtime never sees that way.
#
# `as_posix()`, not `str()`: a sys.path entry must be a string (a Path is
# ignored by the path finder), and `str(Path)` renders backslashes on Windows,
# which is exactly the keying-on-a-rendered-path shape check_path_keying.py
# exists to refuse. CPython's import machinery accepts forward slashes on every
# platform. check_path_keying.py caught this line on its first CI run.
sys.path.insert(0, ROOT.as_posix())
from workspace_interpreter.expr_parser import Path as ExprPath  # noqa: E402
from workspace_interpreter.expr_parser import (  # noqa: E402
    Assign, Lambda, Let, parse,
)

# The loader's own directory vocabulary (workspace_interpreter/loader.py).
KEYED_SUBDIRS = ("panels", "tools", "concepts")
MERGED_SUBDIRS = ("dialogs", "templates")
LOADED_SUBDIRS = KEYED_SUBDIRS + MERGED_SUBDIRS
YAML_SUFFIXES = (".yaml", ".yml")

# The four namespace heads that name a STATE table. Every other head has a
# different producer -- see WHAT IT DOES NOT COVER.
STATE_HEADS = ("state", "panel", "tool", "dialog")

# A string is worth parsing only if it mentions one of those heads followed by
# a dot. `(?<![\w.])` keeps `active_document.panel` and `foo.state.bar` out: a
# head is only a head at the START of a path.
HEAD_RE = re.compile(r"(?<![\w.])(" + "|".join(STATE_HEADS) + r")\.")

# `{{ }}` interpolation regions, the same pattern `expr.evaluate_text` uses.
INTERP_RE = re.compile(r"\{\{(.+?)\}\}")

# Keys whose values are ENGLISH, by project law (.claude/CLAUDE.md: "the
# English description should be comprehensive but still human-readable"). Prose
# mentions `state.rotate_*` and `dialog.color` freely and none of it is
# evaluated. The exclusion is load-bearing in BOTH directions and the self-test
# drives it both ways: prose containing a bogus read must stay GREEN, and
# deleting this set must make it RED.
PROSE_KEYS = ("description", "summary")

# Namespace heads that exist but are not state tables. Listed so the census can
# print what it stepped over instead of leaving it to be inferred from silence.
NON_STATE_HEADS = ("param", "data", "active_document", "event", "preferences",
                   "theme", "workspace", "panels", "panes", "selection")


class Refusal(Exception):
    """The gate cannot make a judgement. Distinct from a FINDING on purpose: a
    refusal means the instrument is not measuring, and it must never be
    reported as a clean tree."""


# ── node helpers (composed YAML nodes, so every site carries a line) ───────

def _is_map(node):
    return isinstance(node, yaml.MappingNode)


def _is_seq(node):
    return isinstance(node, yaml.SequenceNode)


def _pairs(node):
    """[(key_str, key_node, value_node)] for a mapping node, in file order."""
    if not _is_map(node):
        return []
    return [(k.value, k, v) for k, v in node.value
            if isinstance(k, yaml.ScalarNode)]


def _items(node):
    return list(node.value) if _is_seq(node) else []


def _get(node, key):
    for k, _kn, v in _pairs(node):
        if k == key:
            return v
    return None


def _scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None


def _site(where, node):
    """`file:line` for a node. Line numbers are REPORTED, never keyed on."""
    return f"{where}:{node.start_mark.line + 1}"


def _keys_of(node):
    """The declared key names of a mapping node, as a set. A non-mapping (an
    absent block, or a scalar someone wrote by mistake) declares nothing."""
    return {k for k, _kn, _v in _pairs(node)}


def _entity_id(root, relpath):
    """The key a keyed-subdir file is filed under: its declared ``id``, else
    its filename stem (loader.py: ``part.get("id", splitext(fname)[0])``)."""
    declared = _scalar(_get(root, "id")) if _is_map(root) else None
    if isinstance(declared, str):
        return declared
    return pathlib.PurePosixPath(relpath).stem


# ── expression -> the state paths it reads ────────────────────────────────

def ast_paths(node, out, shadows):
    """Collect every ``Path`` node's segments, plus every bare name BOUND in
    the expression that shadows a namespace head.

    Recursion is GENERIC over dataclass fields rather than a hand-written case
    per node type: a node type added to the grammar is then walked by this gate
    on the day it lands, instead of being silently skipped by a match arm
    nobody remembered to extend."""
    if isinstance(node, ExprPath):
        out.append(tuple(node.segments))
        return
    if isinstance(node, Lambda):
        for p in node.params:
            if p in STATE_HEADS:
                shadows.append(p)
    elif isinstance(node, Let):
        if node.name in STATE_HEADS:
            shadows.append(node.name)
    elif isinstance(node, Assign):
        if node.target in STATE_HEADS:
            shadows.append(node.target)
    if dataclasses.is_dataclass(node):
        for f in dataclasses.fields(node):
            ast_paths(getattr(node, f.name), out, shadows)
    elif isinstance(node, (list, tuple)):
        for item in node:
            ast_paths(item, out, shadows)


def expressions_in(text):
    """The expression strings inside one YAML scalar.

    A string carrying ``{{ }}`` is INTERPOLATION -- ``evaluate_text`` evaluates
    only the regions inside the braces and treats the rest as literal text -- so
    only those regions are expressions. Anything else in an expression position
    is one whole expression."""
    if "{{" in text:
        return [m.group(1).strip() for m in INTERP_RE.finditer(text)]
    return [text]


def extract_reads(text):
    """``(reads, shadows, error)`` for one YAML scalar.

    ``reads`` is a list of segment tuples whose head is a state namespace.
    ``error`` is a parse-failure message when a string that MENTIONS a state
    head does not parse -- the gate cannot judge such a string, and it must not
    count as clean."""
    reads, shadows = [], []
    for expr in expressions_in(text):
        if not HEAD_RE.search(expr):
            continue
        try:
            ast = parse(expr.strip())
        except Exception as e:                       # ParseError and lexer errors
            return reads, shadows, f"{e.__class__.__name__}: {e}"
        found = []
        ast_paths(ast, found, shadows)
        for segs in found:
            if segs and segs[0] in STATE_HEADS:
                reads.append(segs)
    return reads, shadows, None


# ── the declaration tables ────────────────────────────────────────────────

class Decls:
    """Every declaration the loader would seed a namespace with, in two tiers.

    TIER 1 is a ``state:`` block: present from construction, in every port.
    TIER 2 is an ``init:`` key with no ``state:`` entry: created only when the
    init pass runs (``set_dialog`` / ``set_panel``), so the first render of the
    Flask reference renderer -- whose panel scope is ``panel_state_defaults``,
    ``state:`` alone -- reads null."""

    def __init__(self):
        self.global_ = set()
        self.panel, self.panel_init = {}, {}
        self.tool = {}
        self.dialog, self.dialog_init = {}, {}
        self.sites = {}          # ("panel", id) -> file:line of the state: block

    def count(self, which):
        if which == "global":
            return len(self.global_)
        table = getattr(self, which)
        return sum(len(v) for v in table.values())


def collect_declarations(composed):
    d = Decls()
    for relpath, node in sorted(composed.items()):
        parts = relpath.split("/")
        if len(parts) == 2:
            # loader: top-level YAML files merge with `data.update`, so the
            # global `state:` block is whichever file carries the key.
            block = _get(node, "state")
            if block is not None:
                d.global_ |= _keys_of(block)
                d.sites[("state", "")] = _site(relpath, block)
            continue
        subdir = parts[1] if len(parts) == 3 else None
        if subdir == "panels":
            pid = _entity_id(node, relpath)
            st = _keys_of(_get(node, "state"))
            init = _keys_of(_get(node, "init"))
            d.panel[pid] = st
            d.panel_init[pid] = init - st
            d.sites[("panel", pid)] = _site(relpath, node)
        elif subdir == "tools":
            tid = _entity_id(node, relpath)
            d.tool[tid] = _keys_of(_get(node, "state"))
            d.sites[("tool", tid)] = _site(relpath, node)
        elif subdir == "dialogs":
            # loader: `merged.update(part)` -- each TOP-LEVEL key is a dialog.
            for did, _kn, spec in _pairs(node):
                st = _keys_of(_get(spec, "state"))
                init = _keys_of(_get(spec, "init"))
                d.dialog[did] = st
                d.dialog_init[did] = init - st
                d.sites[("dialog", did)] = _site(relpath, spec)
    return d


# ── the report ────────────────────────────────────────────────────────────

class Report:
    def __init__(self):
        self.counts = {}
        self.findings = []
        self.warnings = []
        self.unreadable = []
        self.decls = Decls()

    def bump(self, collector, n=1):
        self.counts[collector] = self.counts.get(collector, 0) + n

    def finding(self, kind, read, site, keypath, searched, why):
        self.findings.append({"kind": kind, "read": read, "site": site,
                              "keypath": keypath, "searched": searched,
                              "why": why})

    def warn(self, kind, read, site, keypath, why):
        self.warnings.append({"kind": kind, "read": read, "site": site,
                              "keypath": keypath, "why": why})


# The collectors that must find something. A dead one reports no failures in
# its namespace, which is indistinguishable from a namespace with none.
COLLECTORS = ("scalars", "expr-strings",
              "read-state", "read-panel", "read-tool", "read-dialog",
              "decl-global", "decl-panel", "decl-tool", "decl-dialog")

# Printed on a passing run beside the collectors, but allowed to be zero: an
# uncovered surface can legitimately be empty, and requiring it non-empty would
# make emptying it a failure.
CENSUS = ("ambient-panel", "ambient-dialog", "warn-init-tier", "warn-shadow")

# The `get:` / `set:` position inside a dialog's `state:` block. The bindings
# there are NOT eval_context's: `get_dialog` / `set_dialog`
# (state_store.py:340-356 and :380-400) build a local scope of the dialog's own
# keys as BARE names plus `panel`, `state`, `active_document` and `param` -- and
# NEITHER `dialog` NOR `tool`. A `dialog.x` read inside a getter resolves
# `ctx.get("dialog")` to None and is null however well `x` is declared.
PROP_POS_RE = re.compile(r"^/[^/]+/state/[^/]+$")
PROP_UNBOUND = ("dialog", "tool")


def _resolve(report, segs, site, keypath, owner, in_prop):
    """Judge ONE read against the one namespace its head segment selects."""
    head = segs[0]

    if in_prop and head in PROP_UNBOUND:
        report.finding(
            "prop-scope", ".".join(segs), site, keypath,
            "the dialog property's local scope",
            f"a dialog `get:`/`set:` expression is evaluated against "
            f"get_dialog/set_dialog's OWN local scope (state_store.py:340-356), "
            f"which binds the dialog's keys as BARE names plus panel/state/"
            f"active_document/param -- and no {head!r} key at all, so this "
            f"resolves to null whatever it names")
        return

    if head == "state":
        report.bump("read-state")
        if len(segs) < 2:
            report.finding("state", ".".join(segs), site, keypath,
                           "the global state table",
                           "a bare `state` names the whole table; the "
                           "evaluator returns the dict, which no widget binds")
            return
        if segs[1] not in report.decls.global_:
            report.finding(
                "state", ".".join(segs), site, keypath,
                f"workspace/state.yaml `state:` "
                f"({len(report.decls.global_)} keys)",
                "no global declaration; the read is Value.null() at runtime "
                "(expr_eval.py:113-116), logged at DEBUG only")
        return

    if head == "tool":
        if len(segs) < 3:
            report.bump("ambient-tool")
            return
        report.bump("read-tool")
        tid = segs[1]
        if tid not in report.decls.tool:
            report.finding("tool", ".".join(segs), site, keypath,
                           "workspace/tools/*.yaml entity ids",
                           f"no tool is filed under {tid!r}, so ctx['tool']"
                           f"[{tid!r}] is absent and the read is null")
        elif segs[2] not in report.decls.tool[tid]:
            report.finding(
                "tool", ".".join(segs), site, keypath,
                f"{report.decls.sites.get(('tool', tid), tid)} `state:` "
                f"({len(report.decls.tool[tid])} keys)",
                "the tool exists but declares no such key; init_tool seeds "
                "only the `state:` block, so the read is null until some "
                "effect writes it")
        return

    if head == "panel":
        if owner is None or owner[0] != "panel":
            report.bump("ambient-panel")
            return
        report.bump("read-panel")
        pid = owner[1]
        _resolve_owned(report, segs, site, keypath, "panel", pid,
                       report.decls.panel.get(pid, set()),
                       report.decls.panel_init.get(pid, set()),
                       "init_panel seeds the panel's own `state:` block "
                       "(loader.panel_state_defaults)")
        return

    if head == "dialog":
        if owner is None or owner[0] != "dialog":
            report.bump("ambient-dialog")
            return
        report.bump("read-dialog")
        did = owner[1]
        _resolve_owned(report, segs, site, keypath, "dialog", did,
                       report.decls.dialog.get(did, set()),
                       report.decls.dialog_init.get(did, set()),
                       "open_dialog seeds the dialog's own `state:` block "
                       "(effects.py:982-1000)")
        return


def _resolve_owned(report, segs, site, keypath, kind, owner_id, tier1, tier2,
                   how):
    if len(segs) < 2:
        report.finding(kind, ".".join(segs), site, keypath,
                       f"the {kind} {owner_id!r} table",
                       f"a bare `{kind}` names the whole table, not a key")
        return
    key = segs[1]
    if key in tier1:
        return
    if key in tier2:
        report.bump("warn-init-tier")
        report.warn(kind + "-init-tier", ".".join(segs), site, keypath,
                    f"declared only in {owner_id!r}'s `init:`, not its "
                    f"`state:`. It exists once the init pass runs, but the "
                    f"Flask reference renderer's first paint builds the scope "
                    f"from `state:` alone (jas_flask/renderer.py:1493-1498), "
                    f"so the first render reads null")
        return
    site_of = report.decls.sites.get((kind, owner_id), owner_id)
    report.finding(kind, ".".join(segs), site, keypath,
                   f"{site_of} `state:` ({len(tier1)} keys)"
                   + (f" + `init:` ({len(tier2)} keys)" if tier2 else ""),
                   f"no declaration in {kind} {owner_id!r}; {how}, so the read "
                   f"is Value.null() at runtime")


# ── the walk ──────────────────────────────────────────────────────────────

def _walk(node, relpath, keypath, owner, report, in_prop=False):
    if _is_map(node):
        # A `foreach` item variable named after a namespace head shadows that
        # whole namespace inside the loop body -- the evaluator's context is a
        # single flat dict, so the binding replaces the table.
        fe = _get(node, "foreach")
        if fe is not None and _is_map(fe):
            as_node = _get(fe, "as")
            as_name = _scalar(as_node)
            if as_name in STATE_HEADS:
                report.bump("warn-shadow")
                report.warn("shadow-foreach", as_name,
                            _site(relpath, as_node), keypath + "/foreach/as",
                            f"a foreach item bound as {as_name!r} SHADOWS the "
                            f"{as_name} namespace for the whole loop body; the "
                            f"evaluator has one flat context dict and no "
                            f"runtime diagnostic for the collision")
        for key, _kn, value in _pairs(node):
            if key in PROSE_KEYS:
                continue
            child = f"{keypath}/{key}"
            prop = in_prop or (
                owner is not None and owner[0] == "dialog"
                and key in ("get", "set") and PROP_POS_RE.match(keypath)
                is not None)
            _walk(value, relpath, child, owner, report, prop)
    elif _is_seq(node):
        for i, item in enumerate(_items(node)):
            _walk(item, relpath, f"{keypath}[{i}]", owner, report, in_prop)
    elif isinstance(node, yaml.ScalarNode):
        report.bump("scalars")
        text = node.value
        if not isinstance(text, str) or not HEAD_RE.search(text):
            return
        report.bump("expr-strings")
        site = _site(relpath, node)
        reads, shadows, error = extract_reads(text)
        if error is not None:
            report.unreadable.append({"site": site, "keypath": keypath,
                                      "expr": text, "error": error})
            return
        for name in shadows:
            report.bump("warn-shadow")
            report.warn("shadow-binding", name, site, keypath,
                        f"a `fun`/`let` binding named {name!r} SHADOWS the "
                        f"{name} namespace inside this expression")
        for segs in reads:
            _resolve(report, segs, site, keypath, owner, in_prop)


def evaluate(docs):
    """The gate's whole judgement over ``{relpath: yaml text}``, as data, so the
    self-test drives the same code the live run does.

    Raises Refusal on a file that will not compose. Never touches the
    filesystem."""
    composed = {}
    for relpath in sorted(docs):
        try:
            node = yaml.compose(docs[relpath])
        except yaml.YAMLError as e:
            raise Refusal(
                f"{relpath} does not parse as YAML ({e.__class__.__name__}). "
                f"A workspace source this gate cannot read is a source it "
                f"cannot judge, and a skipped file would report as clean."
            ) from e
        if node is None:
            raise Refusal(
                f"{relpath} composed to nothing (empty document). The loader "
                f"merges it as a no-op; this gate refuses rather than counting "
                f"an unreadable file as scanned.")
        composed[relpath] = node

    report = Report()
    report.decls = collect_declarations(composed)
    for which in ("global", "panel", "tool", "dialog"):
        report.bump("decl-" + which, report.decls.count(which))

    for relpath, node in sorted(composed.items()):
        parts = relpath.split("/")
        subdir = parts[1] if len(parts) == 3 else None
        if subdir == "panels":
            _walk(node, relpath, "", ("panel", _entity_id(node, relpath)),
                  report)
        elif subdir == "dialogs":
            # Each top-level key is one dialog, and it owns its own subtree.
            for did, _kn, spec in _pairs(node):
                _walk(spec, relpath, f"/{did}", ("dialog", did), report)
        else:
            _walk(node, relpath, "", None, report)
    return report


def unreadable_refusal(report):
    """The refusal message for expressions the gate could not parse, or None.

    Kept OUT of ``evaluate`` so a run reports its findings AND its refusal
    rather than losing the findings to the first bad string."""
    if not report.unreadable:
        return None
    lines = [f"{len(report.unreadable)} expression string(s) mention a state "
             f"namespace but do NOT parse with the interpreter's own parser "
             f"(workspace_interpreter/expr_parser.parse). Every one of them is "
             f"Value.null() at runtime -- expr.evaluate catches the "
             f"ParseError, logs it at WARNING and returns null (expr.py:44-51) "
             f"-- and this gate cannot extract the reads inside them, so it "
             f"refuses rather than reporting the file as clean:"]
    for u in report.unreadable:
        lines.append(f"    {u['site']} ({u['keypath']})")
        lines.append(f"        {u['expr'].strip()[:140]!r}")
        lines.append(f"        {u['error']}")
    return "\n".join(lines)


# ── the live scan ─────────────────────────────────────────────────────────

def scan_paths(workspace=WORKSPACE):
    """The files ``loader.load_workspace`` would read: top-level YAML plus the
    five recognised subdirectories. ``tests/`` is not one of them."""
    found = []
    if workspace.is_dir():
        for entry in sorted(os.listdir(workspace)):
            if entry.endswith(YAML_SUFFIXES):
                found.append(workspace / entry)
        for sub in LOADED_SUBDIRS:
            subdir = workspace / sub
            if not subdir.is_dir():
                continue
            for entry in sorted(os.listdir(subdir)):
                if entry.endswith(YAML_SUFFIXES):
                    found.append(subdir / entry)
    return found


def read_docs(paths, root=ROOT):
    """{posix relpath: text}. Keyed on ``as_posix()`` -- a rendered path is
    platform-dependent and must never be an identity (check_path_keying.py)."""
    return {p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
            for p in paths}


def tracked_workspace_yaml(root=ROOT):
    """How many loadable workspace YAML files GIT knows about.

    DERIVED, and from a DIFFERENT ORACLE than the one it guards: the scan uses
    ``os.listdir``, so a floor computed from the same listing would agree with
    any breakage of it. ``git ls-files`` is an independent index and emits
    POSIX paths on every platform. It FAILS CLOSED -- a floor that returns 0
    when its oracle is unreachable passes every possible tree."""
    try:
        out = subprocess.run(["git", "ls-files", "--", "workspace"],
                             cwd=root, capture_output=True, text=True,
                             encoding="utf-8", check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise Refusal(
            f"cannot derive the file floor: `git ls-files` is unavailable "
            f"({e}). The floor is what stops a silently-empty scan from "
            f"reading as a clean tree, so this refuses rather than guessing."
        ) from e
    n = 0
    for line in out.splitlines():
        line = line.strip()
        if not line.endswith(YAML_SUFFIXES):
            continue
        parts = line.split("/")
        if len(parts) == 2 or (len(parts) == 3 and parts[1] in LOADED_SUBDIRS):
            n += 1
    if n == 0:
        raise Refusal(
            "cannot derive the file floor: `git ls-files -- workspace` matched "
            "no loadable YAML. Either the pathspec stopped matching or this is "
            "not the repository -- both make the floor vacuous.")
    return n


def _vacuous(report, n_docs, floor):
    """True when the scan cannot be trusted to have LOOKED. Extracted so the
    self-test drives the same predicate ``main`` uses."""
    if n_docs < floor:
        return True
    return any(not report.counts.get(c) for c in COLLECTORS)


def _report_findings(report, stream=sys.stderr):
    for f in sorted(report.findings,
                    key=lambda f: (f["kind"], f["read"], f["site"])):
        print(f"  {f['site']}  ({f['keypath']})", file=stream)
        print(f"      reads   : {f['read']}", file=stream)
        print(f"      searched: {f['searched']}", file=stream)
        print(f"      why     : {f['why']}", file=stream)


def _report_warnings(report, stream=sys.stdout):
    for w in sorted(report.warnings,
                    key=lambda w: (w["kind"], w["read"], w["site"])):
        print(f"  WARN {w['site']}  ({w['keypath']})", file=stream)
        print(f"       {w['read']}: {w['why']}", file=stream)


# ── the fixture ───────────────────────────────────────────────────────────

def _fixture():
    """A miniature workspace exercising every collector exactly once, so a
    planted read has one possible cause."""
    return {
        "workspace/app.yaml": "version: 1\napp:\n  name: fixture\n",
        "workspace/state.yaml": (
            "state:\n"
            "  g_flag:\n"
            "    type: bool\n"
            "    default: false\n"
            "    description: >\n"
            "      Prose is excluded from the scan. It may name state.g_ghost\n"
            "      and dialog.d_ghost freely; neither is ever evaluated.\n"
            "  g_count:\n"
            "    type: number\n"
            "    default: 0\n"
        ),
        "workspace/layout.yaml": (
            "layout:\n"
            "  id: root\n"
            "  type: pane_system\n"
            "  children:\n"
            "    - id: pane_a\n"
            "      type: pane\n"
            "      bind:\n"
            "        visible: \"state.g_flag\"\n"
        ),
        "workspace/menubar.yaml": (
            "menubar:\n"
            "  - id: file_menu\n"
            "    items:\n"
            "      - id: menu_new\n"
            "        action: new_document\n"
            "        enabled_when: \"state.g_count > 0\"\n"
        ),
        "workspace/actions.yaml": (
            "actions:\n"
            "  new_document:\n"
            "    effects:\n"
            "      - set: { g_count: \"state.g_count + 1\" }\n"
            "  poke_tool:\n"
            "    effects:\n"
            "      - set: { tool.pen.mode: \"'idle'\" }\n"
            "      - if: \"tool.pen.mode == 'drawing'\"\n"
            "        then:\n"
            "          - set: { g_flag: \"true\" }\n"
        ),
        "workspace/panels/alpha.yaml": (
            "id: alpha_panel\n"
            "type: panel\n"
            "state:\n"
            "  a_key:\n"
            "    type: string\n"
            "    default: \"\"\n"
            "init:\n"
            "  a_late: \"state.g_count\"\n"
            "content:\n"
            "  type: container\n"
            "  children:\n"
            "    - id: alpha_row\n"
            "      type: row\n"
            "      bind:\n"
            "        value: \"panel.a_key\"\n"
            "        disabled: \"state.g_flag\"\n"
            "      content: \"now {{ panel.a_key }} of {{ state.g_count }}\"\n"
        ),
        "workspace/tools/pen.yaml": (
            "id: pen\n"
            "cursor: crosshair\n"
            "state:\n"
            "  mode: { default: \"idle\" }\n"
            "handlers:\n"
            "  on_mousedown:\n"
            "    - set: { tool.pen.mode: \"'drawing'\" }\n"
            "  on_mouseup:\n"
            "    - if: \"tool.pen.mode == 'drawing'\"\n"
            "      then:\n"
            "        - set: { tool.pen.mode: \"'idle'\" }\n"
        ),
        "workspace/dialogs/first.yaml": (
            "first_dialog:\n"
            "  modal: true\n"
            "  state:\n"
            "    d_key:\n"
            "      type: number\n"
            "      default: 0\n"
            "    d_derived:\n"
            "      get: \"d_key + state.g_count\"\n"
            "  init:\n"
            "    d_late: \"state.g_count\"\n"
            "  content:\n"
            "    type: container\n"
            "    children:\n"
            "      - id: first_row\n"
            "        type: row\n"
            "        bind:\n"
            "          value: \"dialog.d_key\"\n"
            "          visible: \"dialog.d_derived > 0\"\n"
        ),
        "workspace/templates/slider.yaml": (
            "slider_row:\n"
            "  content:\n"
            "    type: row\n"
            "    children:\n"
            "      - id: slider_label\n"
            "        type: text\n"
            "        content: \"{{ state.g_count }}\"\n"
        ),
    }


def _planted_cases(clean):
    """[(label, docs, kind that must red)] -- one plant per read spelling, plus
    the wrong-scope and dialog-property arms."""
    cases = []

    def variant(label, path, old, new, kind):
        docs = dict(clean)
        assert old in docs[path], f"fixture drift: {old!r} not in {path}"
        docs[path] = docs[path].replace(old, new, 1)
        cases.append((label, docs, kind))

    # THE FOUR READ SPELLINGS, one undeclared plant each.
    variant("an undeclared global read", "workspace/layout.yaml",
            'visible: "state.g_flag"', 'visible: "state.g_ghost"', "state")
    variant("an undeclared panel read", "workspace/panels/alpha.yaml",
            'value: "panel.a_key"', 'value: "panel.p_ghost"', "panel")
    variant("an undeclared tool read", "workspace/tools/pen.yaml",
            'if: "tool.pen.mode == \'drawing\'"',
            'if: "tool.pen.ghost == \'drawing\'"', "tool")
    variant("an undeclared dialog read", "workspace/dialogs/first.yaml",
            'value: "dialog.d_key"', 'value: "dialog.d_ghost"', "dialog")
    # A tool id nothing is filed under -- ctx["tool"] has no such entry.
    variant("a read of an unknown tool", "workspace/actions.yaml",
            'if: "tool.pen.mode == \'drawing\'"',
            'if: "tool.nosuch.mode == \'drawing\'"', "tool")
    # RIGHT NAME, WRONG SCOPE. `a_key` IS declared -- in the panel -- and the
    # global table has no such key. There is no fallback search
    # (expr_eval.py:106-110), so this is null and must red.
    variant("a key declared only in another scope", "workspace/menubar.yaml",
            'enabled_when: "state.g_count > 0"',
            'enabled_when: "state.a_key > 0"', "state")
    # A dialog property getter has NO `dialog` binding of its own.
    variant("a dialog.* read inside a dialog property getter",
            "workspace/dialogs/first.yaml",
            'get: "d_key + state.g_count"',
            'get: "dialog.d_key + state.g_count"', "prop-scope")
    return cases


def _green_cases(clean):
    """[(label, docs)] -- mutations that must NOT red. Each closes an
    over-reach: a gate that pooled every scope into one table, or that read
    prose, would fail exactly here."""
    cases = []

    def variant(label, path, old, new):
        docs = dict(clean)
        assert old in docs[path], f"fixture drift: {old!r} not in {path}"
        docs[path] = docs[path].replace(old, new, 1)
        cases.append((label, docs))

    # AMBIENT: `panel.*` outside a panel file names whatever panel is active.
    variant("an ambient panel read in actions.yaml", "workspace/actions.yaml",
            'set: { g_flag: "true" }', 'set: { g_flag: "panel.whatever" }')
    # AMBIENT: `dialog.*` outside a dialog file names whatever dialog is open.
    variant("an ambient dialog read in menubar.yaml", "workspace/menubar.yaml",
            'enabled_when: "state.g_count > 0"',
            'enabled_when: "dialog.whatever > 0"')
    # PROSE: a description naming a key that does not exist stays green.
    variant("a bogus read inside prose", "workspace/state.yaml",
            "and dialog.d_ghost freely; neither is ever evaluated.",
            "and dialog.d_ghost and panel.p_ghost and tool.pen.ghost freely.")
    return cases


def _self_test():
    """Prove the gate can still REFUSE and still REJECT. Touches no file."""
    failures = []
    clean = _fixture()

    # 1. AN EMPTY SCAN MUST REFUSE, AND IT IS ASSERTED FIRST. Every assertion
    #    below is vacuously true over an empty document set, so if this one is
    #    wrong the rest of this self-test is theatre.
    empty = evaluate({})
    if empty.findings or empty.counts.get("expr-strings"):
        failures.append("an empty scan produced findings or expression strings")
    if not _vacuous(empty, n_docs=0, floor=1):
        failures.append("an empty scan was not judged vacuous -- a scan that "
                        "read nothing must never report a clean tree")

    # 2. THE FLOOR REDS ON A SHORT SCAN. Stubbed BOTH WAYS: the same documents
    #    pass under a floor they meet and refuse under a floor they miss.
    reg = evaluate(clean)
    if _vacuous(reg, n_docs=len(clean), floor=len(clean)):
        failures.append(f"a full scan was judged vacuous against its own "
                        f"floor (counts: {reg.counts})")
    if not _vacuous(reg, n_docs=len(clean), floor=len(clean) + 1):
        failures.append("a scan of fewer files than the floor was not refused")

    # 3. AN UNPARSEABLE FILE IS A REFUSAL, not a finding and not a skip.
    broken = dict(clean)
    broken["workspace/broken.yaml"] = "a:\n  - b\n c: [\n"
    try:
        evaluate(broken)
        failures.append("an unparseable YAML file did not raise Refusal")
    except Refusal as r:
        if "broken.yaml" not in str(r):
            failures.append("the refusal did not name the unparseable file")

    # 4. AN UNPARSEABLE EXPRESSION IS A REFUSAL THAT NAMES IT. The gate cannot
    #    extract reads from a string the interpreter's parser rejects, and the
    #    runtime cannot evaluate it either -- expr.evaluate returns null. A
    #    skipped string would report as clean.
    bad_expr = dict(clean)
    bad_expr["workspace/layout.yaml"] = bad_expr["workspace/layout.yaml"].replace(
        'visible: "state.g_flag"', 'visible: "state.g_flag contains 3"')
    got = evaluate(bad_expr)
    msg = unreadable_refusal(got)
    if msg is None:
        failures.append("an unparseable expression was not refused")
    elif "workspace/layout.yaml" not in msg or "contains" not in msg:
        failures.append("the unparseable-expression refusal did not name the "
                        "site and the string")
    if unreadable_refusal(reg) is not None:
        failures.append("the clean fixture reported an unparseable expression")

    # 5. THE CLEAN FIXTURE IS GREEN, and EVERY collector found something.
    if reg.findings:
        failures.append(f"the clean fixture reported findings: {reg.findings}")
    for collector in COLLECTORS:
        if not reg.counts.get(collector):
            failures.append(f"collector {collector!r} found nothing in the "
                            f"clean fixture")

    # 6. ONE PLANTED UNDECLARED READ PER SPELLING. Each mutates a copy of the
    #    fixture case 5 has just proven green, so the RED is attributable to
    #    the plant and to nothing else. The finding must NAME the site and the
    #    scope that was searched -- a bare count would not tell an author where
    #    to look.
    for label, docs, kind in _planted_cases(clean):
        got = evaluate(docs)
        hit = [f for f in got.findings if f["kind"] == kind]
        if not hit:
            failures.append(f"planting {label} did not red kind {kind!r} "
                            f"(findings: {[f['kind'] for f in got.findings]})")
            continue
        f = hit[0]
        if ":" not in f["site"] or not f["searched"] or not f["why"]:
            failures.append(f"{label}: the finding did not name a site, the "
                            f"scope searched, and the runtime behaviour")

    # 7. THE GREEN ARMS. A gate that pooled all four namespaces into one table,
    #    or that read prose, passes every arm above and fails here.
    for label, docs in _green_cases(clean):
        got = evaluate(docs)
        if got.findings:
            failures.append(f"{label} must stay GREEN, got {got.findings}")
        if unreadable_refusal(got) is not None:
            failures.append(f"{label} must stay GREEN, but was refused as "
                            f"unreadable")
    ambient = evaluate(_green_cases(clean)[0][1])
    if not ambient.counts.get("ambient-panel"):
        failures.append("an ambient panel read was not COUNTED -- an uncovered "
                        "read must be visible in the census, not merely "
                        "skipped")

    # 8. THE TWO WARNING TIERS WARN AND DO NOT RED. Both are ZERO on the live
    #    tree, so if they are not driven here they are driven nowhere.
    init_tier = dict(clean)
    init_tier["workspace/panels/alpha.yaml"] = init_tier[
        "workspace/panels/alpha.yaml"].replace(
            'value: "panel.a_key"', 'value: "panel.a_late"')
    got = evaluate(init_tier)
    if got.findings:
        failures.append(f"an init-tier read must WARN, not red: {got.findings}")
    if not [w for w in got.warnings if w["kind"] == "panel-init-tier"]:
        failures.append("an init-only declaration produced no warning")

    shadow = dict(clean)
    shadow["workspace/panels/alpha.yaml"] = shadow[
        "workspace/panels/alpha.yaml"].replace(
            "    - id: alpha_row\n",
            "    - foreach: { source: \"state.g_count\", as: state }\n"
            "      do: { type: row }\n"
            "    - id: alpha_row\n")
    got = evaluate(shadow)
    if got.findings:
        failures.append(f"a shadowing foreach must WARN, not red: "
                        f"{got.findings}")
    if not [w for w in got.warnings if w["kind"] == "shadow-foreach"]:
        failures.append("a foreach bound as a namespace head produced no "
                        "warning")

    for label, expr in (("a lambda parameter",
                         "map(d_key, fun state -> state.g_count)"),
                        ("a let binding",
                         "let state = 1 in state.g_count")):
        lam = dict(clean)
        lam["workspace/dialogs/first.yaml"] = lam[
            "workspace/dialogs/first.yaml"].replace(
                'get: "d_key + state.g_count"', f'get: "{expr}"')
        got = evaluate(lam)
        if unreadable_refusal(got) is not None:
            failures.append(f"{label}: the shadowing fixture did not parse")
        if got.findings:
            failures.append(f"{label} named after a namespace head must WARN, "
                            f"not red: {got.findings}")
        if not [w for w in got.warnings if w["kind"] == "shadow-binding"]:
            failures.append(f"{label} named after a namespace head produced "
                            f"no warning")

    # 9. THE MUTANTS. Each disables one load-bearing part and asserts the gate
    #    NOTICES. Without these the parts are present but unproven.
    g = globals()

    #    MUTANT A -- an extractor that finds nothing. This is the failure the
    #    whole anti-vacuity floor exists for: no reads found reads exactly like
    #    no reads broken.
    real_extract = g["extract_reads"]
    g["extract_reads"] = lambda text: ([], [], None)
    try:
        blind = evaluate(clean)
        if blind.findings:
            failures.append("MUTANT A: a blind extractor still found findings")
        if not _vacuous(blind, n_docs=len(clean), floor=len(clean)):
            failures.append("MUTANT A: an extractor that finds NOTHING was not "
                            "judged vacuous -- the floor does not bind")
    finally:
        g["extract_reads"] = real_extract

    #    MUTANT B -- a resolver that accepts everything, while still bumping
    #    the read collectors so the floor above cannot catch it. Every planted
    #    case must go green, which is what proves the plants are redding
    #    because of the RESOLVER and not because of some incidental parse.
    real_resolve = g["_resolve"]

    def _accept_all(report, segs, site, keypath, owner, in_prop):
        report.bump("read-" + segs[0] if segs[0] != "tool" else "read-tool")

    g["_resolve"] = _accept_all
    try:
        survived = []
        for label, docs, _kind in _planted_cases(clean):
            if evaluate(docs).findings:
                survived.append(label)
        if survived:
            failures.append(f"MUTANT B: a resolver that accepts everything "
                            f"still redded: {survived}")
    finally:
        g["_resolve"] = real_resolve

    #    MUTANT C -- delete the prose exclusion. Prose must then RED, which is
    #    what makes the exclusion load-bearing rather than decorative. (Case 7
    #    proved the other direction: with it, prose is green.)
    real_prose = g["PROSE_KEYS"]
    g["PROSE_KEYS"] = ()
    try:
        prose_docs = _green_cases(clean)[2][1]
        got = evaluate(prose_docs)
        # Prose is not an expression: with the exclusion gone the description
        # reaches the parser, fails it, and lands in `unreadable` -- a REFUSAL,
        # which is the loud direction. Either outcome proves the exclusion is
        # what keeps case 7 green; a still-clean run would prove it is not.
        if not got.findings and unreadable_refusal(got) is None:
            failures.append("MUTANT C: with the prose exclusion deleted, a "
                            "bogus read inside a description STILL did not "
                            "red -- the exclusion is not what keeps it green")
    finally:
        g["PROSE_KEYS"] = real_prose

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_state_reads SELF-TEST: OK (empty scan refuses, proven FIRST; "
          f"the derived floor refuses a short scan and passes a full one; an "
          f"unparseable FILE refuses; an unparseable EXPRESSION refuses naming "
          f"it; all {len(COLLECTORS)} collectors find something in a clean "
          f"fixture; a planted undeclared read reds each of "
          f"{len(_planted_cases(_fixture()))} arms naming site, scope searched "
          f"and runtime behaviour; {len(_green_cases(_fixture()))} ambient/"
          f"prose arms stay green and the ambient one is still COUNTED; the "
          f"init-tier and two shadowing arms warn without redding; 3 mutants "
          f"-- blind extractor, accept-everything resolver, deleted prose "
          f"exclusion -- are each caught).")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="State-read declaration gate (VISION.md §11).")
    ap.add_argument("--self-test", action="store_true",
                    help="prove the gate can still refuse and still reject; "
                         "touches no workspace file")
    args = ap.parse_args()
    if args.self_test:
        return _self_test()

    try:
        floor = tracked_workspace_yaml()
        paths = scan_paths()
        docs = read_docs(paths)
        report = evaluate(docs)
        if _vacuous(report, n_docs=len(docs), floor=floor):
            dead = [c for c in COLLECTORS if not report.counts.get(c)]
            raise Refusal(
                f"the scan read {len(docs)} workspace YAML files (git's index "
                f"holds {floor}) and these collectors found NOTHING: "
                f"{', '.join(dead) or '(none)'}. A scan that reads less than "
                f"the tree, or collects nothing from what it read, reports "
                f"fewer unresolved reads than the tree has -- and reads "
                f"exactly like a clean tree.")
    except Refusal as r:
        print(f"REFUSED: {r}", file=sys.stderr)
        return 1

    rc = 0
    if report.findings:
        print(f"FAIL: {len(report.findings)} state read(s) with no "
              f"declaration in the scope the resolver searches:",
              file=sys.stderr)
        _report_findings(report)
        print("\nThere is no scope SEARCH: expr_eval._eval_path takes "
              "ctx.get(segments[0])\nand never falls back, so a read with no "
              "declaration is Value.null() and\nnothing says so at runtime. "
              "Declare the key, or fix the read.", file=sys.stderr)
        rc = 1

    msg = unreadable_refusal(report)
    if msg is not None:
        print(f"REFUSED: {msg}", file=sys.stderr)
        rc = 1

    if report.warnings:
        print(f"{len(report.warnings)} warning(s):")
        _report_warnings(report)

    if rc == 0:
        print(f"OK: {report.counts.get('read-state', 0)} state / "
              f"{report.counts.get('read-panel', 0)} panel / "
              f"{report.counts.get('read-tool', 0)} tool / "
              f"{report.counts.get('read-dialog', 0)} dialog reads all "
              f"resolve ({len(docs)} workspace YAML files scanned, floor "
              f"{floor} from git's index).")
    # The census, printed on EVERY run. A collector going quiet is refused
    # above; this is so a HUMAN can see one going THIN, which no threshold
    # catches -- and so the uncovered surface is a number rather than a
    # sentence in a docstring.
    print("  " + " | ".join(f"{c} {report.counts.get(c, 0)}"
                            for c in COLLECTORS))
    print("  uncovered/warned: "
          + " | ".join(f"{c} {report.counts.get(c, 0)}" for c in CENSUS))
    return rc


if __name__ == "__main__":
    sys.exit(main())
