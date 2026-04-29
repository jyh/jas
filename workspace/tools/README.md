# workspace/tools/

Tool specifications for the vector illustration app. Each `*.yaml` in
this directory defines one tool: its cursor, shortcut, event handlers,
local state, and render overlay.

Tool YAMLs validate against `schema/tool.schema.json`. A canonical
complete example is `selection.yaml`.

## Status

The tool-dispatcher runtime is implemented in all four native apps
(jas_dioxus, JasSwift, jas_ocaml, jas). Each app has its own
`tool_files` baseline of native tools (Type / TypeOnPath per
NATIVE_BOUNDARY.md §6); every other tool here is YAML-driven.

The Flask app does not yet implement a tool dispatcher. Tool YAMLs
remain design-only on the Flask side; see `FLASK_PARITY.md` §15.

**Unwired YAMLs.** A few tool specs in this directory are authored
but not yet bound into any app's toolbar registry:

- `ellipse.yaml` — no app currently lists Ellipse as a tool kind
  (the existing oval-drawing happens through `polygon` / native
  `Element.Ellipse` paths). Wiring requires adding the tool kind
  in each app and a toolbar slot.

Adding a new tool spec here does NOT automatically register the
tool — each native app must add the tool kind to its enum/registry
and place it in `workspace/toolbar.yaml`.

## Authoring a tool

1. Create `workspace/tools/<tool_name>.yaml`.
2. Declare `id: <tool_name>` matching the filename stem.
3. Declare any tool-local state slots under `state:`. State is
   namespaced `$tool.<tool_name>.*` in expressions.
4. Write event handlers under `handlers:`. Valid keys per the schema:
   `on_enter`, `on_leave`, `on_mousedown`, `on_mousemove`, `on_mouseup`,
   `on_keydown`, `on_keyup`, `on_wheel`, `on_dblclick`, `on_contextmenu`.
5. Optionally declare an `overlay:` — render spec drawn into the canvas
   overlay layer each frame the `if:` guard is truthy.

## State machine convention

Tools commonly have multiple modes (e.g. idle / drawing / dragging).
Per `FLASK_PARITY.md` §10, encode the state machine as a `mode:` state
slot plus guard conditions in each handler:

```yaml
state:
  # States: idle | drawing | complete
  mode:
    default: "idle"
    enum: [idle, drawing, complete]

handlers:
  on_mousedown:
    - if: "$tool.pen.mode == 'idle'"
      then:
        - set: $tool.pen.mode
          value: "drawing"
        - ...
```

The `# States:` comment documents the valid modes. The `enum:` field
on the state slot is validated at compile time.

## Primitives available in tool expressions

See `FLASK_PARITY.md` §4 for the full list. Tool handlers commonly use:

- `hit_test($event.x, $event.y)` — returns element path or null
- `distance(x1, y1, x2, y2)` — Euclidean distance
- `min`, `max`, `abs`, `floor`, `round` — math basics

## Effects available in tool handlers

Document mutations:
- `doc.snapshot` — push undo entry
- `doc.add_element`, `doc.delete_at`, `doc.replace_at`
- `doc.set_attr`, `doc.set_fill`, `doc.set_stroke`
- `doc.translate`, `doc.rotate`, `doc.scale`
- `doc.set_selection`, `doc.toggle_selection`, `doc.clear_selection`,
  `doc.select_in_rect`

State writes: `set:` effect targets any `$state.*`, `$panel.*.*`, or
`$tool.*.*` path.

See `FLASK_PARITY.md` §4 for the complete catalog.

## `$event` scope

Populated by the dispatcher before each handler runs:

| Field | Notes |
|---|---|
| `type` | `"mousedown"`, `"mousemove"`, etc. |
| `client_x`, `client_y` | Raw browser coords |
| `x`, `y` | Document coords (after zoom + pan) |
| `target_x`, `target_y` | Local to element under the event |
| `button` | `0` / `1` / `2` for left / middle / right |
| `modifiers` | `.shift`, `.ctrl`, `.alt`, `.meta` booleans |
| `key` | For keyboard events |
| `wheel_delta_x`, `wheel_delta_y` | For wheel events |

Absent fields are `null`; a handler reading `$event.key` during a
mousemove just gets null, not an error.
