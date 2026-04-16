# Schema-Driven `set:` Effect — Specification

**Status**: Phase 1 Step 3 design. Precedes the reference implementation
in this directory (Step 4) and the per-language ports (Step 5).

## Why this exists

Today, the `set:` effect is implemented differently in each of the four
native apps:

- Rust handles only `fill_on_top` and `stroke_*` keys; everything else
  is silently dropped (Bug A3 in `AUDIT.md`).
- Python, OCaml, Swift all accept any key into a generic state bag and
  defer coercion to render-time helpers.

Phase 1's `Option B` decision (see `../AUDIT.md`) standardizes all four
languages on a **schema-driven** `set:` where the engine consults the
state schema for each key, coerces the YAML value per the declared
type, and writes to language-native storage.

This doc specifies the behavior all four languages must agree on.

---

## 1. Schema sources

The schema is built at startup from these YAML files:

1. **Tier 1 (global state)** — `workspace/state.yaml`
   - Top-level key is `state:`; entries are field definitions.
   - Field keys become addressable as bare names in `set:` effects.
2. **Tier 2 (per-panel state)** — `workspace/panels/<panel_id>.yaml`
   - Each panel's YAML has a top-level `state:` block.
   - Field keys are addressable as `panel.<field_name>` in `set:` when
     the named panel is active, or via dotted keys always.

Each field entry is a YAML map with:

| Key | Required | Meaning |
|---|---|---|
| `type` | yes | Canonical type name — see §2 |
| `default` | yes | Value used when the app starts or a document opens |
| `nullable` | no (default `false`) | Whether `null` is an allowed value |
| `writable` | no (default `true`) | Whether YAML `set:` may target this field |
| `values` | required when `type: enum` | List of allowed enum values |
| `item_type` | optional when `type: list` | Canonical type of list elements |
| `description` | no (but recommended) | Free-form doc |

Example:

```yaml
# workspace/state.yaml
state:
  fill_color:
    type: color
    default: "#ffffff"
    nullable: true
    description: "Active fill color (null = no fill)"
```

---

## 2. Canonical types

The engine recognizes exactly these `type:` values. New types require
a spec update and implementation in all four languages.

| Type | YAML values accepted | Internal representation |
|---|---|---|
| `bool` | YAML bool; strings `"true"` / `"false"` (case-sensitive) | native bool |
| `number` | YAML number; YAML string matching `/^-?\d+(\.\d+)?$/` | 64-bit float (all langs) |
| `string` | YAML string | native string |
| `color` | YAML string matching `/^#[0-9a-fA-F]{6}$/` or `null` (if nullable) | Rust: native `Color` struct (r, g, b fields). Python / OCaml / Swift: raw hex string stored in the generic state bag; readers coerce on demand. See §5 Color for coercion details. |
| `enum` | YAML string matching one of the declared `values` | native string (validated) |
| `list` | YAML list | native list of coerced items if `item_type` is declared, else raw list |
| `object` | YAML map | native dict/map (opaque to `set:` engine) |

**Nullability.** Any field with `nullable: true` also accepts YAML
`null`. Fields without `nullable: true` reject `null` as a type error.

**`tool_kind` and similar app-specific enums** fit the generic `enum`
type with `values:` listing all tool names. No special-case code.

---

## 3. Schema loader

At startup, each language implementation builds an in-memory
**schema table** keyed by `(scope, field_name)`:

- `scope` is one of:
  - `"state"` — Tier 1 global fields from `state.yaml`
  - `"panel:<panel_id>"` — Tier 2 fields from the corresponding
    `panels/<panel_id>.yaml`
- `field_name` is the bare key as declared in the YAML

Value is the full schema entry (type, default, nullable, writable,
values, etc.).

Pseudocode:

```
schema = {}
for (name, entry) in load("workspace/state.yaml").state:
    schema[("state", name)] = entry
for panel_file in glob("workspace/panels/*.yaml"):
    panel_id = basename(panel_file).replace(".yaml", "")
    for (name, entry) in load(panel_file).state or {}:
        schema[("panel:" + panel_id, name)] = entry
```

The schema table is read-only after load. If the loader encounters
a malformed entry (missing required key, invalid `type:` value, enum
without `values:`), it logs an error and the app fails to start —
schema bugs surface at boot, not at runtime.

---

## 4. `set:` effect semantics

**Input**: a YAML map under the `set:` key. Keys are field names;
values are YAML expressions (already evaluated by the expression engine
into a scalar / list / map by the time `set:` receives them).

```yaml
- set:
    fill_color: "#ff0000"
    stroke_color: null
    fill_on_top: true
```

**Scope resolution.** For each key in the set-map:

1. If the key contains a dot (e.g. `"panel.cap"`), split on the first
   dot. The prefix names the scope (`panel`) or a specific panel id
   (`panel:stroke`). The remainder is the bare field name.
2. Otherwise the key is a bare name. Resolution order:
   - First, try `("state", key)` in the schema table.
   - If not found, try `("panel:<active_panel>", key)` — the active
     panel determined by the runtime's current panel focus.
   - If still not found, it's an unknown key (see §6 error cases).

