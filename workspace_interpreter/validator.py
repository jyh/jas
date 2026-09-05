"""Workspace STRUCTURAL validator — layer 1 of ``FLASK_PARITY.md`` §12, and
only layer 1.

Runs at compile time (inside ``workspace_interpreter.compile``) to catch
structural errors in workspace YAML before the compiled ``workspace.json``
ships. Five interpreters (Flask Python, jas Python, Rust, Swift, OCaml)
load the compiled JSON trusting it to be well-formed.

WHAT THIS MODULE VALIDATES TODAY — the whole list:

1. ``schema_version`` is one of ``SUPPORTED_SCHEMA_VERSIONS``. Absent is
   accepted, for workspaces predating the field.
2. The ``app`` top-level document, against ``schema/app.schema.json``.
3. Every entry of ``tools:``, against ``schema/tool.schema.json``, plus
   the one cross-check this module owns: a tool's declared ``id`` must
   equal the key it is filed under. Read that check for what it COVERS:
   the key is the filename stem only until two tool files claim one id,
   at which point ``loader.load_workspace``'s ``merged[entity_id] = part``
   has already dropped one of them and this check finds the survivor
   agreeing with itself. Uniqueness is not what it asserts.
4. The ``elements``, ``preferences`` and ``features`` sections, each
   against its own schema.
5. Every panel against ``schema/panel.schema.json`` (its error names the
   panel's source file, ``panels/<kind>.yaml``), every dialog against
   ``dialog.schema.json``, every action against ``action.schema.json``,
   the ``menubar`` and the ``layout`` (the pane system holding the
   toolbar) against theirs — the six that landed 2026-09-05, sharing the
   widget tree through ``widget.schema.json`` by a cross-file ``$ref``
   resolved from the repo's own files (:func:`_schema_registry`). They
   close the key sets, the widget kinds, the effect vocabulary and the
   action categories; they leave ``style:``, per-kind widget properties
   and effect payloads open, on purpose. When first run on the real
   tree they went red on 63 sites and every one was a form the census
   had missed, none a defect — a clean negative, reported as one. The
   fallback checker (:func:`_validate_minimal`) refuses what they refuse
   too, driven with ``jsonschema`` forced absent.

Nothing else. In particular this module implements NEITHER layer 2
(cross-reference) NOR layer 3 (expression parsing) of ``FLASK_PARITY.md``
§12. Until 2026-09-03 this docstring claimed both, and named "no
duplicate ids" and "every state-key read has a declaration" as things
this module does — a claim that had never been true and that no reader of
the code below could have reconciled. ``VISION.md`` §11 carried it as
"related and unrepaired"; this is the repair.

WHERE THE OTHER LAYERS ACTUALLY LIVE

* *every* ``action:`` *reference resolves* — ``scripts/check_action_refs.py``
  (CI), and ``TestValidateActionRefs`` in
  ``workspace_interpreter/tests/test_loader.py``.
* *no duplicate ids* — ``scripts/check_workspace_ids.py`` (CI), per
  namespace over the workspace YAML sources. It reads the SOURCES rather
  than this module's input on purpose: by the time a workspace dict
  reaches :func:`validate_workspace`, PyYAML has kept the LAST of two
  duplicate mapping keys and raised nothing, so the duplicate cannot be
  seen from here at all.
* *every* ``$state`` *read has a declaration* — ``scripts/check_state_reads.py``,
  which parses every expression string in the workspace YAML with THIS
  package's own ``expr_parser`` and resolves each ``state.`` / ``panel.``
  / ``tool.<id>.`` / ``dialog.`` read against the one namespace its head
  segment selects. Until 2026-09-03 this line read "NOT BUILT, anywhere",
  which was true when it was written; it then read "built and
  self-tested, live arm NOT wired", which was true for as long as main
  carried the 13 findings the gate surfaced. Read what is WIRED NOW: CI
  runs ``--self-test`` AND the live scan on both platform families
  (``.github/workflows/test.yml:98`` and ``:742-743``). All 13 findings
  were repaired in the YAML with forms the grammar already had — no port
  gained an operator — except one that is NAMED rather than exempted:
  ``sort_brushes_by_name`` wanted a data path computed from state, which
  no port can express, so it is a log-only stub that says so. Details in
  ``VISION.md`` §11; behaviour pinned in
  ``workspace_interpreter/tests/test_state_read_findings.py``. Note the
  spelling too: ``$state`` is FLASK_PARITY-era and occurs in no workspace
  YAML today — a read is a dotted path inside an expression string.
* *enum values match declared* — by schema rather than by code, and since
  2026-09-05 over every authored section: ``schema/`` covers app, tool,
  elements, features, preferences, panels, dialogs, actions, menubar and
  the layout (toolbar included). What remains open is named in
  ``schema/README.md``, not
  all.
* *expression parsing* — no compile-time pass over the workspace exists.
  The expression language is pinned by the cross-language corpus
  (``scripts/compile_expr_corpus.py`` and its CI freshness gate), which
  parses the CORPUS, not every expression string in the YAML.

The validator prefers json-schema-spec but gracefully degrades to a
minimal hand-rolled checker when the ``jsonschema`` package is not
installed — keeping CI green without forcing a new runtime dep.
"""

