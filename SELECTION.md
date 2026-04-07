# Selection

This document describes the selection model, the three selection tools, hit
testing, and the operations that act on selections.

---

## Selection State

The selection is part of the immutable Document. It is a set of
**ElementSelection** entries, each pairing an element path with a
**SelectionKind**:

```
ElementSelection
  path:  ElementPath         position in the document tree
  kind:  SelectionKind       how the element is selected

SelectionKind = All
              | Partial(SortedCps)
```

Equality and hashing are by **path only**. The collection behaves as a
path-keyed map: each element path can appear at most once.

### SelectionKind: All vs Partial

The two cases capture two distinct user intents:

| kind | Meaning | How dragging behaves |
|------|---------|----------------------|
| `All` | The element is selected as a whole — bounding-box selection, the typical Selection Tool result. | Move/copy translates the primitive in place; Rect stays a Rect, Circle stays a Circle. |
| `Partial(s)` | Only the listed control points are selected (Direct Selection). `s` is a `SortedCps` — sorted, de-duplicated, fixed-width. | Move drags only the listed CPs; Rect/Circle/Ellipse may convert to a Polygon when the resulting shape is no longer axis-aligned. |

`Partial(SortedCps[0..n))` (every CP listed individually) is *not* the
same as `All`: the user picked CPs one at a time and expects per-CP
manipulation, not whole-element translation.

`Partial(empty)` **is** a legal, retained state — it means "the
element is selected, but zero control points are individually
highlighted". This is what the Direct Selection marquee produces when
it crosses an element's body without catching any of its CPs, and it
is also the result of toggling off the last remaining CP of a
`Partial` via shift-click. Move/drag on `Partial(empty)` is a no-op
(there are no CPs to move, and we must not fall through to a polygon
conversion that would silently change the primitive type).

`All` XOR `All` still drops the element from the selection map —
that is the element-level deselect gesture (shift-click an
already-fully-selected element). `Partial(a)` XOR `Partial(b)` keeps
the element even when the XOR is empty.

### SortedCps invariants

`SortedCps` is a sorted, de-duplicated container of control-point
indices. It guarantees:

- **Sorted ascending** — iteration is deterministic; `Set` ordering
  ambiguity is gone.
- **No duplicates** — by construction; the underlying type can no
  longer represent two copies of the same index.
- **Width-bounded** — `u16` (Rust), `UInt16` (Swift), or plain `int`
  (Python/OCaml) — small enough to keep the common case (a handful of
  CPs) tiny without sacrificing range.
- **Cheap operations** — `contains` is binary search; `XOR`/union are
  linear merges over two sorted runs.

The wrapper exists in all four ports under the same name (`SortedCps`)
with the same invariants and the same operations.

### Language representations

| Language | Selection type | Notes |
|----------|---------------|-------|
| Python   | `frozenset[ElementSelection]` | Immutable, unordered |
| OCaml    | `PathMap.t` (map keyed by `int list`) | Structural equality |
| Rust     | `Vec<ElementSelection>` | Ordered by insertion; uniqueness by convention |
| Swift    | `Set<ElementSelection>` | Path-only `Hashable` conformance |

In all four ports:
- `SelectionKind` is a tagged sum type (Rust/Swift `enum`, OCaml
  variant, Python tagged dataclass pair).
- `ElementSelection.all(path)` and `.partial(path, cps)` are the
  canonical constructors.

---

## Three Selection Modes

The application provides three selection tools, each backed by a different
Controller method. All three share the same interaction model (marquee
drag to select, click to select single elements, Shift to extend) but
differ in how they compute which elements and control points to select.

### Selection Tool

**Controller method:** `select_rect(x, y, width, height, extend)`

Selects elements whose visible geometry intersects the marquee rectangle.
Groups are selected **as a whole**: if any child of a Group intersects,
the Group itself and all its children are added to the selection with all
their control points.

```
for each layer:
  for each child:
    if child is a Group:
      if any group-child intersects rect:
        select the Group (kind: All)
        select every child of the Group (kind: All)
    else:
      if child intersects rect:
        select child (kind: All)
```

This is the standard selection behavior. Dragging over a group selects the
entire group, and moving the selection moves everything together.

### Group Selection Tool

**Controller method:** `group_select_rect(x, y, width, height, extend)`

Traverses **into** groups. Selects individual elements (not their parent
groups) with all their control points. This allows selecting elements
inside a group without selecting the group as a whole.

