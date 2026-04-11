# WORKSPACE.yaml Schema

A generic, app-agnostic schema for declaratively describing the complete UI of a
desktop-style application: layout, visual presentation, behavior, menus, dialogs,
keyboard shortcuts, and reactive state. Designed to be rendered by a generic web
app using Bootstrap for layout and JavaScript for interaction.

## Design Principles

- **Bootstrap-native layout** — `container`, `row`, `col`, and `grid` at every
  level, mapping directly to Bootstrap's grid system.
- **Separation of concerns** — each element has distinct `style` (visual),
  `behavior` (events/actions), and `bind` (reactive state) sections.
- **Action indirection** — behaviors reference named actions from a top-level
  `actions` catalog; no inline logic.
- **State-driven** — a `state` section declares reactive variables; elements
  bind to them via `bind` and `{{interpolation}}`.
- **Two description tiers** — `summary` (short label for wireframe display) and
  `description` (full English for inspection popups).
- **Extensible** — unknown element types are treated as opaque widgets, rendered
  as labeled rectangles in wireframe mode.

---

## Top-Level Structure

```yaml
version: <integer>

app:       <app_spec>
theme:     <theme_spec>
icons:     <map: name → icon_def>
state:     <map: name → state_var>
actions:   <map: name → action_def>
shortcuts: <list of shortcut>
menubar:   <list of menu>
layout:    <element>
dialogs:   <map: name → dialog>
```

All top-level keys are required except `icons` and `dialogs` (optional).

---

## Primitive Types

| Type | Format |
|---|---|
| `color_value` | `"#rrggbb"`, `"#rrggbbaa"`, `"rgba(r,g,b,a)"`, or `"transparent"` |
| `font_spec` | `{ family: <string>, size: <number>, weight?: <string> }` |
| `interpolated` | String with `{{theme.*}}`, `{{state.*}}`, or `{{param.*}}` references |

---

## `app` — Application Metadata

```yaml
app:
  name: <string>
  description: <string>
  window:
    width: <number>
    height: <number>
    min_width: <number>          # optional
    min_height: <number>         # optional
```

---

## `theme` — Visual Theme

Defines named tokens referenced by elements via `{{theme.*}}` interpolation.

```yaml
theme:
  colors: <map: name → color_value>
  fonts:  <map: name → font_spec>
  sizes:  <map: name → number>
```

Example:

```yaml
theme:
  colors:
    window_bg:  "#2e2e2e"
    pane_bg:    "#3c3c3c"
    border:     "#555555"
    text:       "#cccccc"
  fonts:
    default:    { family: "sans-serif", size: 12 }
    title:      { family: "sans-serif", size: 11, weight: "bold" }
  sizes:
    title_bar_height: 20
    border_handle:    6
```

---

## `icons` — Icon Definitions

Defines named icons as inline SVG. Elements reference icons by name via the
`icon` property. The renderer outputs the SVG inline, allowing CSS to control
color and size.

```yaml
icons:
  <name>:
    viewbox: <string>            # SVG viewBox, e.g. "0 0 256 256"
    svg: <string>                # SVG content (everything inside the <svg> tag)
```

The `svg` field contains the raw SVG elements (`<path>`, `<rect>`, `<line>`,
`<polygon>`, etc.) as a string. The renderer wraps them in an `<svg>` tag with
the specified `viewbox` and sizes the icon to fit the element.

Icon colors in the SVG should use `currentColor` or be defined relative to the
theme so the renderer can adapt them. Alternatively, icons may use fixed colors
matching the app's dark theme (e.g. `#cccccc` for strokes on dark backgrounds).

Example:

```yaml
icons:
  line:
    viewbox: "0 0 256 256"
    svg: '<line x1="30.79" y1="232.04" x2="231.78" y2="31.05"
           fill="none" stroke="currentColor" stroke-width="8"/>'

  rect:
    viewbox: "0 0 256 256"
    svg: '<rect x="23.33" y="58.26" width="212.06" height="139.47"
           fill="gray" stroke="currentColor" stroke-width="8"/>'
```

---

## `state` — Reactive State Variables

Declares named variables that drive the UI. Elements bind to these; the renderer
keeps the DOM in sync when values change.