from __future__ import annotations

import json
import os
from typing import Iterable


SCHEMA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "schema",
)

SUPPORTED_SCHEMA_VERSIONS = ("2.0",)


class ValidationError(Exception):
    """Raised when validation finds errors. ``messages`` is a list of
    human-readable diagnostics; the exception's ``args[0]`` is a
    newline-joined summary for Python's default formatter."""

    def __init__(self, messages: list[str]) -> None:
        self.messages = messages
        super().__init__("\n".join(messages) if messages else "validation failed")


def _load_schema(name: str) -> dict:
    """Load a JSON Schema file from the repo-root ``schema/`` directory."""
    path = os.path.join(SCHEMA_DIR, f"{name}.schema.json")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _try_import_jsonschema():
    """Return the ``jsonschema`` module if installed, else ``None``."""
    try:
        import jsonschema  # type: ignore
        return jsonschema
    except ImportError:
        return None


_REGISTRY = None


def _schema_registry():
    """Every ``schema/*.schema.json`` registered under its ``$id``, so a
    cross-file ``$ref`` (``widget.schema.json#/$defs/widget`` from
    panel/dialog/layout) resolves against the repo's own files and never
    the network. Built once per process."""
    global _REGISTRY
    if _REGISTRY is None:
        from referencing import Registry, Resource
        resources = []
        for fname in sorted(os.listdir(SCHEMA_DIR)):
            if not fname.endswith(".schema.json"):
                continue
            with open(os.path.join(SCHEMA_DIR, fname), encoding="utf-8") as f:
                contents = json.load(f)
            resources.append((contents["$id"], Resource.from_contents(contents)))
        _REGISTRY = Registry().with_resources(resources)
    return _REGISTRY


def _validate_structural(schema_name: str, doc: dict, where: str) -> list[str]:
    """Validate ``doc`` against ``schema/<schema_name>.schema.json``.

    Uses ``jsonschema`` when available; falls back to a minimal checker
    that covers the common shapes (required fields, type, enum) when
    ``jsonschema`` isn't installed.
    """
    schema = _load_schema(schema_name)
    jsonschema = _try_import_jsonschema()
    if jsonschema is not None:
        errors = []
        validator = jsonschema.Draft202012Validator(schema, registry=_schema_registry())
        for err in validator.iter_errors(doc):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{where}: {loc}: {err.message}")
        return errors
    return _validate_minimal(schema, doc, where)


def _resolve_ref(ref: str, root: dict) -> tuple[dict, dict]:
    """Resolve a ``$ref`` to ``(schema, root)``: a local ``#/$defs/x`` against
    ``root``; a cross-file ``<name>.schema.json#/$defs/x`` against that file,
    which becomes the new root for refs inside it. The same two forms the
    shipped schemas use and the ``referencing`` registry resolves for
    ``jsonschema``; anything else is refused loudly rather than skipped."""
    file_part, _, frag = ref.partition("#")
    if file_part:
        if not file_part.endswith(".schema.json"):
            raise ValueError(f"unsupported $ref {ref!r}")
        root = _load_schema(file_part[: -len(".schema.json")])
    node: dict = root
    for seg in frag.strip("/").split("/") if frag.strip("/") else []:
        node = node[seg]
    return node, root


_JSON_TYPES = {
    "object": lambda d: isinstance(d, dict),
    "array": lambda d: isinstance(d, list),
    "string": lambda d: isinstance(d, str),
    "integer": lambda d: isinstance(d, int) and not isinstance(d, bool),
    "number": lambda d: isinstance(d, (int, float)) and not isinstance(d, bool),
    "boolean": lambda d: isinstance(d, bool),
    "null": lambda d: d is None,
}


