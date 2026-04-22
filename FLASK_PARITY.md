# Flask Feature-Parity Design

Design analysis for extending `jas_flask` to support the full feature set
of the native apps (canvas, tools, document model, file I/O, undo, …) while
remaining a generic framework — i.e. jas-specific behavior lives entirely
in `workspace/*.yaml`.

This document captures the design decisions that need to be made before
code lands. It does not itself land any code; it exists to settle
foundational questions (boundary, client-server split, schema growth,
language extensions) so downstream work can proceed without replaying
them.

**Status: design-only**, produced 2026-04-22. Implementation is a
multi-month effort; this doc scopes it into tiered pieces.

---

## Table of contents

1. [What "generic" means — the L1/L2/L3 boundary](#1-l1l2l3-boundary)
2. [Client-server split: thick client](#2-client-server-split)
3. [Workspace schema growth](#3-workspace-schema-growth)
4. [Expression-language extensions](#4-expression-language-extensions)
5. [Undo / redo](#5-undo--redo)
6. [Event model](#6-event-model)
7. [Canvas rendering](#7-canvas-rendering)
8. [File I/O](#8-file-io)
9. [Cross-language testing](#9-cross-language-testing)
10. [Tool state machines in YAML](#10-tool-state-machines-in-yaml)
11. [Platform approximations](#11-platform-approximations)
12. [Schema validation](#12-schema-validation)
13. [Collaboration (deferred)](#13-collaboration-deferred)
14. [Consolidated YAML changes](#14-consolidated-yaml-changes)
15. [Staging and priority](#15-staging-and-priority)

---

## 1. L1/L2/L3 boundary

The rule "Flask is generic; jas-specific features live in YAML" is a
two-tier model; reality needs three tiers once Flask grows canvas / tools
/ document model. Decision:

- **L1 Framework** (Flask code, always): widget types, expression engine,
  state store, effect primitives, client-server protocol, event
  dispatcher.
- **L2 Domain** (Flask code, always): vector-illustration primitives —
  SVG element types (Rect, Circle, Path, Text, Layer, Group …), path
  commands, transforms, bounds, hit-testing, boolean ops, color-space
  conversions, file format I/O. Shared by any vector-illustration app
  built on the framework, not specific to any one product.
- **L3 App** (workspace YAML): panels, tools, menus, actions, brand,
  theme, keyboard shortcuts, import/export options, preferences — all
  things that differ between vector apps.

**Operational rule for reviewers**: anything computable from geometry
alone is L2 code. Anything about which button sits where is L3 YAML.
Flask code knows about `Rect` and `Path`; it does not know about
`layers_panel` or `color_panel`.

The genericity audits already in flight (per `project_flask_genericity_leaks.md`,
`project_panel_menu_yaml_migration.md`) enforce the L2/L3 boundary —
L3 leaks like `_PANEL_LABELS` were violations; L2 things like path
rendering are not.

---

## 2. Client-server split

Three architectural shapes were considered:

- **(a) Thick client** — JS hosts document + undo + tool state; server
  serves workspace YAML + assets; no round-trip per mouse event.
- **(b) Thin client** — every mousemove POSTs to server; server updates
  document and returns state. Ruled out by latency (16ms frame budget
  incompatible with HTTP round-trip).
- **(c) CRDT-replicated** — real-time multi-editor. Requires document-model
  rewrite; no user story forces it (see §13).

**Decision: (a) thick client.** Concretely:

- Document model lives in JS (fifth implementation, matching the existing
  Rust/Swift/OCaml/Python pattern)
- Mutations dispatched locally via the YAML interpreter running in JS
- Server is a static content server + YAML endpoint + optional save helper
- No WebSocket, no real-time sync, no CRDT — single-user interactive editing
- Future collaboration, if wanted, retrofits to CRDT as a document-model
  rewrite (deliberate cliff, not a gradient)

**Implication — expression interpreter runs in JS.** Today it's Python
(shared by Flask and jas native). For thick client, expressions need to
evaluate in the browser for interactive bindings. Plan: JS port; fifth
interpreter implementation. Estimated ~2-3k lines given the existing
Python interpreter is ~1.5k LOC.

---

## 3. Workspace schema growth

Per feature parity, the workspace YAML grows roughly 2× today's size.
New file categories:

| New directory / file | Purpose |
|---|---|
| `workspace/tools/*.yaml` (~15) | Tool spec: cursor, shortcut, handlers, overlay, local state |
| `workspace/canvas.yaml` | Canvas chrome: rulers, grid, guide snap rules |
| `workspace/preferences.yaml` | User-settable defaults |
| `workspace/viewport.yaml` | Zoom levels, fit-to-window |
| `workspace/selection.yaml` | Marquee, modifier-key semantics |
| `workspace/clipboard.yaml` | Cut/copy/paste wire formats |
| `workspace/drag_drop.yaml` | Global handlers for OS file drops |
| `workspace/import/*.yaml` | Format-specific import options |
| `workspace/export/formats.yaml` | Export format enumeration + handlers |
| `workspace/elements.yaml` | Default fill/stroke/font per element type |
| `workspace/features.yaml` | Runtime feature-capability declarations |

Added to existing files: `schema_version:` (required, per §12),
`platform:` filter and `hide_if:` on menu items.

**Volume estimate** (see §14 for details): +7,400 lines of new YAML +
schema authoring; roughly doubles the workspace footprint.

---

## 4. Expression-language extensions

The current expression language (parser, evaluator, AST cache across 5
implementations) handles: arithmetic, comparison, logic, `$name` scope
lookup, dotted/bracket path access, `{{…}}` string interpolation,
`foreach`, `if/then/else`, `<-` assignment.

### New expression primitives needed

Categorized; each primitive must ship identically in all 5 interpreters
with a cross-language test fixture:

**Math**: `min`, `max`, `abs`, `floor`, `ceil`, `round`, `sqrt`, `sin`,
`cos`, `tan`, `atan2`.

**String**: `uppercase`, `lowercase`, `substring`, `concat`, `trim`,
`starts_with`, `ends_with`, `length`.

**List**: `length`, `contains`, `first`, `last`, `index_of`, `slice`,
`map`, `filter`.

**Geometry (L2 primitives)**: `distance`, `point_in_rect`,
`rects_intersect`, `hit_test`, `nearest_anchor`, `path_bounds`,
`path_length`, `path_point_at_offset`, `transform_point`.

**Framework**: `last_added_path`, `viewport_to_document`,
`document_to_viewport`.

### New effect types — document mutations

The largest new surface. Today's effects are state-store writes. Feature
parity requires document mutations as first-class YAML effects:

`doc.snapshot`, `doc.add_element`, `doc.delete_at`, `doc.replace_at`,
`doc.set_attr`, `doc.set_fill`, `doc.set_stroke`, `doc.move`,
`doc.translate`, `doc.rotate`, `doc.scale`, `doc.group`, `doc.ungroup`,
`doc.start_path`, `doc.append_anchor`, `doc.set_tangent`, `doc.close_path`,
`doc.set_selection`, `doc.toggle_selection`, `doc.select_in_rect`,
`doc.clear_selection`, `doc.replace_last_added`.

Plus `file.*`, `clipboard.*`, `dialog.*`, `ui.*` effects for non-document
operations.

### New scope namespaces

| Scope | Status | Contains |
|---|---|---|
| `$state.*` | existing | Global state |
| `$panel.<id>.*` | existing | Per-panel state |
| `$tool.<id>.*` | **new** | Per-tool state |
| `$event.*` | **new** | Current event — x/y/modifiers/key in 4 coord spaces |
| `$platform.*` | **new** | `is_web`, `os`, modifier display strings |
| `$features.*` | **new** | Runtime capability (server_storage.available) |
| `$config.*` | **new** | Server/build-time configuration |

### Design principles for language extension

1. **Prefer primitives over syntax.** `min(a, b)` is a primitive (cheap
   per language); `if/then/else` is syntax (expensive per language).
2. **Pure expressions, effectful effects.** Keep expression evaluation
   side-effect-free; side effects only in the effect position.
3. **No user-defined functions beyond closures.** If the same logic
   repeats, refactor to a shared action + `call_action` effect.
4. **Every extension ships with a cross-language test fixture** in
   `workspace/tests/expressions/` (see §9).

---

## 5. Undo / redo

Pattern identical to native apps: stack of Document snapshots in JS,
`MAX_UNDO = 100`, `snapshot()` called explicitly by the tool before
mutation.

**Coalescing during drag**: the tool decides granularity. Rectangle tool
calls `doc.snapshot` **once on mousedown**, mutates the document in place
through the drag via `doc.replace_last_added`, no snapshot on mouseup.
One undo entry per user action, regardless of frame count.

**`doc.snapshot` is an explicit YAML effect.** Authors write it where
they want an undo step. No automatic snapshotting. No in-place-vs-snapshotting
effect split; one set of `doc.*` effects, with snapshot as a peer effect.

**Persistence across refresh**:
- V1: Tier A — lose on refresh. Matches native "process crashed" semantics.
- V2: Tier B — IndexedDB autosave every N seconds. Retrofit without
  schema changes.

**`saved_generation` pattern**: existing counter-based `is_modified`
shape (post the `saved_document` cleanup on `codebase-review-tier1`)
ports directly. JS Model holds `generation` and `saved_generation`
integers.

**Single-tab per document invariant**: two tabs of the same document =
two independent heaps = last save wins. Document loudly in
`REQUIREMENTS.md`. `BroadcastChannel` warning between tabs is a
zero-cost mitigation.

**File save**: File System Access API where available (silent overwrite,
Chromium); download fallback elsewhere (new file each time).
`beforeunload` prompt when `is_modified`.

---

## 6. Event model

Thick client + YAML tools mean events flow:

```
DOM event → JS dispatcher → routing → YAML handler → effect list
```

Routing priority:
1. Global shortcut (Cmd-S, Cmd-Z, V, P …) — matched against
   `workspace/shortcuts.yaml`
2. Focused panel's widget — if target is inside a panel body
3. Active tool's handler — if target is the canvas
4. Default (drop or browser default)

### Tool handler shape — named handlers per event type

```yaml
handlers:
  on_enter: [...]        # tool activated
  on_leave: [...]        # tool deactivated
  on_mousedown: [...]
  on_mousemove: [...]
  on_mouseup: [...]
  on_keydown: [...], on_keyup: [...]
  on_wheel: [...]
  on_dblclick: [...]
  on_contextmenu: [...]
```

Deferred: touch, pen pressure, gesture events.

### `$event` scope — unified shape

Populated by the dispatcher before invoking a handler:

```yaml
$event:
  type: "mousedown" | ...
  client_x, client_y: # raw browser coords
  x, y:                # document coords (after zoom+pan)
  target_x, target_y:  # local to element under event
  button: 0|1|2
  modifiers: { shift, ctrl, alt, meta: bool }
  key:                 # for keyboard events
  wheel_delta_x, wheel_delta_y:
```

Absent keys → `null`. A handler that checks `$event.key` while handling
a mousedown just gets null — no error.

### Coordinate spaces

Four: client (raw), viewport (inside canvas widget), document (world),
local (relative to element). Dispatcher computes all four once per event.

### Hit-testing — explicit primitive

Tools call `hit_test($event.x, $event.y, options)` themselves rather
than the dispatcher auto-populating `$event.hit_path`. Gives tools
filtered hit-testing (`only: "layer"`, `radius: 5`).

### Drag / 60fps budget

`on_mouseup` frames don't fire `doc.*` effects. Tool sets `$tool.*.*`
state; canvas overlay (§7) renders preview from state. Document mutates
only on mousedown (snapshot + initial) and mouseup (commit).

### Propagation / focus — handled by dispatcher, invisible to YAML

Framework calls `stopPropagation` after routing; YAML doesn't see DOM
bubbling. Typing in a text input suppresses tool events; dispatcher
checks focus.

### Clipboard, file drop, context menu

New event types / top-level handlers:
- `on_contextmenu` in tool YAML
- `workspace/drag_drop.yaml` — global `on_file_drop`
- Clipboard primitives (`clipboard.copy`, `.read`, `.write`) exposed as
  L2 effects

---

## 7. Canvas rendering

### Layered SVG DOM

```
<div class="canvas-viewport">   <!-- pan/zoom via CSS transform -->
  <svg class="doc-layer">         <!-- document elements -->
  <svg class="selection-layer">   <!-- handles, bboxes -->
  <svg class="overlay-layer">     <!-- tool previews -->
  <svg class="guides-layer">      <!-- rulers, snap lines -->
</div>
```

CSS `transform: translate() scale()` on the container handles pan/zoom
without touching inner content (GPU-accelerated).

### Per-layer rendering source

- **Document layer**: L2 `element_to_svg(element)` function, one SVG
  node per document element. Server can pre-render this layer for
  initial page load (SEO + first-paint).
- **Selection layer**: framework JS from `$state.selection`; fixed logic.
- **Overlay layer**: YAML interpreter evaluates tool's `overlay:` block
  each frame.
- **Guides layer**: framework JS from `$state.viewport` / preferences.

### Tech choice per layer

**All SVG DOM for V1.** Three primitives honestly compared:

- **SVG DOM**: declarative, accessibility for free, hit-testing native,
  prints correctly. ~1000-element ceiling under drag without
  optimization.
- **Canvas 2D**: 10k+ elements fast. Manual hit-test, manual text
  rendering, poor accessibility.
- **WebGL**: 100k+ elements. Huge complexity. V3+, not V1.

Recommendation: ship SVG DOM; swap document layer to Canvas 2D *if*
profiling shows it's the bottleneck. Keep selection + overlay on SVG
for correctness.

### Reactivity — plain JS + manual diffing

No framework dependency in V1. ~500 LOC diffing module. If pain emerges
later, Lit is the cleanest upgrade path (small, web-components, minimal
API surface).

### Text rendering — SVG native

SVG `<text>` gives kerning, font loading, OpenType features for free.
Canvas 2D loses all that. Major reason to stay SVG-only in V1.

### Server-side initial render

Server emits SVG snapshot of the document for first paint. Subsequent
interaction is JS-driven. Reuse existing SVG export. Fast first-paint,
SEO-friendly, graceful for no-JS viewers.

### Benchmarks before committing

1. 500-element doc first-paint: <200ms target
2. Drag 500 elements at 60fps sustained
3. Worst-case single-edit DOM rebuild: <16ms

---

## 8. File I/O

### Format compatibility matrix

| File created by | SVG | Binary |
|---|:---:|:---:|
| jas_dioxus (Rust) | ✅ | ✅ |
| JasSwift | ✅ | ✅ |
| jas_ocaml | ✅ | ✅ |
| jas (Python) | ✅ | ✅ |
| jas_flask (offline/PWA) | ✅ | ❌ |
| jas_flask (online) | ✅ | ✅ via server roundtrip |

### Binary format strategy

**Server roundtrip**, not JS port. Flask server exposes:
- `POST /api/decode_binary` bytes → JSON
- `POST /api/encode_binary` JSON → bytes

Offline-mode limitation documented. JS port deferred until offline
binary is a real requirement.

### Default save format

- **Flask: SVG by default** (web UX expectation: save = openable anywhere)
- **Native: binary by default** (existing behavior)

One deliberate native-vs-Flask divergence.

### Save semantics — layered

1. If File System Access API handle exists → silently overwrite
2. Else if FSAA available → prompt, remember handle
3. Else → download new file each time

Framework JS handles; YAML doesn't need to know.

### Autosave — IndexedDB / OPFS

Format: internal JSON (not SVG, not binary). Every N seconds per
`preferences.yaml:autosave.interval_seconds`. On load, prompt restore.

### Import/export in YAML

```yaml
# workspace/import/svg.yaml
preserve_ids: true
default_unit: px
unit_mapping: { mm: 3.7795, in: 96, pt: 1.3333 }
viewport_mode: crop_to_viewbox

# workspace/export/formats.yaml
formats:
  - id: svg_plain
    name: "SVG (plain)"
    extension: svg
    handler: svg_export
    options: { embed_images: true, inline_styles: false }
```

Flask's Export menu auto-generated from the list. New formats = new
YAML. Handler names map to L2 primitives.

### PDF export

Deferred to V2. Server-side `reportlab` (online-only) or client-side
`pdf-lib` (large dep).

### Drag-drop

Global `workspace/drag_drop.yaml` handler. Image files → insert as
image element. SVG files → open or insert (dialog).

### Asset embedding

L2 primitive `embed_external_refs(svg, base_path)` converts `href=…`
to `data:` URIs for portable SVG export.

---

## 9. Cross-language testing

### Current state

`workspace/tests/` has: `phase3/` (9 fixtures), `set_effect/` (17
fixtures), `expressions.yaml`, `gradient_primitives.yaml`. Each native
app's `cross_language_test.*` loads these and verifies agreement.

### New fixture categories

```
workspace/tests/
  doc_effect/*.yaml         # NEW — one per doc.* primitive
  tools/*.yaml              # NEW — tool-interaction sequences
  render_snapshots/*.yaml   # NEW — canonical render tree per state
  undo/*.yaml               # NEW — undo/redo mechanics
  interop/*.yaml            # NEW — SVG/binary round-trip
  expressions/*.yaml        # NEW — expanded per-primitive coverage
```

### Fixture shapes

**Tool interaction**:
```yaml
description: "Rectangle tool drag creates a rect"
active_tool: rect
document_before: { layers: [{ children: [] }] }
events:
  - { type: mousedown, x: 10, y: 10 }
  - { type: mousemove, x: 60, y: 35 }
  - { type: mouseup, x: 110, y: 60 }
document_after:
  layers: [{ children: [{ type: rect, x: 10, y: 10, width: 100, height: 50 }] }]
undo_stack_size_after: 1
```

**Render snapshot**:
```yaml
state: { panel.color.mode: "rgb", selection: [] }
panel: color_panel_content
expected_tree:
  type: panel
  children: [...]
```

### Canonicalization rules (CROSS_LANGUAGE_TESTING.md)

- Floats: 6 decimal places, canonical printing
- Object keys sorted alphabetically; arrays preserve order
- Default-valued fields omitted
- No timestamps, PIDs, environment
- JSON primitives (`true`, not `True`)

### Update workflow — golden-master

1. Developer changes code; tests with new output marked `.expected.new`
2. Review diffs; promote to `.expected`
3. Propagate to all 5 apps; CI enforces agreement

### CI partitioning

Fixture subset per-PR (fast); nightly full-suite run (thorough).

---

## 10. Tool state machines in YAML

### State machines via state variable + guards

No explicit state-machine DSL. Tools use an existing-primitive pattern:

```yaml
state:
  # States: idle | placing_anchor | drag_tangent | awaiting_next_click
  mode: { default: "idle" }
  # ... other tool state

handlers:
  on_mousedown:
    - if: $tool.pen.mode == "idle"
      then:
        - doc.snapshot: {}
        - doc.start_path: ...
        - set: $tool.pen.mode, value: "placing_anchor"
    - if: $tool.pen.mode == "awaiting_next_click"
      then: ...
```

### Why not a state-machine DSL

Alternative shape A (explicit `states:`, `transition_to:`) is more
readable but costs 5-interpreter work per extension. Shape B reuses
existing `if/then/else`, `set:`, and action primitives from §4 — zero
new language / schema work.

If shape-B pain emerges across many tools, shape A can be a compiler
layer on top of shape B (one-time transformer, no 5-language cost).

### Conventions

- `# States: …` comment at top of every tool YAML documenting valid modes
- Dev-mode state-transition logger extending the expr-eval logging
  shipped on `codebase-review-tier1`
- CI static analyzer extracts implicit state machine → emits Graphviz
  diagram per PR
- Shared exit logic factored to actions (`workspace/actions.yaml`)

### Imperative escape hatch

Tools with genuinely imperative physics (freehand pencil) can declare
`handler_impl: native` and point to a named L2 function. Used sparingly;
flagged in the YAML so reviewers see it.

---

## 11. Platform approximations

### Stance: approximate, don't replicate

Flask is a reference implementation; native apps remain primary for
platform fidelity. Users who care about menu bars, file dialogs, etc.
use the native app. Flask handles: quick edits, prototyping,
collaboration (future), embedded use.

### Per-feature approximation

| Feature | Flask approximation | Acceptable? |
|---|---|---|
| Menu bar | HTML in-page menu | Yes |
| Context menu | CSS-styled HTML | Yes |
| File Open dialog | `<input type=file>` | Yes (no recents) |
| File Save dialog | FSAA / download | Yes (FSAA where available) |
| Clipboard (rich) | SVG + text fallback | Lossy |
| Drag-from-OS | Works | Yes |
| Drag-to-OS | Not supported | No workaround |
| Cursor shapes | CSS `cursor:` | Yes |
| Platform chrome | Browser owns | Yes |
| File associations | PWA only | Limited |
| OS notifications | Web Notifications | V2, with permission |
| Print | `window.print()` | Yes |
| IME | Overlay-input pattern | Yes |

### Platform filter in YAML

```yaml
# menubar.yaml entries with native-only items
- label: "Open Recent"
  platform: [native]    # Flask renderer skips
  submenu: ...
- label: "Reveal in Finder"
  platform: [macos]
  action: file.reveal
```

Each renderer filters by `$platform.os` / `is_web`. Same YAML, two
renderers.

### `$platform.*` scope

```yaml
$platform:
  is_web: true | false
  os: "macos" | "linux" | "windows" | "web"
  modifier_display:
    primary: "⌘" | "Ctrl"
    alt: "⌥" | "Alt"
```

### Accessibility

SVG DOM + ARIA gives screen-reader support nearly for free. Required:
ARIA labels on interactive widgets, semantic HTML, logical tab order.
CI lints via `@axe-core` or equivalent.

### IME for canvas text

Overlay an invisible `<input>` on the text element during editing.
Browser handles composition events; framework renders the result back
to SVG. Standard web-vector-editor technique.

---

## 12. Schema validation

### Compile-time validation — existing infrastructure

`workspace/workspace.json` is already committed and regenerated via
`python -m workspace_interpreter.compile`. This is the natural home for
validation — runs once, before `workspace.json` ships. All 5
interpreters load compiled JSON, trusting it.

### Three validation layers

**Layer 1 — structural shape** via JSON Schema. One schema file per
YAML type. Gives editor autocomplete + live error highlighting for free
(via YAML Language Server).

**Layer 2 — cross-reference checks** via Python validator. Every
`action:` reference resolves; every `$state.xxx` read has a declaration;
no duplicate IDs; enum values match declared values.

**Layer 3 — expression parsing**. Every expression string in the YAML
run through `parse()` at compile time; failures reported with file:line
context.

### Severity

- **Error** → compilation fails; `workspace.json` not emitted
- **Warning** → compiles but logged
- **Info** → suggestions in verbose mode

CI fails on Error.

### Dev-mode integration

Flask dev server recompiles on YAML change; validation errors rendered
inline in browser:

```
⚠ workspace/panels/color.yaml:42
  Expression parse failed: $selection.fil.r
  Did you mean "fill"?
```

Production skips.

### Schema evolution

`schema_version:` field at top of `workspace/app.yaml`. Compiler rejects
unknown versions. Separate `--migrate` subcommand for upgrades; no
runtime migration in interpreters.

### Complementary to expr-eval logging

Dev-mode runtime expression logging (shipped on `codebase-review-tier1`)
catches dynamic issues. Compile-time validation catches structural and
static reference errors. Both layers; neither alone suffices.

---

## 13. Collaboration (deferred)

### Tier 0 commitment for V1

**Single user, single tab, offline-first, no server sync.** Matches
native apps' semantics. No WebSocket, no CRDT, no operation transforms.

### What V1 architecture must not foreclose

Thick-client (§2) + JS document + local undo is compatible with:
- **Tier 1** — file sharing via server-side file storage (no real-time)
- **Tier 2** — concurrent read, single writer (read-only live view)

And incompatible with:
- **Tier 3** — full real-time multi-editor (CRDT rewrite required)

The architectural hedge: if Tier 3 is wanted, it's a document-model
rewrite. Accept this; don't slow V1 to preserve Tier 3 optionality.

### What V1 includes regardless

- IndexedDB autosave (§5 / §8)
- Optional server-side file hosting via small REST surface
  (`POST /api/files`, `GET /api/files/<id>`) — opt-in via config
- `BroadcastChannel` tab-conflict warning
- `beforeunload` prompt when modified

### Auth / permissions

- V1: session cookies if server deployed; anonymous otherwise
- V2: owner/collaborator/viewer tiers with share URLs
- V3: SSO, org-level — out of scope indefinitely

### Feature-capability filter

```yaml
# workspace/features.yaml
server_storage: { available: "{{ $config.server.storage_enabled }}" }
```

Menu items hide via `hide_if:` when backend features absent. Same
pattern as `platform:` filter from §11.

---

## 14. Consolidated YAML changes

### New top-level files

~15 `workspace/tools/*.yaml`, plus: `canvas.yaml`, `preferences.yaml`,
`viewport.yaml`, `selection.yaml`, `clipboard.yaml`, `drag_drop.yaml`,
`import/svg.yaml`, `export/formats.yaml`, `elements.yaml`, `features.yaml`.

### New fields added to existing files

- `schema_version:` at top of `workspace/app.yaml` (required)
- `platform:` filter on menu entries
- `hide_if:` filter on menu entries
- `state:` blocks extended with optional `enum:` metadata

### New tool YAML shape

```yaml
id: <tool_id>
cursor: <cursor_name>
menu_label: "..."
shortcut: "P"

state:
  mode: { default: "idle" }
  # ... tool-local state

handlers:
  on_enter / on_leave / on_mousedown / on_mousemove / on_mouseup /
  on_keydown / on_keyup / on_wheel / on_dblclick / on_contextmenu

overlay:
  if: <expr>
  render: <render_spec>
```

### New expression primitives

Math, string, list, geometry (L2), framework. See §4.

### New effect types

~20 `doc.*` primitives, plus `file.*`, `clipboard.*`, `dialog.*`,
`ui.*`. See §4.

### New scope namespaces

`$tool.*`, `$event.*`, `$platform.*`, `$features.*`, `$config.*`.
See §4.

### New test fixture categories

`doc_effect/`, `tools/`, `render_snapshots/`, `undo/`, `interop/`. See §9.

### Schema infrastructure

`schema/*.json` (JSON Schema per YAML type) — authored once, consumed
by YAML Language Server. ~15-20 schemas.

### Scale summary

| Category | Lines |
|---|---:|
| Existing workspace authoring | ~5,000 |
| New tool YAMLs (~15 × ~100) | ~1,500 |
| New top-level files | ~800 |
| Added fields (platform, hide_if, schema_version, enum) | ~100 |
| New JSON Schema definitions | ~3,000 |
| New test fixtures | ~2,000 |
| **Total delta** | **~7,400** |

Roughly doubles the workspace footprint. About half is schema + tests
(one-time authoring); half is feature definitions that unlock Flask
parity.

---

## 15. Staging and priority

### Decision blocks (must settle before code)

1. §1 L1/L2/L3 boundary — decided: three concentric tiers
2. §2 Client-server split — decided: thick client
3. §3 Schema growth — enumerate `workspace/tools/selection.yaml`
   as the first concrete prototype

### Infrastructure (can start early, unblocks everything)

4. §12 Schema validation — JSON Schema per file type, compiler
   integration, `schema_version:` field
5. §9 Test fixture layout — canonicalization rules doc, fixture
   directory structure

### Runtime substrate (requires decisions + infrastructure)

6. §4 Expression-language extensions (primitives, effect types, scopes)
7. §6 Event model and dispatcher
8. §5 Undo/redo with `doc.snapshot` effect
9. §7 Canvas rendering (SVG DOM, four layers)
10. §10 Tool state machines (selection tool first, as validation)
11. §8 File I/O (SVG for V1, binary via server roundtrip)

### Feature / polish (runs alongside runtime)

12. §11 Platform approximations (as features land)
13. §13 Collaboration — V1 stays Tier 0

### Suggested first-ship scope

1. Schema infrastructure + validator (§12) — unlocks editor tooling
2. `workspace/elements.yaml` + `workspace/import/svg.yaml` — bootstrap
   document model
3. `workspace/tools/selection.yaml` — proves the tool schema shape
4. JS expression interpreter (fifth implementation) + `$tool.*`
   / `$event.*` scopes (§4, §6)
5. Canvas SVG DOM layers (§7)
6. `doc.*` effect primitives (§4)
7. Remaining tools in order of priority

Each numbered step is 1-3 weeks of work. Full V1 is months, not
weeks. Ship incrementally; each step is usable before the next lands.

---

## Benefits

- **One renderer, five platforms**: Flask becomes the canonical
  implementation; native apps are platform shells.
- **YAML as product spec**: the workspace directory fully describes the
  app. Branded variants become trivial.
- **Automatic test coverage**: cross-language snapshot tests enforce
  parity across 5 implementations.
- **Onboarding**: new contributors learn the framework once, not four
  times.

## Downsides

- **Huge up-front investment**: months, not weeks.
- **Parallel maintenance worsens short-term** until Flask catches up —
  five drifting implementations instead of four converging ones.
- **Native UI polish harder to preserve** — the generic renderer loses
  platform affordances (see §11).
- **Schema + interpreter complexity explodes**; every feature touches
  all 5 interpreters.
- **JS document model** adds a fifth native-equivalent implementation
  to maintain.

## Open questions for before V1

- Is collaboration (§13 Tier 1+) a stated goal? If yes, file-sharing
  shape; if no, stay Tier 0.
- PDF export: V1 or V2?
- Performance target — what document size / FPS is "acceptable"?
- Deployment story: offline PWA only? Self-hosted with backend? SaaS?
- Authentication model for server deployments.
