#!/usr/bin/env python3
"""Workspace id-uniqueness gate (VISION.md §11, the validator cross-reference
layer's *no duplicate ids* sub-check).

WHY THIS EXISTS
---------------
VISION.md §11 names four sub-checks of the validator cross-reference layer.
Three of them have an instrument; this was the missing one:

    *no duplicate ids* -- ABSENT for workspace ids (the only id check is
    per-tool filename-stem matching, which is one tool at a time, not
    uniqueness).

The stem check in ``workspace_interpreter/validator.py`` compares each tool's
declared ``id`` against the key it is FILED UNDER -- and the key it is filed
under is the survivor of the merge. Two tool files claiming the same id cannot
fail it: the loader's ``merged[entity_id] = part`` has already dropped one of
them, and the validator then finds the survivor's id matching its own key.

That is the shape of the whole class. Every duplicate in this repository's
workspace is resolved SILENTLY, by a first-wins or last-wins rule nobody wrote
down:

  * ``yaml.safe_load`` on a mapping with a repeated key keeps the LAST and
    raises nothing. The compiled ``workspace.json`` then carries one entry, so
    every gate that reads the COMPILED BUNDLE -- ``check_action_refs.py`` among
    them -- is structurally unable to see the duplicate. That is why this gate
    reads the YAML SOURCES and composes them into nodes rather than loading
    them into dicts.
  * ``loader.load_workspace`` merges top-level YAML files with ``data.update``
    (LAST file in sorted order wins), files under ``panels/``, ``tools/`` and
    ``concepts/`` with ``merged[entity_id] = part`` (LAST wins), and files
    under ``dialogs/`` and ``templates/`` with ``merged.update(part)`` (LAST
    wins).
  * ``loader.find_element_by_id`` is a depth-first walk that returns on the
    FIRST match, and both live renderers emit element ids as DOM/view ids.
  * ``resolve_key_in`` (jas_dioxus ``workspace/resolve_key.rs``, and the same
    linear scan in JasSwift and the Flask JS) returns the FIRST shortcut entry
    whose chord matches. Its own module docstring asserts the table is
    "already disambiguated (no duplicate chords)" and that "the list order is a
    deterministic tie-break that the present table never exercises" -- an
    invariant stated in prose with nothing enforcing it. This gate enforces it.

WHAT IT ASSERTS
---------------
Uniqueness PER NAMESPACE over the workspace YAML sources the loader actually
loads. A namespace is one resolution table; two namespaces that never share a
lookup may reuse a name freely (a dialog and a panel may both own a widget
called ``preview``), and the self-test pins that a cross-namespace reuse stays
GREEN.

The one CROSS-namespace clause is derived from code, not assumed: an action
verb resolves through the UNION of ``actions:`` and ``native_intercepts:``
(``check_action_refs._resolvable``: ``set(ws["actions"]) | set(ws[
"native_intercepts"])``), while ``effects.run_effects`` dispatches on
``actions`` alone. A verb in both tables therefore means the declarative
runtime and a native port disagree about who handles it, silently. So the two
tables are ONE namespace here.

WHAT IT DOES NOT COVER, and why
-------------------------------
* ``workspace/tests/**`` -- corpus fixtures. ``load_workspace`` never reads
  them; they are input to the corpus compilers, which key on the case ``name``
  and are gated by their own freshness checks.
* ``workspace/appearances/*.json``, ``swatches/*.json``, ``gradients/*.json``,
  ``brushes/*/library.json`` -- keyed by FILENAME STEM (or directory name), so
  the filesystem already makes the key unique; the ids inside them are content
  rows, not lookup keys. Also outside this gate's file population, which is
  YAML.
* ``workspace/workspace.json`` -- GENERATED from the sources scanned here. It
  is post-merge, so it cannot carry a duplicate its sources do not; it is
  pinned fresh by ``scripts/check_workspace_json.sh``.
* ``id:`` appearing inside ``behavior:``/``handlers:``/``effects:`` --
  ``open_dialog: {id: color_picker}``, ``start_timer: {id: ...}``, and the
  ``alternates.items[*].id`` tool references. Those are REFERENCES to other
  namespaces; repeating one is normal and correct. The element walk therefore
  follows only element edges (see ELEMENT_EDGES), never effect bodies.
* Reuse of a widget id across two DIFFERENT owners (a panel and a dialog).
  The reference interpreter holds no global element table -- it resolves
  ``panels[pid]`` (or ``dialogs[did]``) first and walks that subtree -- so
  per-owner is the namespace the code actually keys on. Two such reuses exist
  today (``cp_hex`` in the color panel and the color-picker dialog,
  ``so_preview`` in two dialogs); the Flask reference renderer's
  ``getElementById`` would take the first of them if both were in one DOM.
  Gating that would be a stricter rule than any interpreter enforces, so it is
  reported here as a known observation rather than silently included.

Run ``python scripts/check_workspace_ids.py`` to verify, ``--self-test`` to
prove the gate can still go RED.

WHY --self-test EXISTS
----------------------
This gate is a pile of collectors and a duplicate count, and a count has no
failure mode: a collector that silently returns nothing reports zero
duplicates, which is byte-identical to a clean tree. So the self-test asserts,
BEFORE anything else, that an empty scan REFUSES rather than passing; then that
a scan of fewer files than git's index knows about REFUSES; then that an
unparseable file REFUSES; then that a clean fixture is GREEN with every
collector non-empty; and only then that each namespace's planted duplicate
turns it RED. The live run repeats the per-collector non-emptiness assertion
against the real tree, because a fixture proves the collector works on the
fixture.
"""

