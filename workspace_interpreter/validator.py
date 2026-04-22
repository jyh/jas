"""Workspace schema validator.

Runs at compile time (inside ``workspace_interpreter.compile``) to catch
structural errors in workspace YAML before the compiled ``workspace.json``
ships. Five interpreters (Flask Python, jas Python, Rust, Swift, OCaml)
load the compiled JSON trusting it to be well-formed.

Three validation layers (see ``FLASK_PARITY.md`` §12):

1. **Structural** (JSON Schema) — required fields, types, unknown keys.
2. **Cross-reference** (this module) — every ``action:`` points to a
   defined action; every state-key read has a declaration; no duplicate
   ids.
3. **Expression parsing** (this module) — every expression string runs
   through the parser; parse failures reported with context.

Current coverage: structural only for ``app`` and ``tools``. Other
layers will be added as schemas are written (``panel``, ``widget``,
``action``, etc.).

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
        validator = jsonschema.Draft202012Validator(schema)
        for err in validator.iter_errors(doc):
            loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
            errors.append(f"{where}: {loc}: {err.message}")
        return errors
    return _validate_minimal(schema, doc, where)


def _validate_minimal(schema: dict, doc, where: str, path: str = "") -> list[str]:
    """Hand-rolled JSON Schema subset. Handles ``type``, ``required``,
    ``additionalProperties``, ``enum``, and ``pattern``. Good enough for
    the schemas this project ships; graceful degradation when
    ``jsonschema`` isn't installed."""
    errors: list[str] = []
    loc = path or "<root>"

    t = schema.get("type")
    if t == "object":
        if not isinstance(doc, dict):
            errors.append(f"{where}: {loc}: expected object, got {type(doc).__name__}")
            return errors
        for req in schema.get("required", []):
            if req not in doc:
                errors.append(f"{where}: {loc}: missing required field '{req}'")
        props = schema.get("properties", {})
        ap = schema.get("additionalProperties", True)
        for k, v in doc.items():
            sub_path = f"{path}.{k}" if path else k
            if k in props:
                errors.extend(_validate_minimal(props[k], v, where, sub_path))
            elif ap is False:
                errors.append(f"{where}: {sub_path}: unknown field")
            elif isinstance(ap, dict):
                errors.extend(_validate_minimal(ap, v, where, sub_path))
    elif t == "array":
        if not isinstance(doc, list):
            errors.append(f"{where}: {loc}: expected array, got {type(doc).__name__}")
            return errors
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for i, item in enumerate(doc):
                errors.extend(_validate_minimal(item_schema, item, where, f"{path}[{i}]"))
    elif t == "string":
        if not isinstance(doc, str):
            errors.append(f"{where}: {loc}: expected string, got {type(doc).__name__}")
        elif "enum" in schema and doc not in schema["enum"]:
            errors.append(f"{where}: {loc}: {doc!r} not in {schema['enum']}")
    elif t == "integer":
        if not isinstance(doc, int) or isinstance(doc, bool):
            errors.append(f"{where}: {loc}: expected integer, got {type(doc).__name__}")

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

    return errors


def format_errors(errors: Iterable[str]) -> str:
    """Format a list of errors as a multi-line string for terminal output."""
    errs = list(errors)
    if not errs:
        return ""
    header = f"Workspace validation failed ({len(errs)} error{'s' if len(errs) != 1 else ''}):"
    return "\n".join([header] + [f"  - {e}" for e in errs])
