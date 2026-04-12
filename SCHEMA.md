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

app:              <app_spec>
theme:            <theme_spec>
icons:            <map: name → icon_def>
state:            <map: name → state_var>
runtime_contexts: <map: name → context_def>
actions:          <map: name → action_def>
shortcuts:        <list of shortcut>
menubar:          <list of menu>
layout:           <element>
dialogs:          <map: name → dialog>
default_layouts:  <map: name → layout_data>
```

All top-level keys are required except `icons`, `runtime_contexts`,
`dialogs`, and `default_layouts` (optional).

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
shortcuts reference actions by id. Each action has an `effects` list that
describes exactly what the action does — state mutations, visual changes,
dialog control, etc. — in a form the renderer can execute directly.

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
    effects: <list of effect>    # optional; what the action does (see Effects)
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
  select_tool:
    description: "Switch the active tool"
    category: tool
    params:
      tool: { type: state_ref, ref: "active_tool" }
    effects:
      - set: { active_tool: "{{param.tool}}" }

  swap_fill_stroke:
    description: "Swap fill and stroke colors"
    category: fill_stroke
    effects:
      - swap: [fill_color, stroke_color]

  toggle_pane:
    description: "Show or hide a pane"
    category: window
    params:
      pane: { type: enum, values: [toolbar, canvas, dock] }
    effects:
      - toggle: "{{param.pane}}_visible"

  revert:
    description: "Reload document from disk"
    category: file
    enabled_when: "model.is_modified and model.has_filename"
    effects:
      - dispatch: reload_from_disk
```

---

## `effect` — Executable Operations

Effects describe what an action does. They are executed in order. Each effect
is a single-key map where the key is the operation type.

### State Mutations

```yaml
# Set one or more state variables
- set: { <key>: <value>, ... }

# Toggle a boolean state variable
- toggle: <state_key>

# Swap the values of two state variables
- swap: [<state_key_a>, <state_key_b>]

# Increment / decrement a numeric state variable
- increment: { key: <state_key>, by: <number> }
- decrement: { key: <state_key>, by: <number> }

# Reset state variables to their declared defaults
- reset: [<state_key>, ...]
```

### Conditional Logic

```yaml
# Execute effects conditionally
- if:
    condition: <interpolated>      # boolean expression
    then: <list of effect>         # executed when true
    else: <list of effect>         # optional; executed when false
```

### Element Manipulation

```yaml
# Show / hide an element by id
- show: <element_id>
- hide: <element_id>

# Add / remove a CSS class on an element
- add_class: { target: <element_id>, class: <string> }
- remove_class: { target: <element_id>, class: <string> }

# Set a CSS property on an element
- set_style: { target: <element_id>, <property>: <value>, ... }

# Set focus to an element
- focus: <element_id>

# Scroll an element into view
- scroll_to: <element_id>
```

### Dynamic Element Creation

```yaml
# Create a new child element inside a container
- create_child:
    parent: <element_id>            # container to append to
    props:                           # optional; template variables
      <name>: <interpolated>         #   resolved once at creation time
    element: <element>              # full element spec to create
    
# Remove a child element by id
- remove_child: <element_id>
```

**Template resolution in `create_child`:** The `props` map is evaluated once
from the current state at creation time, producing literal values. Then every
`{{prop.<name>}}` reference in the element tree (including nested children) is
replaced with the corresponding literal. After prop substitution, the element
is instantiated normally — `id` becomes a fixed string, `bind` expressions
remain reactive, and `behavior` effects are evaluated at event time.

This separation allows dynamic elements to capture values at creation time
(via `{{prop.*}}`) while keeping state bindings reactive (via `{{state.*}}`).

Example — creating a tab that remembers its index:

```yaml
- create_child:
    parent: tab_bar
    props:
      index: "{{state.tab_count}}"
    element:
      id: "tab_{{prop.index}}"
      bind:
        active: "{{state.active_tab}} == {{prop.index}}"
      behavior:
        - event: click
          effects:
            - set: { active_tab: "{{prop.index}}" }
```