import argparse
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKSPACE = ROOT / "workspace"

# The loader's own directory vocabulary (workspace_interpreter/loader.py).
KEYED_SUBDIRS = ("panels", "tools", "concepts")     # merged[entity_id] = part
MERGED_SUBDIRS = ("dialogs", "templates")           # merged.update(part)
LOADED_SUBDIRS = KEYED_SUBDIRS + MERGED_SUBDIRS

# Edges along which an ELEMENT tree continues. Anything not listed here is data
# (a behavior body, a state block, an effect payload), and ids inside it are
# references rather than definitions -- see WHAT IT DOES NOT COVER.
ELEMENT_EDGES = ("children", "content", "title_bar", "buttons", "tabs")
# The menubar is its own tree shape: a list of menus, each with `items`.
MENU_EDGES = ("items",)

YAML_SUFFIXES = (".yaml", ".yml")


class Refusal(Exception):
    """The gate cannot make a judgement. Distinct from a FINDING on purpose: a
    refusal means the instrument is not measuring, and it must never be
    reported as a clean tree."""


# ── node helpers ───────────────────────────────────────────────────────────
# Everything below walks composed YAML NODES, not loaded dicts. A dict has
# already lost every duplicate mapping key (PyYAML keeps the last, silently),
# which is the single most important defect this gate exists to catch.

def _is_map(node):
    return isinstance(node, yaml.MappingNode)


def _is_seq(node):
    return isinstance(node, yaml.SequenceNode)


def _pairs(node):
    """[(key_str, key_node, value_node)] for a mapping node, IN FILE ORDER and
    with duplicates preserved."""
    if not _is_map(node):
        return []
    out = []
    for k, v in node.value:
        if isinstance(k, yaml.ScalarNode):
            out.append((k.value, k, v))
    return out


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


# ── the registry ───────────────────────────────────────────────────────────

class Registry:
    """Every (namespace, id) seen, with the site that claimed it first. A
    second claim on the same pair is a finding."""

    def __init__(self):
        self.first = {}
        self.findings = []
        self.counts = {}

    def add(self, namespace, ident, site, collector):
        self.counts[collector] = self.counts.get(collector, 0) + 1
        key = (namespace, ident)
        if key in self.first:
            self.findings.append({
                "namespace": namespace,
                "id": ident,
                "first": self.first[key],
                "second": site,
                "collector": collector,
            })
        else:
            self.first[key] = site

    @property
    def namespaces(self):
        return {ns for (ns, _i) in self.first}

    @property
    def ids(self):
        return len(self.first)