```yaml
state:
  <name>:
    type: enum | color | number | bool | string
    values: [...]                # required when type=enum
    default: <value>
    nullable: <bool>             # optional, default false
    description: <string>
```

Example:

```yaml
state:
  active_tool:
    type: enum
    values: [selection, pen, rect, line]
    default: selection
    description: "Currently selected drawing tool"

  fill_color:
    type: color
    default: "#ffffff"
    nullable: true
    description: "Active fill color (null = no fill)"
```

---

## `actions` — Action Catalog

Every triggerable operation is defined here by name. Behaviors, menus, and
shortcuts reference actions by id.

```yaml
actions:
  <name>:
    description: <string>
    category: <string>           # optional grouping tag
    tier: <integer>              # optional; 1=layout, 2=interaction, 3=domain
    params:                      # optional
      <param_name>:
        type: enum | string | number | bool | state_ref
        values: [...]            # when type=enum
        ref: <string>            # when type=state_ref
    enabled_when: <interpolated> # optional boolean expression
```

The `tier` field indicates implementation complexity for the renderer:

| Tier | Scope | Example |
|---|---|---|
| 1 | Layout only — pure HTML/CSS | Show/hide a pane |
| 2 | Interaction — requires JS event handling | Tool selection, drag-and-drop |
| 3 | Domain logic — out of scope for generic renderer | SVG rendering, undo/redo |

Example:

```yaml
actions:
  save:
    description: "Save active document; if untitled, fall through to save_as"
    category: file

  select_tool:
    description: "Switch the active tool"
    category: tool
    params:
      tool: { type: state_ref, ref: "active_tool" }

  revert:
    description: "Reload document from disk"
    category: file
    enabled_when: "model.is_modified and model.has_filename"
```

---

## `shortcuts` — Keyboard Bindings

```yaml
shortcuts:
  - key: <string>                # e.g. "Ctrl+N", "Shift+X", "V"
    action: <action_id>
    params: { ... }              # optional, matches action's params
```

Example:

```yaml
shortcuts:
  - key: "Ctrl+N"    action: new_document
  - key: "V"         action: select_tool    params: { tool: selection }
  - key: "Shift+X"   action: swap_fill_stroke
```

---

## `menubar` — Menu Structure

### Menu

```yaml
menubar:
  - id: <string>
    label: <string>              # & marks mnemonic character
    items: <list of menu_item>
```

### Menu Item — one of three forms

**Action item:**

```yaml
- id: <string>
  label: <string>
  action: <action_id>
  params: { ... }                # optional
  shortcut: <string>             # optional display string
  enabled_when: <interpolated>   # optional
```

**Submenu:**

```yaml
- id: <string>
  label: <string>
  type: submenu
  dynamic: <bool>                # optional; items populated at runtime
  description: <string>          # optional
  items: <list of menu_item>
```

**Separator:**

```yaml
- separator
```

Example:

```yaml
menubar:
  - id: file_menu
    label: "&File"
    items:
      - { id: new,     label: "&New",        action: new_document,  shortcut: "Ctrl+N" }
      - { id: open,    label: "&Open...",     action: open_file,     shortcut: "Ctrl+O" }
      - separator
      - { id: quit,    label: "&Quit",        action: quit,          shortcut: "Ctrl+Q" }
```

---

## `element` — Core Layout Node

Every node in the layout tree is an element. The `type` field selects the kind.

```yaml
id: <string>                     # unique identifier
type: <element_type>             # see Element Types table
summary: <string>                # short label (wireframe display)
description: <string>            # full English (inspection popup)
style: <style>                   # optional visual properties
behavior: <list of behavior>     # optional event handlers
bind: <map: prop → interpolated> # optional state bindings
children: <list of element>      # optional nested elements
tier: <integer>                  # optional implementation tier
```

All fields except `type` are optional, though `id` and `summary` are
recommended for every element.

### Element Types