After creation with `tab_count == 2`, the element becomes:

```yaml
id: "tab_2"                          # fixed string
bind:
  active: "{{state.active_tab}} == 2" # reactive — updates when active_tab changes
behavior:
  - event: click
    effects:
      - set: { active_tab: 2 }       # always sets to 2
```

### Layout Operations

```yaml
# Tile panes in a horizontal row filling the viewport.
# Panes with fixed_width keep their width. Panes with collapsed_width
# keep their current width. Flex panes split the remaining space equally
# (respecting min_width). All panes are full viewport height. Hidden
# panes are made visible. Panes are sorted left-to-right by current x.
- tile: { container: <element_id> }

# Reset all pane positions/sizes to their default_position values
# and restore all layout_state variables to their defaults
- reset_layout: { container: <element_id> }

# Save current pane layout to browser storage under a name
# read from a text input element
- save_layout: { container: <element_id>, name_input: <element_id> }

# Load a named layout from browser storage
- load_layout: { container: <element_id>, name: <string> }

# Reload the currently active saved layout
- revert_layout: { container: <element_id> }

# Delete a named layout from browser storage
- delete_layout: { name: <string> }

# Maximize a pane to fill its parent container
- maximize: { target: <element_id> }

# Restore a previously maximized pane
- restore: { target: <element_id> }
```

### Dock Operations

```yaml
# Detach a panel group from a dock_view, creating a new floating pane
# containing a dock_view with that group. The new pane is positioned at
# (x, y) and participates in the pane system (drag, resize, snap).
- detach_group:
    source: <dock_view_id>         # dock_view element to detach from
    group: <integer>               # index of the group to detach
    x: <number>                    # x position for the new floating pane
    y: <number>                    # y position for the new floating pane

# Merge all groups from a floating dock pane back into an anchored dock.
# The groups are appended to the target dock_view. The floating pane is
# removed from the pane system.
- redock:
    source: <dock_view_id>         # floating dock's dock_view
    target: <dock_view_id>         # anchored dock's dock_view

# Move a panel from its current group to a different group. If the source
# group becomes empty, it is removed. If the target group index equals
# the number of groups, a new group is created.
- move_panel:
    panel: <panel_name>            # panel to move (e.g. "color")
    target: <dock_view_id>         # target dock_view
    group: <integer>               # target group index
    index: <integer>               # position within the target group

# Reorder a panel within its group (swap positions).
- reorder_panel:
    dock: <dock_view_id>           # dock_view containing the group
    group: <integer>               # group index
    from: <integer>                # current panel position
    to: <integer>                  # new panel position

# Move an entire group from one dock to another.
- move_group:
    source: <dock_view_id>         # source dock_view
    group: <integer>               # group index in source
    target: <dock_view_id>         # target dock_view
    position: <integer>            # insertion index in target

# Close (hide) a panel. Removes it from its group. If the group becomes
# empty, the group is removed. The panel can be shown again via the
# Window menu's panel toggle.
- close_panel:
    panel: <panel_name>            # panel to close

# Show a hidden panel. Adds it to the last group of the anchored dock.
- show_panel:
    panel: <panel_name>            # panel to show
    target: <dock_view_id>         # dock_view to add it to
```

### Dialog Control

```yaml
# Open a dialog by id, passing parameters
- open_dialog: { id: <dialog_id>, params: { ... } }

# Close the current dialog (or a specific one)
- close_dialog: <dialog_id>       # optional; omit to close topmost
```

### Action Chaining

```yaml
# Dispatch another action (for composition)
- dispatch: <action_id>
- dispatch: { action: <action_id>, params: { ... } }
```

### Visual Feedback

```yaml
# Set the cursor on an element (or globally)
- cursor: <cursor_type>           # pointer, grab, grabbing, crosshair, etc.
- cursor: { target: <element_id>, type: <cursor_type> }

# Flash/highlight an element briefly
- flash: <element_id>

# Show a tooltip or status message
- status: <string>
```