# ── collectors ─────────────────────────────────────────────────────────────

def _collect_mapping_keys(node, where, path, reg):
    """LAYER A, universal: a repeated key in ANY mapping. PyYAML keeps the last
    and raises nothing, so this is invisible to every reader downstream of the
    load -- including the compiled bundle.

    The namespace is the KEY PATH, not the node's identity, so two mappings at
    the same path share one namespace. That is deliberate and it is also what
    the load does -- if `icons/selection_arrow` appears twice, the surviving
    dict is the LAST one whole -- but it means a duplicate key CASCADES: the
    repeated parent is reported, and so is every key inside it. Measured on the
    red-first plant: one duplicated icon entry produced three findings, the
    parent and its two fields. That is noise attached to a real finding and
    never a standalone one, because two mappings can only share a key path if
    an ancestor key is itself duplicated -- which is already reported above
    them. A sequence gives its items distinct paths (`foo[0]`, `foo[1]`), so
    siblings in a list cannot collide this way."""
    if _is_map(node):
        for key, key_node, value_node in _pairs(node):
            reg.add(f"mapping-key {where}{path}", key, _site(where, key_node),
                    "mapping-keys")
            _collect_mapping_keys(value_node, where, f"{path}/{key}", reg)
    elif _is_seq(node):
        for i, child in enumerate(_items(node)):
            _collect_mapping_keys(child, where, f"{path}[{i}]", reg)


def _collect_element_ids(node, where, namespace, reg, collector, edges=ELEMENT_EDGES,
                         at_root=True):
    """Element ids along element edges only. ``find_element_by_id`` returns the
    FIRST match of a depth-first walk, and both live renderers emit these as
    view/DOM ids."""
    if _is_map(node):
        if not at_root:
            ident = _scalar(_get(node, "id"))
            if isinstance(ident, str):
                reg.add(namespace, ident, _site(where, _get(node, "id")), collector)
        for edge in edges:
            child = _get(node, edge)
            if child is None:
                continue
            if _is_seq(child):
                for item in _items(child):
                    _collect_element_ids(item, where, namespace, reg, collector,
                                         edges, at_root=False)
            else:
                _collect_element_ids(child, where, namespace, reg, collector,
                                     edges, at_root=False)


def _normalize_chord(text):
    """Mirror ``resolve_key.parse_shortcut``/``canon_key``: split on '+', all
    but the last token are modifiers matched case-insensitively, and a single
    ASCII letter key is uppercased. Comparing raw strings would miss
    ``Ctrl+N`` shadowing ``ctrl+n``, which resolves to the identical chord."""
    if not isinstance(text, str) or not text:
        return None
    tokens = text.split("+")
    key_tok, mod_toks = tokens[-1], tokens[:-1]
    mods = set()
    for m in mod_toks:
        low = m.lower()
        if low in ("ctrl", "control"):
            mods.add("ctrl")
        elif low == "shift":
            mods.add("shift")
        elif low in ("alt", "option"):
            mods.add("alt")
        elif low in ("meta", "cmd", "command", "super"):
            mods.add("meta")
        # An unknown modifier token is ignored, exactly as parse_shortcut does.
    if len(key_tok) == 1 and key_tok.isascii() and key_tok.isalpha():
        key_tok = key_tok.upper()
    return "+".join(sorted(mods) + [key_tok])


def _entity_id(root, relpath):
    """The key a keyed-subdir file is filed under: its declared ``id``, else
    its filename stem (loader.py: ``part.get("id", splitext(fname)[0])``)."""
    declared = _scalar(_get(root, "id")) if _is_map(root) else None
    if isinstance(declared, str):
        return declared, _get(root, "id")
    return pathlib.PurePosixPath(relpath).stem, root