| Type | Purpose | Extra Properties |
|---|---|---|
| `pane_system` | Absolute-positioned draggable pane container | — |
| `pane` | Draggable, resizable pane | `default_position`, `title_bar`, `content`, `min_width`, `max_width`, `min_height` |
| `container` | Bootstrap container | `layout`: `column` or `row` |
| `row` | Bootstrap row | — |
| `col` | Bootstrap column | `col`: 1–12 or `auto` |
| `grid` | Fixed grid | `cols`, `rows` (optional), `gap` |
| `tabs` | Tabbed container; one child visible at a time | `active`: index or bind expression |
| `panel` | Named content region within tabs | `panel_kind`, `menu` |
| `button` | Clickable button | `label`, `action`, `params`, `variant`, `icon` |
| `icon_button` | Small icon-only button | `icon`, `action`, `params` |
| `toggle` | Toggle / checkbox | `label`, `bind` |
| `radio_group` | Mutually exclusive options | `options`: `[{id, label}]`, `bind` |
| `text` | Static or interpolated text | `content`: interpolated string |
| `text_input` | Text entry field | `placeholder`, `bind` |
| `number_input` | Numeric entry | `min`, `max`, `step`, `bind` |
| `color_swatch` | Color display square | `bind.color`, `hollow`: bool |
| `slider` | Range slider | `min`, `max`, `step`, `bind` |
| `select` | Dropdown | `options`, `bind` |
| `canvas` | Freeform rendering surface | — |
| `placeholder` | Not-yet-implemented region | — |
| `separator` | Visual divider line | `orientation`: `horizontal` or `vertical` |
| `spacer` | Flexible empty space | `size`: number (optional, else flex) |
| `image` | Static image | `src` |

Any string not in this table is treated as an **opaque custom widget** —
rendered as a labeled rectangle in wireframe mode.

---

## `pane` — Extra Properties

```yaml
default_position:
  x: <number>
  y: <number>
  width: <number>
  height: <number>

min_width: <number>              # optional
max_width: <number>              # optional
min_height: <number>             # optional

title_bar:
  label: <string>
  draggable: <bool>
  closeable: <bool>
  buttons: <list of icon_button> # optional extra title bar buttons

content: <element>               # the pane's body (single element tree)
```

---

## `grid` — Child Positioning

Children of a `grid` element specify their cell placement:

```yaml
grid:
  row: <integer>
  col: <integer>
  row_span: <integer>            # optional, default 1
  col_span: <integer>            # optional, default 1
```

---

## `tabs` — Tabbed Container

```yaml
type: tabs
active: <integer | interpolated> # index of the active tab, or bind expression
children:
  - <element>                    # each child is one tab's content
```

Each child should have a `summary` (used as the tab label).

---

## `panel` — Dock Panel

```yaml
type: panel
panel_kind: <string>             # unique panel identifier
menu: <list of panel_menu_item>
content: <element>
```

### `panel_menu_item`

```yaml
- label: <string>
  action: <action_id>            # or inline command string
  type: action | toggle | radio  # default: action
  group: <string>                # for radio items
  shortcut: <string>             # optional
```

---

## `style` — Visual Properties

All fields are optional. Any string-valued property may use `{{interpolation}}`.

```yaml
style:
  # Colors
  background: <color_value>
  color: <color_value>               # text / foreground color
  icon_color: <color_value>
  checked_bg: <color_value>          # background when in checked/active state
  opacity: <number>                  # 0.0–1.0

  # Borders
  border: <string>                   # CSS shorthand, e.g. "1px solid #555"
  border_radius: <number>

  # Spacing
  padding: <number | string>         # uniform or "top right bottom left"
  margin: <number | string>
  gap: <number>                      # spacing between children

  # Sizing
  width: <number | string>           # fixed or "auto"
  height: <number | string>
  min_width: <number>
  min_height: <number>
  max_width: <number>
  max_height: <number>
  size: <number>                     # shorthand for equal width + height
  flex: <number>                     # flex grow factor

  # Layout
  alignment: start | center | end | stretch
  justify: start | center | end | between | around
  overflow: visible | hidden | scroll | auto

  # Positioning (within absolute-positioned parents)
  position: { x: <number>, y: <number> }
  z_index: <number>
```

---

## `behavior` — Event → Action Binding

```yaml
behavior:
  - event: <event_type>
    action: <action_id>              # optional (omit for description-only)
    params: { ... }                  # optional, passed to action
    condition: <interpolated>        # optional boolean guard
    delay_ms: <number>               # optional (e.g. for long_press)
    menu: <string>                   # optional menu id to open
    dialog: <string>                 # optional dialog id to open
    description: <string>            # English explanation of behavior
```

### Event Types