### Timer Control

```yaml
# Start a named timer (for long-press, auto-save, etc.)
- start_timer:
    id: <string>
    delay_ms: <number>
    effects: <list of effect>      # executed when timer fires

# Cancel a named timer
- cancel_timer: <string>
```

### Logging

```yaml
# Log a message to the console (useful for tier 3 placeholders)
- log: <string>
```

### Example: Complete action with conditional effects

```yaml
actions:
  close_tab:
    description: "Close a document tab"
    category: tab
    params:
      index: { type: number }
    effects:
      - if:
          condition: "model.is_modified"
          then:
            - open_dialog:
                id: save_changes_tab
                params: { filename: "{{model.filename}}" }
          else:
            - dispatch: { action: remove_tab, params: { index: "{{param.index}}" } }

  reset_fill_stroke:
    description: "Reset to default white fill and 1pt black stroke"
    category: fill_stroke
    effects:
      - set: { fill_color: "#ffffff", stroke_color: "#000000", stroke_width: 1.0, fill_on_top: true }
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
  - { key: "Ctrl+N",   action: new_document }
  - { key: "V",        action: select_tool,       params: { tool: selection } }
  - { key: "Shift+X",  action: swap_fill_stroke }
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

### `include` — External Element Files

Anywhere an element appears in `children`, an `include` directive may be used
instead of an inline element definition. The included file contains a single
element spec (with `id`, `type`, etc.) and is loaded relative to the workspace
directory. Additional properties (`bind`, `style`, etc.) on the include entry
are merged onto the loaded element.

```yaml
children:
  - include: "panels/layers.yaml"
  - include: "panels/color.yaml"
    bind:
      visible: "{{state.color_visible}}"
```

All fields except `type` are optional, though `id` and `summary` are
recommended for every element.

### Element Types

| Type | Purpose | Extra Properties |
|---|---|---|
| `pane_system` | Absolute-positioned draggable pane container | — |
| `pane` | Draggable, resizable pane | `default_position`, `title_bar`, `content`, `min_width`, `max_width`, `min_height` |
| `dock_view` | Panel group container with tab bars and collapse | `groups`, `collapsed_width` |
| `container` | Bootstrap container | `layout`: `column` or `row` |
| `row` | Bootstrap row | — |
| `col` | Bootstrap column | `col`: 1–12 or `auto` |
| `grid` | Fixed grid | `cols`, `rows` (optional), `gap` |
| `tabs` | Tabbed container; one child visible at a time | `active`: index or bind expression |
| `panel` | Named content region within tabs | `panel_kind`, `menu` |
| `button` | Clickable button | `label`, `action`, `params`, `variant`, `icon` |
| `icon_button` | Small icon-only button | `icon`, `action`, `params` |
| `dropdown` | Button that opens a menu of items | `icon`, `label`, `items`: list of `{label, action, params}` |
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
fixed_width: <bool>              # optional; pane cannot be resized horizontally
flex: <bool>                     # optional; pane expands to fill remaining space
collapsed_width: <number>        # optional; width when collapsed

layout_state: [<state_key>, ...] # optional; state variables saved/restored
                                 # with workspace layouts (see Saved Layouts)

title_bar:
  id: <string>                   # optional; enables behaviors on the title bar
  label: <string>
  draggable: <bool>
  behavior: <list of behavior>   # optional; e.g. double_click to maximize
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

## `panel_group` — Panel Group

A panel group is an ordered collection of panels displayed as a tabbed
container. One panel is active (visible) at a time. The group can be
collapsed to hide its body. Panel groups are the children of a `dock_view`.

```yaml
panel_group:
  panels: [<panel_name>, ...]    # ordered list of panel names
  active: <integer>              # index of the visible panel (default 0)
  collapsed: <bool>              # whether the group body is hidden (default false)
