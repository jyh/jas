# Toolbar Design

The Jas toolbar is a vertical panel on the left edge of the application window. It uses a **2-column grid** of 32x32 pixel tool buttons on a dark background (#3c3c3c). All four implementations (Python/Qt, OCaml/GTK, Swift/AppKit, Rust/Dioxus) share the same layout.

## Grid Layout

```
 Col 0              Col 1
┌────────────────┬────────────────┐
│ Selection (V)  │ Direct Sel (A) │  Row 0
│                │ / Group Sel    │
├────────────────┼────────────────┤
│ Pen (P)        │ Pencil (N)     │  Row 1
├────────────────┼────────────────┤
│ Text (T)       │ Line (L)       │  Row 2
│ / Text on Path │                │
├────────────────┼────────────────┤
│ Rect (M)       │                │  Row 3
│ / Polygon      │                │
└────────────────┴────────────────┘
```

## Shared Slots

Three button positions host **shared slots** — two or more tools that share a single grid cell. Only one tool is visible at a time. Users switch between alternates via **long-press** (500ms hold), which opens a popup menu.

| Slot      | Primary Tool     | Alternate(s)     |
|-----------|------------------|-------------------|
| Row 0 Col 1 | Direct Selection | Group Selection |
| Row 2 Col 0 | Text             | Text on Path    |
| Row 3 Col 0 | Rectangle        | Polygon         |

Buttons with alternates display a **small filled triangle** in the lower-right corner as a visual indicator.

## Icons

Each tool button contains a 28x28 SVG icon drawn with light gray strokes (#cccccc) on the dark toolbar background. The active tool's button gets a highlighted background (#505050).

| Tool             | Icon Description                                       |
|------------------|--------------------------------------------------------|
| Selection        | Filled arrow cursor                                    |
| Direct Selection | Outline arrow cursor                                   |
| Group Selection  | Outline arrow cursor with + badge                      |
| Pen              | Fountain pen nib with center slit                      |
| Pencil           | Angled pencil with tip                                 |
| Text             | Bold "T" letter                                        |
| Text on Path     | Smaller "T" with wavy curve                            |
| Line             | Diagonal line with hollow endpoint circles             |
| Rectangle        | Outlined square                                        |
| Polygon          | Outlined hexagon                                       |

## Keyboard Shortcuts

Single-key shortcuts activate tools directly (no modifier needed):

| Key | Tool             |
|-----|------------------|
| V   | Selection        |
| A   | Direct Selection |
| P   | Pen              |
| N   | Pencil           |
| T   | Text             |
| L   | Line             |
| M   | Rectangle        |

Group Selection, Text on Path, and Polygon have no keyboard shortcuts — they are accessed via long-press on their shared slot.