def _validate_minimal(schema: dict, doc, where: str, path: str = "",
                      root: dict | None = None) -> list[str]:
    """Hand-rolled JSON Schema subset — the checker used when ``jsonschema``
    is not installed. It understands what the shipped schemas use and nothing
    more: ``type`` (a name or a list of names, all seven JSON types),
    ``required``, ``properties``, ``additionalProperties`` (bool or schema),
    ``items``, ``enum`` (any type), ``minProperties``, ``allOf``, ``anyOf`` /
    ``oneOf`` (satisfied by any one branch — the exclusivity half of ``oneOf``
    is not checked), and ``$ref`` in the two forms ``_resolve_ref`` names.
    ``pattern`` is still not enforced. Until 2026-09-05 it knew none of
    ``$ref`` / ``anyOf`` / ``oneOf`` / ``allOf`` / list-typed ``type``, so under
    it the widget tree, the effect vocabulary and every ``$defs`` entry went
    unvalidated while the run reported green — a fallback that degrades
    silently is a gate that reads as coverage. ``test_validator.py`` drives
    this checker over the real workspace and over each planted defect with
    ``jsonschema`` forced absent."""
    root = schema if root is None else root
    errors: list[str] = []
    loc = path or "<root>"

    if "$ref" in schema:
        target, target_root = _resolve_ref(schema["$ref"], root)
        errors.extend(_validate_minimal(target, doc, where, path, target_root))
        rest = {k: v for k, v in schema.items() if k != "$ref"}
        if rest:
            errors.extend(_validate_minimal(rest, doc, where, path, root))
        return errors

    for branch in schema.get("allOf", []):
        errors.extend(_validate_minimal(branch, doc, where, path, root))
    alternatives = schema.get("anyOf") or schema.get("oneOf")
    if alternatives:
        if not any(not _validate_minimal(b, doc, where, path, root) for b in alternatives):
            errors.append(f"{where}: {loc}: matches none of the {len(alternatives)} alternatives")

    t = schema.get("type")
    if t is not None:
        names = t if isinstance(t, list) else [t]
        if not any(_JSON_TYPES[n](doc) for n in names if n in _JSON_TYPES):
            errors.append(f"{where}: {loc}: expected {'/'.join(names)}, got {type(doc).__name__}")
            return errors
    if "enum" in schema and doc not in schema["enum"]:
        errors.append(f"{where}: {loc}: {doc!r} not in {schema['enum']}")

    if isinstance(doc, dict):
        for req in schema.get("required", []):
            if req not in doc:
                errors.append(f"{where}: {loc}: missing required field '{req}'")
        if "minProperties" in schema and len(doc) < schema["minProperties"]:
            errors.append(f"{where}: {loc}: fewer than {schema['minProperties']} properties")
        props = schema.get("properties", {})
        ap = schema.get("additionalProperties", True)
        for k, v in doc.items():
            sub_path = f"{path}.{k}" if path else k
            if k in props:
                errors.extend(_validate_minimal(props[k], v, where, sub_path, root))
            elif ap is False:
                errors.append(f"{where}: {sub_path}: unknown field")
            elif isinstance(ap, dict):
                errors.extend(_validate_minimal(ap, v, where, sub_path, root))
    elif isinstance(doc, list):
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for i, item in enumerate(doc):
                errors.extend(_validate_minimal(item_schema, item, where, f"{path}[{i}]", root))

    return errors


def validate_workspace(ws: dict) -> list[str]:
    """Validate a loaded workspace dict (pre-compile). Returns a list of
    error messages; empty list means valid.

    Callers:
    - ``workspace_interpreter.compile`` — fails the compile on non-empty
    - Flask dev-mode hot-reload — renders errors inline in browser
    """
    errors: list[str] = []

    # Schema version check.
    sv = ws.get("schema_version")
    if sv is None:
        # Backward-compat: workspaces pre-dating the field continue to
        # work, but a deprecation warning fires once schemas stabilize.
        pass
    elif sv not in SUPPORTED_SCHEMA_VERSIONS:
        errors.append(
            f"app.yaml: schema_version={sv!r} not in supported "
            f"{SUPPORTED_SCHEMA_VERSIONS}"
        )

    # Structural validation — app top-level.
    app_doc = {k: v for k, v in ws.items() if k in ("app", "version", "schema_version")}
    errors.extend(_validate_structural("app", app_doc, "app.yaml"))

    # Structural validation — each tool.
    for tool_id, tool_spec in (ws.get("tools") or {}).items():
        where = f"tools/{tool_id}.yaml"
        errors.extend(_validate_structural("tool", tool_spec, where))
        # Cross-check: filename stem must match declared id.
        declared = tool_spec.get("id")
        if declared is not None and declared != tool_id:
            errors.append(
                f"{where}: id field ({declared!r}) does not match "
                f"filename stem ({tool_id!r})"
            )

    # Structural validation — other top-level sections authored in
    # dedicated YAML files. Each schema validates only its own section
    # of the merged workspace dict; absent sections skip silently.
    section_schemas = (
        ("elements", "elements.yaml"),
        ("preferences", "preferences.yaml"),
        ("features", "features.yaml"),
        ("menubar", "menubar.yaml"),
        ("layout", "layout.yaml"),
    )
    for section_key, where in section_schemas:
        if section_key not in ws:
            continue
        section_doc = {section_key: ws[section_key]}
        errors.extend(_validate_structural(section_key, section_doc, where))

    # Structural validation — the per-entry sections: every panel, dialog
    # and action against its own schema, each error naming the SOURCE file
    # the entry was authored in (a panel's file is its short kind).
    for pid, spec in (ws.get("panels") or {}).items():
        stem = pid[: -len("_panel_content")] if pid.endswith("_panel_content") else pid
        errors.extend(_validate_structural("panel", spec, f"panels/{stem}.yaml"))
    for did, spec in (ws.get("dialogs") or {}).items():
        errors.extend(_validate_structural("dialog", spec, f"dialogs/{did}.yaml"))
    for aid, spec in (ws.get("actions") or {}).items():
        errors.extend(_validate_structural("action", spec, f"actions.yaml: {aid}"))

    return errors


def format_errors(errors: Iterable[str]) -> str:
    """Format a list of errors as a multi-line string for terminal output."""
    errs = list(errors)
    if not errs:
        return ""
    header = f"Workspace validation failed ({len(errs)} error{'s' if len(errs) != 1 else ''}):"
    return "\n".join([header] + [f"  - {e}" for e in errs])