```
recursive check(path, elem):
  if elem is a Group or Layer:
    for each child:
      check(path + child_index, child)
  else:
    if elem intersects rect:
      select elem (kind: All)
```

### Direct Selection Tool

**Controller method:** `direct_select_rect(x, y, width, height, extend)`

Selects individual **control points** rather than whole elements. Traverses
into groups like Group Selection. The element ends up in the selection
in one of two ways:

```
recursive check(path, elem):
  if elem is a Group or Layer:
    for each child:
      check(path + child_index, child)
  else:
    hit_cps = [ i for i, (px, py) in control_points(elem)
                if point_in_rect(px, py, rect) ]
    if hit_cps non-empty:
      select elem with kind: Partial(SortedCps(hit_cps))
    else if elem intersects rect:
      # The marquee crosses the body but no CPs — pick the element
      # as a whole.
      select elem with kind: All
```

This enables moving individual vertices of a polygon, individual anchor
points of a path, or individual corners of a rectangle.

The Direct Selection Tool also supports **Bezier handle dragging**: when
the user clicks on a path handle (detected via `hit_test_handle`), dragging
moves that handle. Moving one handle automatically rotates the opposite
handle to maintain collinearity (smooth constraint), while preserving the
opposite handle's distance from the anchor.

---

## Selection Toggle (Shift)

When Shift is held, the new selection is **XORed** against the
existing selection per element:

```
_toggle_selection(current, new):
  for elements only in current:  keep as-is
  for elements only in new:      keep as-is
  for elements in both:
    match (current.kind, new.kind):
      (All,        All)        -> drop element            # cancel out
      (Partial(a), Partial(b)) -> let xor = a XOR b
                                  if xor non-empty: keep with Partial(xor)
                                  else:             drop element
      _                        -> keep with All           # mixed -> All
```

The XOR for `Partial(a) XOR Partial(b)` is the set symmetric
difference computed via the `SortedCps.symmetric_difference` linear
merge.

This means:
- Shift-marquee over an unselected element adds it.
- Shift-marquee over an already-selected element deselects it.
- Shift-marquee over a partially selected element (Direct Selection)
  toggles individual control points.
- Mixing All and Partial via Shift collapses to All for that
  element — the rare case that doesn't appear in normal use.

---

## Click Selection

When the user clicks (press and release at the same point or with minimal
movement), the selection tools behave differently from a marquee drag:

### Selection Tool click

The tool checks if the click lands on an existing element:

1. **Click on already-selected element:** enters Moving state (drag to move).
2. **Click on unselected element:** calls `select_element(path)`.
   - If the element's parent is a Group (not a Layer), the entire Group
     and all its children are selected.
   - Otherwise just the clicked element is selected.
3. **Click on empty space:** clears the selection.

### Shift-click

Toggles the clicked element in or out of the current selection without
clearing other selections.

### Alt-drag

When Alt is held during a move drag, the selected elements are **copied**
(duplicated with offset) rather than moved. The copies become the new
selection.

---

## Selection Tool Interaction States

All three selection tools share a common state machine:

```
        press on selection
IDLE ──────────────────────> MOVING
  │                             │
  │ press on empty/element      │ release
  │                             v
  └──────────────────────> MARQUEE ──> IDLE
                               │
                            release
                               v
                             IDLE
```

| State | Behavior |
|-------|----------|
| **Idle** | Waiting for input. No drag in progress. |
| **Marquee** | A dashed rectangle is drawn from press point to current cursor. On release, `select_rect` / `group_select_rect` / `direct_select_rect` is called. |
| **Moving** | Selected elements follow the cursor (shown as dashed outlines). On release, `move_selection(dx, dy)` or `copy_selection(dx, dy)` is committed. |

Shift constrains movement to 45-degree angles (horizontal, vertical, or
diagonal) by snapping the endpoint to the nearest multiple of pi/4.

---

## Hit Testing

Hit testing determines what geometric objects lie under a given point. It is
performed by pure functions in the `geometry/hit_test` module.

### Primitive tests