**Per-key processing.** For each resolved `(scope, key, entry)`:

1. If `entry.writable` is `false`, log a warning and skip the write.
2. Coerce the value per `entry.type` (see §5). If coercion fails,
   log an error and skip the write.
3. Apply the write to language-native storage:
   - Rust: dispatch to the corresponding `AppState` field setter
   - Swift / OCaml / Python: write coerced value to the generic state
     store at the resolved key

**Return type**: `unit`. Binding via `as:` is legal but produces a
useless binding (linter candidate for warning).

**Multi-key atomicity.** All writes in a single `set:` effect are
applied as a batch. UI observers see the post-batch state, not
intermediate states. Snapshots taken before the `set:` capture the
pre-batch state; snapshots after capture post-batch.

**Ordering within a batch.** Undefined. YAML authors must not rely on
evaluation order within a single `set:` map. If ordered writes are
needed, use multiple `set:` effects.

---

## 5. Coercion rules

Per-type coercion from the YAML-evaluated value. Coercion happens
AFTER the expression engine produces a value; this section describes
the value-to-field-type step, not expression evaluation.

### `bool`

| Input | Result |
|---|---|
| `true` (YAML bool) | `true` |
| `false` (YAML bool) | `false` |
| `"true"` (string, exact) | `true` |
| `"false"` (string, exact) | `false` |
| `null` (only if nullable) | `null` |
| anything else | **error** |

### `number`

| Input | Result |
|---|---|
| YAML int / float | converted to 64-bit float |
| YAML string matching `/^-?\d+(\.\d+)?$/` | parsed to float |
| `null` (only if nullable) | `null` |
| anything else | **error** |

### `string`

| Input | Result |
|---|---|
| YAML string | identity |
| `null` (only if nullable) | `null` |
| anything else | **error** |

### `color`

Coercion behavior splits by language to match each implementation's
storage model:

**Rust** (typed `AppState` struct):
| Input | Result |
|---|---|
| String matching `/^#[0-9a-fA-F]{6}$/` | parsed at `set:` time into the native `Color` struct (`r`, `g`, `b`) before writing to the field |
| `null` (only if nullable) | `None` assigned to the `Option<Color>` field |
| anything else | **error** |

**Python / OCaml / Swift** (generic state bag):
| Input | Result |
|---|---|
| String matching `/^#[0-9a-fA-F]{6}$/` | validated at `set:` time (regex check) but stored as the raw hex string in the bag. Readers coerce to the language's `Color` type on demand |
| `null` (only if nullable) | stored as the language's null representation |
| anything else | **error** |

All four languages perform validation at `set:` time, so an invalid
hex string is rejected immediately and does not poison the store.
Only the storage representation differs. Callers reading a color
field always go through a schema-aware accessor that returns the
language-native `Color` type regardless of storage.

Alpha / 8-digit hex is not currently supported. Add when needed.

### `enum`

| Input | Result |
|---|---|
| String matching one of `values` | the string itself, now validated |
| `null` (only if nullable) | `null` |
| anything else (including a value not in `values`) | **error** |

### `list`

| Input | Result |
|---|---|
| YAML list | each element coerced per `item_type` (if declared); error if any element fails; otherwise stored as a homogeneous list |
| YAML list, no `item_type` declared | stored as-is |
| `null` (only if nullable) | `null` |
| anything else | **error** |

### `object`

| Input | Result |
|---|---|
| YAML map | identity (stored as a raw map; not further validated at `set:` time) |
| `null` (only if nullable) | `null` |
| anything else | **error** |

---

## 6. Error handling

Every failure mode evaluates the `set:` effect to `unit` and logs to
the interpreter diagnostic stream. Writes that would fail are skipped;
writes that succeed in the same `set:` batch are still applied. The
action continues executing subsequent effects.

| Failure | Diagnostic level | Behavior |
|---|---|---|
| Unknown key (not in schema) | warning | Skip write |
| Key shadowing: bare key resolves to both `state` and `panel:<active>` | error | Skip write; ambiguity must be resolved by dotted key |
| Type mismatch (coercion fails) | error | Skip that key's write |
| Enum value not in `values` | error | Skip write |
| `null` on non-nullable field | error | Skip write |
| Field has `writable: false` | warning | Skip write |
| Schema malformed at load time | fatal | App fails to start |

Every diagnostic includes:
- Source location: action name, effect index, key name
- Expected: the schema entry's relevant fields
- Actual: the offending value (sanitized if sensitive)

**Rationale for "warning + skip" rather than crash**: the engine
should be robust to typos in third-party workspace YAML; crashing
the app on a stray typo is a worse user experience than logging and
continuing. Schema-level bugs (malformed schema) are fatal because
they indicate a developer error.

---

## 7. Cross-language contract

All four native-language implementations must agree on:

1. The canonical types in §2 and their coercion rules in §5.
2. The schema loader behavior in §3, including error cases.
3. The semantics in §4, including scope resolution and multi-key
   batching.
4. The error-handling matrix in §6.

Agreement is enforced by **shared test fixtures**. A new directory
`workspace/tests/set_effect/` contains YAML fixtures of the form:

```yaml
# workspace/tests/set_effect/basic_color.yaml
description: |
  set: with a valid hex color updates the field
initial_state:
  fill_color: "#ffffff"
effect:
  set:
    fill_color: "#ff0000"
expected_state:
  fill_color: "#ff0000"
expected_diagnostics: []
```

Each language's test harness loads the fixture, applies the effect to
the named initial state, and asserts equality with the expected state
and diagnostics.

Minimum fixture coverage for Phase 1:

- Basic coercion per type (6 fixtures, one per canonical type)
- Nullable accept / reject
- Enum in-range / out-of-range
- Non-writable field (warning + skip)
- Unknown key (warning + skip)
- Multi-key batch
- Panel-scoped key via dotted syntax
- Bare key resolving to panel when no global match
- Bare key shadowing error

Additional fixtures accrue as bugs surface.

---

## 8. Interaction with other effects

### `as:` binding on `set:`

Legal; produces a `unit`-typed binding. Example:

```yaml
- set: { fill_color: "#ff0000" }
  as: ignored       # type: unit
```

Lint rule: warn that the binding is useless; either drop `as:` or bind
a non-`unit` effect.

### `set:` inside `if:`

Standard nested evaluation. The conditional decides whether `set:`
runs:

```yaml
- if:
    condition: "state.fill_on_top"
    then:
      - set: { fill_color: "param.color" }
    else:
      - set: { stroke_color: "param.color" }
```

### `set:` inside `foreach`

The loop variable is in scope for expressions inside `set:` values:

```yaml
- foreach:
    source: "state.some_list"
    as: item
    do:
      - set:
          last_item: "$item"
```

Note that each iteration's `set:` is a separate batch — `last_item`
is overwritten on every iteration; only the last value survives.
For accumulating writes, use a list-push effect (not yet specified).

### `snapshot` before `set:`

`snapshot` captures the document's current state for undo. For
undoable `set:` batches, explicit `- snapshot` precedes the `set:`:

```yaml
effects:
  - snapshot
  - set: { fill_color: "param.color" }
```

Most `set:` effects on panel / tool state are NOT undoable by
convention (matches today's behavior in the hardcoded arms).

---

## 9. Migration mapping for Phase 1 actions

Each Category A action currently hardcoded in native code maps to a
YAML `effects:` block under the schema-driven design. Six actions:

### `set_active_color_none`

```yaml
set_active_color_none:
  effects:
    - if:
        condition: "state.fill_on_top"
        then:
          - set: { fill_color: null }
        else:
          - set: { stroke_color: null }
```

(Already present in `workspace/actions.yaml`; currently silently
no-ops on Rust due to Bug A3. Works correctly after the schema-driven
`set:` lands.)

### `set_active_color`

```yaml
set_active_color:
  params:
    color: { type: color }
  effects:
    - if:
        condition: "state.fill_on_top"
        then:
          - set: { fill_color: "param.color" }
        else:
          - set: { stroke_color: "param.color" }
    - list_push:
        target: "panel.recent_colors"
        value: "param.color"
        unique: true
        max_length: 10
```

Needs the `list_push:` effect (not fully speced here; presumably a
sibling Phase 1 primitive).

### `select_tool`

```yaml
select_tool:
  params:
    tool: { type: state_ref, ref: "active_tool" }
  effects:
    - set: { active_tool: "param.tool" }
```

Relies on the `active_tool` field being declared as `type: enum` in
`state.yaml` (it is) and coercion accepting the `param.tool` string.

### `swap_fill_stroke`

The existing YAML `- swap: [fill_color, stroke_color]` depends on a
`swap:` primitive that is separately specified. This doc covers only
`set:`. Bug A1 (the broken `swap:` implementation) is resolved in
parallel — see `PLAN.md`.

### `reset_fill_stroke`

Already in `workspace/actions.yaml` as a 24-key `set:` block. Works
correctly after schema-driven `set:` lands (all 24 keys are declared
in `state.yaml`).

### `exit_isolation_mode`

Needs the `pop:` primitive:

```yaml
exit_isolation_mode:
  effects:
    - pop:
        target: "panel.isolation_stack"
```

`pop:` is a sibling Phase 1 primitive; not specified here but shares
the schema-lookup mechanism (target must be a `writable: true` field
of type `list`).

---

## 10. Open questions (for Step 4 implementation)

1. **`list` mutation by `set:`**. `set: { field_list: [...] }` replaces
   the entire list. For element-wise append / remove, a separate
   effect (`list_push`, `list_remove`) is needed. Confirm `set:` on a
   list is always whole-list replacement.
2. **Multi-panel state.** When multiple panels are open and a bare
   key exists in two panels' schemas, resolution picks the active one.
   What if no panel is active? Error? Fall through to global only?
3. **Observer notifications.** After a `set:` batch, which UI
   subscribers are notified? Probably: any subscriber listening to
   any of the written keys, dispatched after the batch completes.
   Implementation detail rather than spec, but per-language
   subscribers should agree on timing.

These will be settled during Step 4 implementation. This doc is
updated as decisions land.