```

Panel names reference content defined in `workspace/panels/*.yaml`. The
renderer builds the tab bar, collapse chevron, and hamburger menu
automatically from the group definition.

---

## `dock_view` — Dock Container

A `dock_view` element renders a vertical stack of panel groups with tab
bars, collapse/expand chevrons, hamburger menus, and panel content bodies.
It also handles the collapsed icon strip when the dock is collapsed.

```yaml
type: dock_view
collapsed_width: <number>        # width when collapsed (default 36)
groups:
  - panels: [layers]
    active: 0
  - panels: [color, stroke, properties]
    active: 0
```

The `dock_view` renders automatically based on its `groups` list:

- **Expanded**: For each group, a header row with tab buttons (one per
  panel), a collapse chevron, and a hamburger menu. Below the header,
  the active panel's content (from `workspace/panels/*.yaml`). Groups
  are separated by horizontal dividers.
- **Collapsed**: A vertical icon strip showing one icon per panel. Click
  an icon to expand the dock and activate that panel.

Panel groups can be dragged within a dock (reorder), between docks
(move), or to empty space (creating a floating dock pane). Individual
panel tabs can be dragged to reorder within their group or move to a
different group in any dock.

### `panel_menu_item`

Each panel's hamburger menu contains items for closing the panel.

```yaml
- label: <string>
  action: <action_id>
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
  aspect_ratio: <number>             # width / height ratio (e.g. 1 = square)
  flex: <number>                     # flex grow factor
  font_size: <number>                # font size in pixels (overrides theme font)

  # Layout
  alignment: start | center | end | stretch
  justify: start | center | end | between | around
  overflow: visible | hidden | scroll | auto

  # Positioning (within absolute-positioned parents)
  position: { x: <number>, y: <number> }
  z_index: <number>

  # Cursor
  cursor: <string>                   # CSS cursor value (pointer, grab, crosshair, etc.)

  # Interactive states (applied automatically by the renderer)
  hover:                             # style overrides when hovered
    background: <color_value>
    border: <string>
    # ... any style property
  active:                            # style overrides when mouse is pressed
    background: <color_value>
  focus:                             # style overrides when focused
    border: <string>
  checked:                           # style overrides when in checked state (bound via bind.checked)
    background: <color_value>
  disabled:                          # style overrides when disabled (enabled_when is false)
    opacity: <number>
    cursor: <string>
```

---

## `behavior` — Event → Action Binding

Each behavior entry binds a DOM event to either a named action or an inline
list of effects. This is the primary mechanism for making the UI interactive.

```yaml
behavior:
  - event: <event_type>
    action: <action_id>              # dispatch a named action (simple form)
    params: { ... }                  # optional, passed to action
    effects: <list of effect>        # inline effects (alternative to action)
    condition: <interpolated>        # optional boolean guard
    delay_ms: <number>               # optional (e.g. for long_press)
    menu: <string>                   # optional menu id to open
    dialog: <string>                 # optional dialog id to open
    prevent_default: <bool>          # optional; suppress native browser behavior
    stop_propagation: <bool>         # optional; prevent event bubbling
    description: <string>            # English explanation of behavior
```

An entry may specify `action` (dispatches a named action from the catalog),
`effects` (inline list executed directly), or both (action runs first, then
inline effects). If `condition` is present, the handler only fires when the
expression is true.

### Event Types

| Event | Meaning |
|---|---|
| `click` | Mouse click / tap |
| `double_click` | Double click |
| `long_press` | Press and hold (fires after `delay_ms`) |
| `right_click` | Context menu click |
| `mouse_down` | Mouse button pressed |
| `mouse_up` | Mouse button released |
| `mouse_move` | Mouse moved (while over element) |
| `drag_start` | Begin drag (mouse_down + move threshold) |
| `drag_move` | During drag (each mouse_move while dragging) |
| `drag_end` | Drag released (mouse_up while dragging) |
| `drop` | Drop target receives a dragged item |
| `hover_enter` | Mouse enters element bounds |
| `hover_leave` | Mouse leaves element bounds |
| `key_down` | Keyboard key pressed |
| `key_up` | Keyboard key released |
| `change` | Value changed (inputs, toggles, selects) |
| `tab_click` | Tab header selected (within `tabs`) |
| `tab_close` | Tab close button clicked |
| `resize` | Element resized |
| `collapse_toggle` | Collapse/expand toggled |
| `timer` | Named timer fired (see `start_timer` effect) |

The event list is extensible — unknown event names are preserved in the spec
and displayed in wireframe inspection mode.

### Interaction Protocols

Complex interactions like dragging and long-press menus are composed from
primitive events and effects. The schema provides standard protocols.

#### Drag Protocol

Pane dragging and edge resizing are expressed as three cooperating behaviors.
The `drag_start` event fires when a mouse_down is followed by movement beyond
a threshold (default 3px). The renderer tracks the drag state internally.

```yaml
behavior:
  - event: drag_start
    description: "Begin dragging this pane"
    effects:
      - cursor: grabbing
      - set: { _drag_offset_x: "{{event.offset_x}}", _drag_offset_y: "{{event.offset_y}}" }
  - event: drag_move
    description: "Move pane to follow cursor, snapping to nearby edges"
    effects:
      - set_style:
          target: "{{self.id}}"
          left: "{{event.client_x - state._drag_offset_x}}"
          top: "{{event.client_y - state._drag_offset_y}}"
  - event: drag_end
    effects:
      - cursor: grab
```

#### Long-Press Protocol

Long-press is expressed using `mouse_down` to start a timer, and `mouse_up`
to cancel it if released early. If the timer fires, the menu opens.

```yaml
behavior:
  - event: mouse_down
    effects:
      - start_timer:
          id: "long_press_{{self.id}}"
          delay_ms: 250
          effects:
            - open_dialog: { id: "{{self.alternates.menu_id}}" }
  - event: mouse_up
    effects:
      - cancel_timer: "long_press_{{self.id}}"
  - event: click
    action: select_tool
    params: { tool: pen }
```

#### Hover Feedback Protocol

```yaml
behavior:
  - event: hover_enter
    effects:
      - add_class: { target: "{{self.id}}", class: "hover" }
      - cursor: pointer
  - event: hover_leave
    effects:
      - remove_class: { target: "{{self.id}}", class: "hover" }
      - cursor: default
```

### Event Context Variables

Within behavior `effects` and `condition` expressions, the following context
variables are available in addition to `state.*` and `theme.*`:

| Variable | Meaning |
|---|---|
| `event.client_x` | Mouse X relative to viewport |
| `event.client_y` | Mouse Y relative to viewport |
| `event.offset_x` | Mouse X relative to element |
| `event.offset_y` | Mouse Y relative to element |
| `event.key` | Key name for keyboard events |
| `event.ctrl` | Whether Ctrl/Cmd is held |
| `event.shift` | Whether Shift is held |
| `event.alt` | Whether Alt is held |
| `event.target_id` | The id of the element that received the event |
| `event.value` | New value for `change` events |
| `self.id` | The id of the element that owns this behavior |
| `self.type` | The type of the element |

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

### Standard Bindable Properties

| Property | Type | Meaning |
|---|---|---|
| `visible` | bool | Whether the element is rendered (default true) |
| `checked` | bool | Whether the element is in checked/active state (applies `style.checked` overrides) |
| `active` | bool | Whether a tab button or similar element is the active/selected one (applies active styling) |
| `collapsed` | bool | Whether a pane uses its `collapsed_width` instead of its current width |
| `color` | color | The displayed color (for `color_swatch` elements) |
| `icon` | string | The icon name (for `icon_button` elements; switches icon dynamically) |
| `z_index` | number | The stacking order of the element |

Any style property may also appear in `bind` to make it reactive.

Example:

```yaml
bind:
  visible: "{{state.dock_collapsed}}"
  active: "{{state.dock_group1_active}} == 0"
  icon: "{{state.dock_collapsed}} == true ? chevron_left : chevron_right"
  color: "{{state.fill_color}}"
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
    state:                           # optional dialog-local state
      <name>:
        type: enum | color | number | bool | string
        values: [...]                # when type=enum
        default: <value>
        description: <string>
    init:                            # optional; initialize dialog state on open
      <state_name>: <interpolated>   # expression evaluated at open time
    content: <element>               # layout tree for dialog body
```

### Dialog-Local State

Dialogs may declare their own `state` section. These variables:

- Are created when the dialog opens and destroyed when it closes.
- Are referenced within the dialog's content tree via `{{dialog.<name>}}`.
- Are initialized in two phases: first to `default` values, then overridden
  by the `init` section (if present). Init expressions are evaluated once at
  open time in the context of the dialog's `params` and the current global
  `state`.
- Are reactive within the dialog — changes propagate to bound elements.
- Are not visible to global state or other dialogs.
- Cannot be mutated by global actions. Only effects within the dialog's own
  behaviors (or actions dispatched from them) can modify dialog state via
  `set: { dialog.<name>: <value> }`.

To commit dialog values back to global state, the dialog's OK/confirm action
should use `set` effects targeting global state variables:

```yaml
effects:
  - set: { fill_color: "{{dialog.color}}" }
  - close_dialog: null
```

### Color Conversion Functions

Init expressions may use built-in color conversion functions to decompose a
color value into its components:

| Function | Returns |
|---|---|
| `hsb_h(<color>)` | Hue component (0–360) |
| `hsb_s(<color>)` | Saturation component (0–100) |
| `hsb_b(<color>)` | Brightness component (0–100) |
| `rgb_r(<color>)` | Red component (0–255) |
| `rgb_g(<color>)` | Green component (0–255) |
| `rgb_b(<color>)` | Blue component (0–255) |
| `cmyk_c(<color>)` | Cyan component (0–100) |
| `cmyk_m(<color>)` | Magenta component (0–100) |
| `cmyk_y(<color>)` | Yellow component (0–100) |
| `cmyk_k(<color>)` | Key/black component (0–100) |
| `hex(<color>)` | Hex string without `#` prefix |
| `rgb(<r>, <g>, <b>)` | Compose color from RGB components |
| `hsb(<h>, <s>, <b>)` | Compose color from HSB components |

### Examples

Simple confirmation dialog (no local state):

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
| `{{prop.<name>}}` | Template variable from `create_child` (resolved once at creation) |
| `{{dialog.<name>}}` | Dialog-local state variable (see Dialogs) |
| `{{active_document.<name>}}` | Property of the active document (see Runtime Contexts) |
| `{{workspace.<name>}}` | Property of the workspace (see Runtime Contexts) |

### Expressions

Interpolated strings, `enabled_when`, `condition`, and `bind` values may
contain expressions. The expression language supports:

- **Comparisons:** `==`, `!=`, `<`, `>`, `<=`, `>=`
- **Logical operators:** `and`, `or`, `not`
- **Membership:** `<value> in [<list>]`
- **Ternary:** `<condition> ? <if_true> : <if_false>`
- **Dot access:** `active_document.is_modified`, `state.active_tool`
- **Parentheses** for grouping

`enabled_when` and `condition` fields must evaluate to a boolean. Bind
values and style properties may evaluate to any type (string, number, bool)
via ternary expressions.

Examples:

```yaml
# Boolean (for enabled_when / condition)
enabled_when: "active_document.is_modified and active_document.has_filename"
condition: "not state.fill_on_top"

# Ternary — selects a value based on a condition
bind:
  icon: "{{state.dock_collapsed}} == true ? chevron_left : chevron_right"
  z_index: "{{state.fill_on_top}} == true ? 2 : 1"
```

---

## Runtime Contexts

In addition to `state` (declared reactive variables), `theme` (visual tokens),
and `param` (action/dialog parameters), two runtime contexts provide read-only
properties computed by the renderer engine.

Runtime contexts are declared in a `runtime_contexts` workspace file so the
renderer can validate interpolation expressions at load time.

```yaml
runtime_contexts:
  <namespace>:
    description: <string>
    defaults:                        # values when context is unavailable
      <property>: <value>
    properties:
      <property>:
        type: bool | string | number
        description: <string>
```

### `active_document` — Active Document

Properties of the currently active document tab. When no tab is open
(`active_tab == -1`), all properties resolve to their declared defaults.

| Property | Type | Default | Meaning |
|---|---|---|---|
| `is_modified` | bool | `false` | The active document has unsaved changes |
| `has_filename` | bool | `false` | The active document has been saved to a file at least once |
| `filename` | string | `""` | The active document's filename (empty string if untitled) |
| `any_modified` | bool | `false` | Any open document has unsaved changes |
| `has_selection` | bool | `false` | One or more objects are selected |
| `selection_count` | number | `0` | Number of selected objects |
| `can_undo` | bool | `false` | The undo stack is non-empty |
| `can_redo` | bool | `false` | The redo stack is non-empty |
| `zoom_level` | number | `1.0` | Current zoom factor (1.0 = 100%) |

These properties are not assignable via `set` effects. They are updated
automatically by the renderer when documents are opened, edited, saved,
or closed.

### `workspace` — Workspace State

Properties of the workspace layout system. These are managed by the layout
save/load engine, not by `state` variables.

| Property | Type | Default | Meaning |
|---|---|---|---|
| `has_saved_layout` | bool | `false` | A named layout is currently active (was loaded or saved) |
| `active_layout_name` | string | `""` | Name of the currently active layout (empty if none) |

---

## Saved Layouts (Workspaces)

A workspace layout captures the positions, sizes, and associated state of all
panes, allowing the user to save, switch between, and restore named layouts.

### What gets saved

When a layout is saved (via `save_layout` effect), the following data is
captured for each pane in the container:

```yaml
# Saved layout format (stored in browser localStorage)
<layout_name>:
  panes:
    <pane_id>:
      left: <number>               # x position in pixels
      top: <number>                # y position in pixels
      width: <number>              # width in pixels
      height: <number>             # height in pixels
  state:                           # layout-specific state variables
    <state_key>: <value>
    ...
```

### `layout_state` — declaring layout-specific state

Panes and containers may declare which state variables are part of the
workspace layout using the `layout_state` property:

```yaml
- id: dock_pane
  type: pane
  layout_state: [dock_collapsed, dock_group0_active, dock_group1_active,
                 dock_group0_collapsed, dock_group1_collapsed]
```

When a layout is saved, the current values of all `layout_state` variables
(from all panes in the container) are captured alongside pane positions. When
a layout is loaded, those state variables are restored to their saved values.

State variables NOT listed in any `layout_state` property are considered
app state and are not affected by workspace save/load/reset.

### `default_layouts` — pre-defined layouts

The top-level `default_layouts` section (optional) defines named layouts
that ship with the app. These appear in the Workspace menu alongside
user-saved layouts but cannot be overwritten or deleted.

```yaml
default_layouts:
  <name>:
    panes:
      <pane_id>:
        left: <number>
        top: <number>
        width: <number>
        height: <number>
    state:
      <state_key>: <value>
```

### Storage

The storage backend for saved layouts is implementation-defined. A web
renderer may use browser `localStorage`; a desktop app may use the local
filesystem; a collaborative tool may use a database. The schema defines
only the data format — a map of layout names to layout data — not the
storage mechanism.

The active layout name is tracked by the renderer engine (not as a state
variable) and is used to show a checkmark in the Workspace menu and to
enable the "Revert to Saved" command.

### Workspace menu

The `dynamic: true` property on a submenu signals the renderer to
populate it at runtime. For the Workspace submenu, the renderer:

1. Lists all saved layout names (from localStorage + default_layouts)
2. Shows a checkmark next to the active layout
3. Appends the static menu items (Save As, Reset, Revert) from the YAML

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
