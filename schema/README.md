# Workspace YAML Schemas

JSON Schema definitions for the workspace YAML format. Used by:

1. **Compile-time validation**: `workspace_interpreter.compile` runs
   validation before emitting `workspace/workspace.json`. CI fails on
   schema errors.
2. **Editor tooling**: YAML Language Server (VS Code's Red Hat YAML
   extension, Neovim, etc.) picks up JSON Schema references and shows
   live errors as authors type.
3. **Documentation**: each schema's `description` fields double as
   reference docs for YAML authors.

## Schema catalog

| Schema | Applies to |
|---|---|
| `app.schema.json` | `workspace/app.yaml` |
| `tool.schema.json` | `workspace/tools/*.yaml` |
| `elements.schema.json` | `workspace/elements.yaml` |
| `preferences.schema.json` | `workspace/preferences.yaml` |
| `features.schema.json` | `workspace/features.yaml` |
| `panel.schema.json` | `workspace/panels/*.yaml` — one panel each |
| `dialog.schema.json` | `workspace/dialogs/*.yaml` — one dialog each |
| `action.schema.json` | `workspace/actions.yaml` — one action each |
| `menubar.schema.json` | `workspace/menubar.yaml` |
| `layout.schema.json` | `workspace/layout.yaml` (the pane system: toolbar, canvas, dock) |
| `widget.schema.json` | not a document: the widget tree the panel, dialog and layout schemas reach by a cross-file `$ref` |

The last six landed 2026-09-05 (VISION.md §11's last named gate). What they
CLOSE: the top-level key set of every panel, dialog, action and menubar item
(an unknown key is a refusal); the widget key set and the widget `type` enum
(the canonical kinds `widget_tree.CANONICAL_WIDGET_KINDS`, plus the pane-system
kinds in layout.yaml only); every `bind:` value an expression string; the
effect vocabulary and the action categories as closed lists; dialog state as
stored (`type` + `default`) or derived (`get` + `set`). What they LEAVE OPEN,
on purpose: `style:` (the renderers' vocabulary), per-kind widget properties
beyond their type, effect payload shapes, and expression parsing (layer 3).
Cross-file `$ref`s resolve through a `referencing` registry built from this
directory, never the network; the hand-rolled fallback used when `jsonschema`
is absent skips `$ref`, `oneOf` and `anyOf`, so under it the widget tree is
unvalidated — CI installs `jsonschema`.

## Editor integration

Add a header comment to any `workspace/*.yaml` to enable live
validation in supported editors:

```yaml
# yaml-language-server: $schema=../../schema/tool.schema.json
id: pen
...
```

## Validation layers

The compiler runs three layers of validation. JSON Schema covers only
Layer 1:

- **Layer 1 — Structural** (JSON Schema here): required fields, types,
  enums, unknown-key detection.
- **Layer 2 — Cross-reference** (Python validator): every `action:`
  reference resolves, every `$state.xxx` read has a declaration, no
  duplicate IDs.
- **Layer 3 — Expression parsing** (Python validator): every
  expression string parses via the expression parser; failures reported
  with file:line context.

Layers 2 and 3 live in `workspace_interpreter/validator.py`.

## Adding a new schema

1. Create `schema/<name>.schema.json` with a JSON Schema document.
2. Update `workspace_interpreter/validator.py` to wire the schema to
   its target file(s).
3. Add a fixture test under `workspace_interpreter/tests/` that loads
   a canonical example and verifies it validates.
4. Document here under "Schema catalog."

## Schema versioning

Workspace YAML's `schema_version:` stamp (in `workspace/app.yaml`) is
checked by the compiler. When the schema format evolves:

1. Bump the major version for breaking changes (rename fields, remove
   fields, change value shapes).
2. Bump the minor version for additive changes (new optional fields).
3. The compiler rejects unknown versions. A separate `--migrate`
   subcommand applies known rewrites to upgrade older YAML.