| Function | Description |
|----------|-------------|
| `point_in_rect(px, py, rx, ry, rw, rh)` | Is the point inside the rectangle? |
| `segments_intersect(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)` | Do two line segments cross? Uses cross-product orientation test. |
| `segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh)` | Does a segment intersect any edge of a rectangle, or is either endpoint inside? |
| `rects_intersect(ax, ay, aw, ah, bx, by, bw, bh)` | Do two axis-aligned rectangles overlap? |
| `circle_intersects_rect(cx, cy, r, rx, ry, rw, rh, filled)` | Circle-rectangle intersection. For filled circles, checks closest-point distance. For stroked (unfilled) circles, checks whether the stroke ring crosses the rect. |
| `ellipse_intersects_rect(cx, cy, erx, ery, rx, ry, rw, rh, filled)` | Ellipse-rectangle intersection by scaling to unit circle coordinates. |

### Element intersection

`element_intersects_rect(elem, rx, ry, rw, rh)` tests whether the visible
drawn portion of an element intersects a selection rectangle. The logic
depends on the element type and whether it has a fill:

| Element | Fill present | Test method |
|---------|-------------|-------------|
| Line | n/a | Segment intersection with rect edges |
| Rect | yes | Rectangle overlap (AABB) |
| Rect | no | Segment intersection for each edge |
| Circle | yes | Filled circle vs. rect |
| Circle | no | Stroke ring vs. rect |
| Ellipse | yes/no | Scaled to unit circle, then circle test |
| Polyline | yes | Bounding box overlap |
| Polyline | no | Segment intersection for each edge |
| Polygon | yes | Vertex containment + segment intersection |
| Polygon | no | Segment intersection for each edge |
| Path | yes | Flattened to segments; endpoint containment + segment intersection |
| Path | no | Flattened to segments; segment intersection |
| Text | any | Bounding box overlap |
| Group | any | Bounding box overlap |

Paths and polylines are **flattened** to line segments (Bezier curves
sampled at 20 points per curve) before testing.

### Canvas hit-test callbacks

The canvas provides hit-test callbacks to tools via the ToolContext:

| Callback | Returns | Used by |
|----------|---------|---------|
| `hit_test_selection(x, y)` | `bool` | All selection tools: determines Moving vs Marquee state |
| `hit_test_handle(x, y)` | `(path, anchor_idx, handle_type)?` | Direct Selection: detect Bezier handle clicks |
| `hit_test_text(x, y)` | `(path, element)?` | Type tool: detect clicks on text for editing |
| `hit_test_path_curve(x, y)` | `(path, element)?` | Pen tool: detect clicks on path curves |

These callbacks check the point against the current document state and
return structured results that the tools use to decide their behavior.

---

## Operations on Selections

### Move

`move_selection(dx, dy)` translates all selected control points by the
given delta. For each ElementSelection in the selection, it calls
`move_control_points(elem, cps, dx, dy)` and replaces the element in the
document.

When all CPs of an element are selected, this translates the element
rigidly. When a subset is selected (Direct Selection), only those points
move, potentially reshaping the element.

### Copy

`copy_selection(dx, dy)` duplicates each selected element, inserts the copy
immediately after the original, offsets the copy by `(dx, dy)`, and updates
the selection to refer to the copies. The originals remain in place and
unselected.

### Delete

`delete_selection()` removes all selected elements from the document. Paths
are sorted in reverse order before deletion so that removing later elements
does not invalidate the paths of earlier ones.

### Lock / Unlock

`lock_selection()` sets `locked = true` on all selected elements (recursing
into Groups) and clears the selection. Locked elements are skipped by all
selection and hit-test operations.

`unlock_all()` clears the locked flag on all elements in the document and
selects the newly unlocked elements.

### Group / Ungroup

`group_selection()` wraps the selected sibling elements into a new Group
element, replacing them in the layer.

`ungroup_selection()` replaces each selected Group with its children,
splicing them into the parent container at the Group's position.

### Clipboard

- `copy()` — stores the selected elements in an internal clipboard.
- `cut()` — copies then deletes the selection.
- `paste()` — inserts clipboard elements into the active layer, offset by
  `PASTE_OFFSET` (24 pt) to distinguish from originals, and selects the
  pasted elements.

---

## Select Element

`select_element(path)` selects a single element by its path. It has special
behavior for grouped elements:

1. Look up the element at the given path.
2. If the element is locked, do nothing.
3. If the element's immediate parent is a Group (not a Layer):
   - Select the parent Group with all its CPs.
   - Also select every child of the Group with all their CPs.
4. Otherwise, select just the element with all its CPs.

This ensures that clicking on a group member in the Selection tool always
selects the whole group.

---

## Select Control Point

`select_control_point(path, index)` selects a single control point on an
element, replacing the entire selection. This is used by the Direct
Selection tool when the user clicks on a specific handle.
