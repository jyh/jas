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

(Additional schemas will be added as the workspace grows: `panel.schema.json`,
`widget.schema.json`, `action.schema.json`, `effect.schema.json`,
`element.schema.json`, `expression.schema.json`.)

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
