"""Schema loader for the workspace state fields.

Builds an in-memory (scope, field_name) → SchemaEntry lookup table from
workspace/state.yaml and workspace/panels/*.yaml.  The table is the
authoritative source for the schema-driven set: effect.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Any


CANONICAL_TYPES = frozenset({"bool", "number", "string", "color", "enum", "list", "object"})

_COLOR_RE = re.compile(r'^#[0-9a-fA-F]{6}$')
_NUMBER_STR_RE = re.compile(r'^-?\d+(\.\d+)?$')


class SchemaError(Exception):
    """Raised when a schema entry is malformed (fatal — app should not start)."""


@dataclass
class SchemaEntry:
    type: str
    default: Any
    nullable: bool = False
    writable: bool = True
    values: list[str] | None = None   # required when type == "enum"
    item_type: str | None = None      # optional when type == "list"
    description: str = ""


class SchemaTable:
    """Maps (scope, field_name) → SchemaEntry.

    scope is one of:
      "state"           — global fields from state.yaml
      "panel:<id>"      — per-panel fields from panels/<id>.yaml
    """

    def __init__(self):
        self._entries: dict[tuple[str, str], SchemaEntry] = {}

    def add(self, scope: str, field_name: str, entry: SchemaEntry) -> None:
        self._entries[(scope, field_name)] = entry

    def get(self, scope: str, field_name: str) -> SchemaEntry | None:
        return self._entries.get((scope, field_name))

    def resolve(
        self, key: str, active_panel: str | None
    ) -> tuple[str, str, SchemaEntry] | str | None:
        """Resolve a set: key to (scope, field_name, entry).

        Returns:
          (scope, field_name, entry)  on success
          "ambiguous"                 if bare key matches both state and active panel
          None                        if not found in any scope

        Scope resolution (from SET_EFFECT.md §4):
          1. Dotted key "panel.<field>"  → active panel scope, field = <field>
          2. Dotted key "<id>.<field>"   → scope "panel:<id>", field = <field>
          3. Bare key                    → try "state", then "panel:<active>",
                                          error if found in both
        """
        if "." in key:
            prefix, rest = key.split(".", 1)
            if prefix == "panel":
                if active_panel is None:
                    return None
                scope = f"panel:{active_panel}"
            else:
                scope = f"panel:{prefix}"
            entry = self._entries.get((scope, rest))
            return (scope, rest, entry) if entry is not None else None

        # Bare key: try state then active panel
        state_entry = self._entries.get(("state", key))
        panel_entry = (
            self._entries.get((f"panel:{active_panel}", key))
            if active_panel else None
        )
        if state_entry is not None and panel_entry is not None:
            return "ambiguous"
        if state_entry is not None:
            return ("state", key, state_entry)
        if panel_entry is not None:
            return (f"panel:{active_panel}", key, panel_entry)
        return None


def _parse_entry(name: str, defn: dict) -> SchemaEntry:
    if not isinstance(defn, dict):
        raise SchemaError(f"Field {name!r}: definition must be a mapping, got {type(defn).__name__}")
    type_ = defn.get("type")
    if type_ not in CANONICAL_TYPES:
        raise SchemaError(f"Field {name!r}: unknown type {type_!r}; expected one of {sorted(CANONICAL_TYPES)}")
    if type_ == "enum" and "values" not in defn:
        raise SchemaError(f"Field {name!r}: enum type requires 'values' list")
    return SchemaEntry(
        type=type_,
        default=defn.get("default"),
        nullable=bool(defn.get("nullable", False)),
        writable=bool(defn.get("writable", True)),
        values=list(defn["values"]) if "values" in defn else None,
        item_type=defn.get("item_type"),
        description=str(defn.get("description", "")),
    )


def load_schema_from_dict(
    state_defs: dict | None,
    panels_defs: dict[str, dict] | None = None,
) -> SchemaTable:
    """Build a SchemaTable from in-memory dicts (used by test fixtures)."""
    table = SchemaTable()
    for name, defn in (state_defs or {}).items():
        entry = _parse_entry(name, defn)
        table.add("state", name, entry)
    for panel_id, panel_fields in (panels_defs or {}).items():
        for name, defn in panel_fields.items():
            entry = _parse_entry(name, defn)
            table.add(f"panel:{panel_id}", name, entry)
    return table


def load_schema_from_workspace(workspace_dir: str) -> SchemaTable:
    """Build a SchemaTable by reading state.yaml and panels/*.yaml.

    Raises SchemaError (fatal) if any entry is malformed.
    """
    import yaml

    table = SchemaTable()
    errors: list[str] = []

    state_path = os.path.join(workspace_dir, "state.yaml")
    if os.path.exists(state_path):
        with open(state_path) as f:
            doc = yaml.safe_load(f)
        for name, defn in (doc.get("state") or {}).items():
            try:
                table.add("state", name, _parse_entry(name, defn))
            except SchemaError as e:
                errors.append(str(e))

    panels_dir = os.path.join(workspace_dir, "panels")
    if os.path.isdir(panels_dir):
        for fname in sorted(os.listdir(panels_dir)):
            if not fname.endswith(".yaml"):
                continue
            panel_id = fname[:-5]
            fpath = os.path.join(panels_dir, fname)
            with open(fpath) as f:
                doc = yaml.safe_load(f)
            for name, defn in (doc.get("state") or {}).items():
                try:
                    table.add(f"panel:{panel_id}", name, _parse_entry(name, defn))
                except SchemaError as e:
                    errors.append(str(e))

    if errors:
        raise SchemaError("Schema load errors (app cannot start):\n" + "\n".join(errors))

    return table


def coerce_value(value: Any, entry: SchemaEntry) -> tuple[Any, str | None]:
    """Coerce a Python value to match the schema entry's declared type.

    Returns (coerced_value, error_reason).  error_reason is None on success.
    The coerced value is undefined when error_reason is not None.
    """
    if value is None:
        return (None, None) if entry.nullable else (None, "null_on_non_nullable")

    t = entry.type

    if t == "bool":
        if isinstance(value, bool):
            return value, None
        if isinstance(value, str) and value in ("true", "false"):
            return value == "true", None
        return None, "type_mismatch"

    if t == "number":
        if isinstance(value, bool):   # bool is a subclass of int — reject it
            return None, "type_mismatch"
        if isinstance(value, (int, float)):
            return float(value), None
        if isinstance(value, str) and _NUMBER_STR_RE.match(value):
            return float(value), None
        return None, "type_mismatch"

    if t == "string":
        if isinstance(value, str):
            return value, None
        return None, "type_mismatch"

    if t == "color":
        if isinstance(value, str) and _COLOR_RE.match(value):
            return value, None
        return None, "type_mismatch"

    if t == "enum":
        allowed = entry.values or []
        if isinstance(value, str) and value in allowed:
            return value, None
        return None, "enum_value_not_in_values"

    if t == "list":
        if not isinstance(value, list):
            return None, "type_mismatch"
        if entry.item_type:
            item_entry = SchemaEntry(type=entry.item_type, default=None)
            coerced_items: list = []
            for item in value:
                c, err = coerce_value(item, item_entry)
                if err:
                    return None, "type_mismatch"
                coerced_items.append(c)
            return coerced_items, None
        return value, None

    if t == "object":
        if isinstance(value, dict):
            return value, None
        return None, "type_mismatch"

    return None, "type_mismatch"