def evaluate(docs):
    """The gate's whole judgement over ``{relpath: yaml text}``, as data, so
    the self-test drives the same code the live run does.

    Raises Refusal on an unparseable file. Never touches the filesystem."""
    reg = Registry()
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

    for relpath, node in composed.items():
        # LAYER A -- every mapping in every file.
        _collect_mapping_keys(node, relpath, "", reg)

        parts = relpath.split("/")
        top = len(parts) == 2                       # workspace/<file>.yaml
        subdir = parts[1] if len(parts) == 3 else None

        if top:
            # loader: `data.update(part)` across sorted top-level files.
            for key, key_node, _v in _pairs(node):
                reg.add("workspace top-level key", key, _site(relpath, key_node),
                        "top-level")

            if parts[1].startswith("layout."):
                layout = _get(node, "layout")
                if layout is not None:
                    ident = _scalar(_get(layout, "id"))
                    if isinstance(ident, str):
                        reg.add("layout element id", ident,
                                _site(relpath, _get(layout, "id")), "layout")
                    _collect_element_ids(layout, relpath, "layout element id", reg,
                                         "layout")
            if parts[1].startswith("menubar."):
                menubar = _get(node, "menubar")
                for menu in _items(menubar) if menubar is not None else []:
                    ident = _scalar(_get(menu, "id"))
                    if isinstance(ident, str):
                        reg.add("menubar id", ident, _site(relpath, _get(menu, "id")),
                                "menubar")
                    _collect_element_ids(menu, relpath, "menubar id", reg, "menubar",
                                         edges=MENU_EDGES)
            if parts[1].startswith("shortcuts."):
                shortcuts = _get(node, "shortcuts")
                for entry in _items(shortcuts) if shortcuts is not None else []:
                    chord = _normalize_chord(_scalar(_get(entry, "key")))
                    if chord:
                        reg.add("shortcut chord", chord,
                                _site(relpath, _get(entry, "key")), "shortcuts")
            if parts[1].startswith("actions."):
                # THE CROSS-NAMESPACE CLAUSE, read out of the code: an action
                # verb resolves through `actions` UNION `native_intercepts`
                # (check_action_refs._resolvable) while effects.run_effects
                # dispatches on `actions` alone. A verb in both means the
                # declarative runtime and the native port disagree in silence.
                acts = _get(node, "actions")
                for key, key_node, _v in _pairs(acts) if acts is not None else []:
                    reg.add("action verb", key, _site(relpath, key_node), "action-verb")
                ni = _get(node, "native_intercepts")
                for entry in _items(ni) if ni is not None else []:
                    name = _scalar(entry)
                    if isinstance(name, str):
                        reg.add("action verb", name, _site(relpath, entry),
                                "action-verb")

        elif subdir in KEYED_SUBDIRS:
            ident, id_node = _entity_id(node, relpath)
            reg.add(f"{subdir} entity id", ident, _site(relpath, id_node), subdir)
            if subdir == "panels":
                _collect_element_ids(node, relpath, f"panel:{ident} element id", reg,
                                     "panel-widgets")
            elif subdir == "concepts":
                for section, collector in (("operations", "concept-operations"),
                                           ("constraints", "concept-constraints")):
                    block = _get(node, section)
                    for entry in _items(block) if block is not None else []:
                        sub = _scalar(_get(entry, "id"))
                        if isinstance(sub, str):
                            reg.add(f"concept:{ident} {section} id", sub,
                                    _site(relpath, _get(entry, "id")), collector)

        elif subdir in MERGED_SUBDIRS:
            # loader: `merged.update(part)` -- each file's TOP-LEVEL keys are
            # the entities, so two files may collide.
            for key, key_node, value_node in _pairs(node):
                reg.add(f"{subdir} key", key, _site(relpath, key_node), subdir)
                owner = "dialog" if subdir == "dialogs" else "template"
                collector = "dialog-widgets" if subdir == "dialogs" else "template-widgets"
                _collect_element_ids(value_node, relpath, f"{owner}:{key} element id",
                                     reg, collector)

    return reg