| Event | Meaning |
|---|---|
| `click` | Mouse click / tap |
| `double_click` | Double click |
| `long_press` | Press and hold (use `delay_ms`) |
| `right_click` | Context menu click |
| `drag_start` | Begin drag |
| `drag` | During drag |
| `drop` | Drop target receives |
| `hover_enter` | Mouse enters element |
| `hover_leave` | Mouse leaves element |
| `key` | Keyboard event (use `params.key`) |
| `change` | Value changed (inputs, toggles) |
| `tab_click` | Tab selected (within `tabs`) |
| `tab_close` | Tab close button clicked |
| `resize` | Element resized |
| `collapse_toggle` | Collapse / expand toggled |

The event list is extensible — unknown event names are preserved in the spec
and displayed in wireframe inspection mode.

---

## `alternates` — Long-Press Menu

Any element may define an `alternates` block for a long-press popup:

```yaml
alternates:
  menu_id: <string>
  items:
    - id: <string>
      label: <string>
      icon: <string>               # optional
      description: <string>        # optional
```

---

## `bind` — Reactive State Binding

Connects element properties to `state` variables. The renderer keeps the DOM
in sync when bound values change.

```yaml
bind:
  <property>: <interpolated>
```

Example:

```yaml
bind:
  color: "{{state.fill_color}}"
  visible: "{{state.dock_collapsed}}"
```

---

## `dialogs` — Modal Dialogs

Dialogs are defined at the top level and referenced by id from `behavior`
entries. They are not part of the spatial layout tree until triggered.

```yaml
dialogs:
  <name>:
    summary: <string>
    description: <string>
    modal: <bool>
    params:                          # optional input parameters
      <name>:
        type: enum | string | number | bool
        values: [...]                # when type=enum
    content: <element>               # layout tree for dialog body
```

Example:

```yaml
dialogs:
  confirm_save:
    summary: "Save Changes"
    description: "Shown when closing a tab with unsaved changes."
    modal: true
    content:
      type: container
      layout: column
      children:
        - { type: text, content: "Save changes to \"{{param.filename}}\"?" }
        - type: row
          style: { justify: end, gap: 8, padding: "12 0 0 0" }
          children:
            - { type: button, label: "Cancel",  action: dismiss_dialog }
            - { type: button, label: "Discard", action: close_without_saving }
            - { type: button, label: "Save",    action: save_and_close, variant: primary }
```

---

## Interpolation

`{{...}}` expressions may appear in any string-valued property.

| Pattern | Resolves To |
|---|---|
| `{{theme.colors.<name>}}` | Color value from theme |
| `{{theme.fonts.<name>}}` | Font spec from theme |
| `{{theme.sizes.<name>}}` | Numeric size from theme |
| `{{state.<name>}}` | Current value of a state variable |
| `{{param.<name>}}` | Parameter passed to an action or dialog |

### Boolean Expressions

`enabled_when` and `condition` fields accept simple boolean expressions:

- Comparisons: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical operators: `and`, `or`, `not`
- Membership: `<value> in [<list>]`
- Dot access: `model.is_modified`, `state.active_tool`
- Parentheses for grouping

Example:

```yaml
enabled_when: "model.is_modified and model.has_filename"
condition: "not state.fill_on_top"
```

---

## Wireframe Mode Rendering

In wireframe mode, the renderer:

1. Walks the element tree and draws each node as a labeled rectangle, using
   `summary` as the label.
2. Preserves Bootstrap grid proportions — `row`, `col`, `grid`, and `container`
   elements determine rectangle sizes and positions.
3. On click of any rectangle, shows an inspection popover containing:
   - `description` (full English)
   - `behavior` list (events and actions)
   - `style` properties
   - `bind` state bindings
   - `tier` if present

## Normal Mode Rendering

In normal mode, the renderer:

1. Translates `container`/`row`/`col`/`grid` elements to Bootstrap HTML.
2. Renders `pane_system` children as absolutely-positioned `div`s with
   drag and resize handlers.
3. Wires `behavior` entries to JavaScript event listeners that dispatch
   named `actions`.
4. Binds `state` variables to the DOM; updates propagate reactively.
5. Renders `menubar` as a Bootstrap navbar with dropdown menus.
6. Renders `dialogs` as Bootstrap modals, shown on demand.
7. Elements with `tier: 3` are rendered as placeholder boxes.