# ── the live scan ──────────────────────────────────────────────────────────

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
    POSIX paths on every platform.

    It FAILS CLOSED. A floor that returns 0 when its oracle is unreachable
    passes every possible tree including an empty one, which is worse than no
    floor because it still reads as one (check_lane_coverage.py learned this
    by mutation)."""
    try:
        out = subprocess.run(["git", "ls-files", "--", "workspace"],
                             cwd=root, capture_output=True, text=True,
                             encoding="utf-8", check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        raise Refusal(
            f"cannot derive the file floor: `git ls-files` is unavailable "
            f"({e}). The floor is what stops a silently-empty scan from "
            f"reading as a clean tree, so this refuses rather than guessing.") from e
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


# Every collector must find something. A dead collector reports no duplicates
# in its namespace, which is indistinguishable from a namespace with none.
COLLECTORS = ("mapping-keys", "top-level", "layout", "menubar", "shortcuts",
              "action-verb", "panels", "tools", "concepts", "dialogs",
              "templates", "panel-widgets", "dialog-widgets", "template-widgets",
              "concept-operations", "concept-constraints")


def _report(reg, stream=sys.stdout):
    for f in sorted(reg.findings, key=lambda f: (f["namespace"], f["id"])):
        print(f"  {f['namespace']}: {f['id']!r} defined twice", file=stream)
        print(f"      first : {f['first']}", file=stream)
        print(f"      again : {f['second']}", file=stream)


def _self_test():
    """Prove the gate can still REFUSE and still REJECT. Touches no file."""
    failures = []

    # 1. AN EMPTY SCAN MUST REFUSE, AND IT IS ASSERTED FIRST. Every assertion
    #    below is vacuously true over an empty document set, so if this one is
    #    wrong the rest of this self-test is theatre.
    empty = evaluate({})
    if empty.ids or empty.findings:
        failures.append("an empty scan produced ids or findings")
    if not _vacuous(empty, n_docs=0, floor=1):
        failures.append("an empty scan was not judged vacuous -- a scan that "
                        "read nothing must never report a clean tree")

    # 2. THE FLOOR REDS ON A SHORT SCAN. Stubbed BOTH WAYS: the same documents
    #    pass under a floor they meet and refuse under a floor they miss, so
    #    the floor is shown to be load-bearing rather than merely present.
    clean = _fixture()
    reg = evaluate(clean)
    if _vacuous(reg, n_docs=len(clean), floor=len(clean)):
        failures.append("a full scan was judged vacuous against its own floor")
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

    # 4. THE CLEAN FIXTURE IS GREEN, and EVERY collector found something in it.
    #    A collector that silently returns nothing reports zero duplicates.
    if reg.findings:
        failures.append(f"the clean fixture reported findings: {reg.findings}")
    for collector in COLLECTORS:
        if not reg.counts.get(collector):
            failures.append(f"collector {collector!r} found nothing in the "
                            f"clean fixture")

    # 5. ONE PLANTED DUPLICATE PER NAMESPACE. Each case mutates a copy of the
    #    clean fixture -- which case 4 has just proven green -- so the RED is
    #    attributable to the plant and to nothing else.
    for label, docs, want_ns in _planted_cases(clean):
        got = evaluate(docs)
        hit = [f for f in got.findings if f["namespace"] == want_ns]
        if not hit:
            failures.append(f"planting {label} did not red the namespace "
                            f"{want_ns!r} (findings: "
                            f"{[f['namespace'] for f in got.findings]})")
            continue
        f = hit[0]
        if not (f["first"] and f["second"] and f["first"] != f["second"]):
            failures.append(f"{label}: the finding did not name two distinct sites")

    # 6. THE SAME ID IN TWO DIFFERENT NAMESPACES IS GREEN. Uniqueness is per
    #    namespace; the ONE cross-namespace clause is `actions` U
    #    `native_intercepts`, and it is case 5's own row. Without this arm a
    #    gate that pooled every id into one set would pass every case above.
    cross = dict(clean)
    cross["workspace/panels/alpha.yaml"] = cross["workspace/panels/alpha.yaml"].replace(
        "id: alpha_row", "id: shared_name")
    cross["workspace/dialogs/first.yaml"] = cross["workspace/dialogs/first.yaml"].replace(
        "id: first_row", "id: shared_name")
    got = evaluate(cross)
    if got.findings:
        failures.append(f"one id reused across two namespaces must stay GREEN, "
                        f"got {got.findings}")

    # 7. CHORD NORMALIZATION. `Ctrl+N` and `ctrl+n` are the SAME chord to
    #    resolve_key.parse_shortcut, so a raw-string comparison would miss the
    #    shadowing the gate exists to catch.
    if _normalize_chord("Ctrl+N") != _normalize_chord("ctrl+n"):
        failures.append("chord normalization does not fold modifier/letter case")
    if _normalize_chord("Ctrl+Shift+S") == _normalize_chord("Ctrl+S"):
        failures.append("chord normalization collapsed two distinct chords")

    for f in failures:
        print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
    if failures:
        return 1
    print(f"check_workspace_ids SELF-TEST: OK (empty scan refuses, proven "
          f"FIRST; the derived floor refuses a short scan and passes a full "
          f"one; an unparseable file refuses; all {len(COLLECTORS)} collectors "
          f"find something in a clean fixture; a planted duplicate reds each "
          f"of {len(_planted_cases(_fixture()))} namespaces naming both sites; "
          f"one id in two namespaces stays green; chord case-folding matches "
          f"parse_shortcut).")
    return 0


def _vacuous(reg, n_docs, floor):
    """The anti-vacuity predicate, extracted so the self-test drives the same
    one main() uses. True when the scan cannot be trusted to have LOOKED:
    fewer files read than git's index holds, or nothing collected from the
    ones that were read."""
    return (n_docs < floor
            or reg.counts.get("mapping-keys", 0) == 0
            or reg.ids == 0)


def _fixture():
    """A miniature workspace exercising every namespace exactly once, so a
    planted duplicate has one possible cause."""
    return {
        "workspace/app.yaml": "version: 1\napp:\n  name: fixture\n",
        "workspace/layout.yaml": (
            "layout:\n"
            "  id: root\n"
            "  type: pane_system\n"
            "  children:\n"
            "    - id: pane_a\n"
            "      type: pane\n"
            "      title_bar:\n"
            "        buttons:\n"
            "          - id: pane_a_close\n"
            "            type: icon_button\n"
            "      content:\n"
            "        type: container\n"
            "        children:\n"
            "          - id: grid_a\n"
            "            type: grid\n"
        ),
        "workspace/menubar.yaml": (
            "menubar:\n"
            "  - id: file_menu\n"
            "    items:\n"
            "      - { id: menu_new, action: new_document }\n"
            "      - separator\n"
            "      - id: sub_menu\n"
            "        items:\n"
            "          - { id: menu_nested, action: quit }\n"
        ),
        "workspace/shortcuts.yaml": (
            "shortcuts:\n"
            "  - { key: \"Ctrl+N\", action: new_document }\n"
            "  - { key: \"V\", action: select_tool }\n"
        ),
        "workspace/actions.yaml": (
            "native_intercepts:\n"
            "  - export_to_pdf\n"
            "actions:\n"
            "  new_document:\n"
            "    effects: []\n"
            "  quit:\n"
            "    effects: []\n"
        ),
        "workspace/panels/alpha.yaml": (
            "id: alpha_panel_content\n"
            "type: panel\n"
            "content:\n"
            "  type: container\n"
            "  children:\n"
            "    - id: alpha_row\n"
            "      type: row\n"
        ),
        "workspace/panels/beta.yaml": (
            "id: beta_panel_content\n"
            "type: panel\n"
            "content:\n"
            "  type: container\n"
            "  children:\n"
            "    - id: beta_row\n"
            "      type: row\n"
        ),
        "workspace/tools/pen.yaml": "id: pen\ncursor: crosshair\n",
        "workspace/tools/rect.yaml": "id: rect\ncursor: crosshair\n",
        "workspace/concepts/star.yaml": (
            "id: star\n"
            "operations:\n"
            "  - { id: add_point, label: Add }\n"
            "  - { id: remove_point, label: Remove }\n"
            "constraints:\n"
            "  - { id: min_points, check: \"param.points >= 3\" }\n"
        ),
        "workspace/dialogs/first.yaml": (
            "first_dialog:\n"
            "  content:\n"
            "    type: container\n"
            "    children:\n"
            "      - id: first_row\n"
            "        type: row\n"
        ),
        "workspace/dialogs/second.yaml": (
            "second_dialog:\n"
            "  content:\n"
            "    type: container\n"
            "    children:\n"
            "      - id: second_row\n"
            "        type: row\n"
        ),
        "workspace/templates/slider.yaml": (
            "slider_row:\n"
            "  content:\n"
            "    type: row\n"
            "    children:\n"
            "      - id: slider_label\n"
            "        type: text\n"
        ),
        "workspace/templates/swatch.yaml": (
            "swatch_row:\n"
            "  content:\n"
            "    type: row\n"
            "    children:\n"
            "      - id: swatch_label\n"
            "        type: text\n"
        ),
    }


def _planted_cases(clean):
    """[(label, docs, namespace that must red)] -- one plant per namespace."""
    cases = []

    def variant(label, path, old, new, namespace):
        docs = dict(clean)
        assert old in docs[path], f"fixture drift: {old!r} not in {path}"
        docs[path] = docs[path].replace(old, new, 1)
        cases.append((label, docs, namespace))

    # A repeated key inside one mapping -- PyYAML keeps the last, silently.
    variant("a repeated mapping key", "workspace/actions.yaml",
            "  quit:\n    effects: []\n",
            "  quit:\n    effects: []\n  new_document:\n    effects: []\n",
            "mapping-key workspace/actions.yaml/actions")
    # Two top-level files claiming the same top-level key (data.update).
    cases.append(("a top-level key in two files",
                  dict(clean, **{"workspace/theme.yaml": "app:\n  name: other\n"}),
                  "workspace top-level key"))
    # Two panel files filed under one entity id (merged[entity_id]).
    variant("two panels with one id", "workspace/panels/beta.yaml",
            "id: beta_panel_content", "id: alpha_panel_content",
            "panels entity id")
    # Two tool files filed under one entity id -- the case the validator's
    # per-tool stem check structurally cannot see, because the merge has
    # already dropped one of them before it runs.
    variant("two tools with one id", "workspace/tools/rect.yaml",
            "id: rect", "id: pen", "tools entity id")
    cases.append(("two concept files with one id",
                  dict(clean, **{"workspace/concepts/gear.yaml": "id: star\n"}),
                  "concepts entity id"))
    # Two dialog files declaring one dialog key (merged.update).
    variant("a dialog key in two files", "workspace/dialogs/second.yaml",
            "second_dialog:", "first_dialog:", "dialogs key")
    variant("a template key in two files", "workspace/templates/swatch.yaml",
            "swatch_row:", "slider_row:", "templates key")
    # find_element_by_id returns the FIRST match of a depth-first walk.
    variant("a layout element id", "workspace/layout.yaml",
            "id: grid_a", "id: pane_a", "layout element id")
    variant("a menubar item id", "workspace/menubar.yaml",
            "id: menu_nested", "id: menu_new", "menubar id")
    variant("a panel widget id", "workspace/panels/alpha.yaml",
            "    - id: alpha_row\n      type: row\n",
            "    - id: alpha_row\n      type: row\n    - id: alpha_row\n"
            "      type: row\n",
            "panel:alpha_panel_content element id")
    variant("a dialog widget id", "workspace/dialogs/first.yaml",
            "      - id: first_row\n        type: row\n",
            "      - id: first_row\n        type: row\n      - id: first_row\n"
            "        type: row\n",
            "dialog:first_dialog element id")
    variant("a template widget id", "workspace/templates/slider.yaml",
            "      - id: slider_label\n        type: text\n",
            "      - id: slider_label\n        type: text\n"
            "      - id: slider_label\n        type: text\n",
            "template:slider_row element id")
    variant("a concept operation id", "workspace/concepts/star.yaml",
            "{ id: remove_point, label: Remove }", "{ id: add_point, label: Remove }",
            "concept:star operations id")
    cases.append(("a concept constraint id",
                  dict(clean, **{"workspace/concepts/star.yaml":
                                 clean["workspace/concepts/star.yaml"] +
                                 "  - { id: min_points, check: \"true\" }\n"}),
                  "concept:star constraints id"))
    # resolve_key_in returns the FIRST matching chord -- and the chords here
    # differ as TEXT, so this arm also drives the normalization.
    variant("a shadowed shortcut chord", "workspace/shortcuts.yaml",
            "{ key: \"V\", action: select_tool }",
            "{ key: \"ctrl+n\", action: select_tool }", "shortcut chord")
    # THE CROSS-NAMESPACE CLAUSE: a verb in `actions:` AND `native_intercepts:`.
    variant("a verb in actions and native_intercepts", "workspace/actions.yaml",
            "  - export_to_pdf", "  - quit", "action verb")
    return cases


def main():
    ap = argparse.ArgumentParser(
        description="Workspace id-uniqueness gate (VISION.md §11).")
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
        reg = evaluate(docs)
        if _vacuous(reg, n_docs=len(docs), floor=floor):
            raise Refusal(
                f"the scan read {len(docs)} workspace YAML files (git's index "
                f"holds {floor}) and collected {reg.ids} ids. A scan that reads "
                f"less than the tree, or collects nothing from what it read, "
                f"reports fewer duplicates than the tree has -- and reads "
                f"exactly like a clean tree.")
        dead = [c for c in COLLECTORS if not reg.counts.get(c)]
        if dead:
            raise Refusal(
                f"these collectors found NOTHING in the live workspace: "
                f"{', '.join(dead)}. Each one watches a real namespace, so an "
                f"empty one means the shape it walks has moved -- not that the "
                f"namespace is clean.")
    except Refusal as r:
        print(f"REFUSED: {r}", file=sys.stderr)
        return 1

    if reg.findings:
        print(f"FAIL: {len(reg.findings)} duplicate id(s) in the workspace "
              f"sources:", file=sys.stderr)
        _report(reg, stream=sys.stderr)
        print("\nEach namespace is one resolution table, and every one of them "
              "resolves a\nduplicate SILENTLY -- last-wins for the YAML merges "
              "(a repeated mapping key,\n`data.update`, `merged[entity_id]`, "
              "`merged.update`), first-wins for the walks\n"
              "(`find_element_by_id`, `resolve_key_in`). Rename one of the two "
              "sites.", file=sys.stderr)
        return 1

    print(f"OK: {len(reg.namespaces)} namespaces, {reg.ids} ids, 0 duplicates "
          f"({len(docs)} workspace YAML files scanned, floor {floor} from "
          f"git's index).")
    # The per-collector census, printed on a PASSING run. A collector going
    # quiet is refused above; this is so a HUMAN can see one going THIN, which
    # no threshold catches.
    print("  " + " | ".join(f"{c} {reg.counts.get(c, 0)}" for c in COLLECTORS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
