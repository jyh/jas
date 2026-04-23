# Anchor-point tools

Three small tools edit the anchors of already-drawn paths. They
complement the Pen tool (which creates paths one anchor at a
time) and the Partial Selection tool (which moves existing
anchors and handles): these three *add*, *remove*, and *toggle*
anchors.

| Tool                  | Shortcut | Does                                   |
|-----------------------|----------|----------------------------------------|
| Add Anchor Point      | `=`      | Click on a segment → insert an anchor  |
| Delete Anchor Point   | `-`      | Click on an anchor → remove it         |
| Anchor Point (Convert)| C        | Click / drag to toggle corner ↔ smooth |

All three operate only on Path elements (not on Line / Rect /
Polygon / Star). They walk the document one level of Group
nesting, so an anchor inside an unlocked Group is reachable.

## Add Anchor Point tool

Click anywhere along a path segment to insert a new anchor
there. The click tolerance is 8 px.

**Algorithm:**

1. For every unlocked Path in the document (including one level
   inside Groups), compute the closest segment to the cursor
   using the `closest_segment_and_t` kernel.
2. Keep the globally-closest (path, segment index, t, distance)
   tuple.
3. If the minimum distance exceeds `hit_radius` (8 px), no-op.
4. Otherwise, snapshot the document and call
   `insert_point_in_path` to split the hit segment at `t`. For
   a line segment the split is a straight lerp; for a cubic
   segment it's De Casteljau's algorithm (preserves the curve
   exactly — the two resulting curves trace the same path as
   the original).

**Selection:** a `.all` selection on the path stays `.all`;
partial selections are preserved as-is (the new anchor is
implicitly included since `.all` doesn't track specific CPs).
Partial-with-specific-CPs preservation across insertion is a
future enhancement.

**Scope:** click-to-insert only. Illustrator also supports
Alt+click-to-toggle (covered by the Convert tool now) and
Space+drag-to-reposition the just-inserted anchor; both are
intentionally omitted from the MVP.

## Delete Anchor Point tool

Click on an existing anchor to remove it. The click tolerance
is 8 px. Corner / smooth distinction doesn't matter — any
anchor is deletable.

**Algorithm:**

1. Find the anchor nearest the cursor across all unlocked
   Paths (same one-level-deep Group recursion as Add).
2. If no anchor is within `hit_radius` (8 px), no-op.
3. Otherwise, snapshot and call `delete_anchor_from_path`:
   - Interior deletion merges the two adjacent segments into
     one, preserving the outer handles (curve+curve → curve;
     line+line → line; mixed → curve with the kept handles).
   - First-anchor deletion promotes the second anchor's
     endpoint into a new MoveTo.
   - Last-anchor deletion trims the trailing segment and
     preserves any trailing ClosePath.
4. If the path would drop below 2 anchors, the whole Path
   element is deleted from the document instead of replaced.

## Anchor Point tool (Convert)

Toggle anchors between corner and smooth, or move a single
handle independently.

**Press-time hit priority (within 8 px):**

1. **Bezier control handle** → `pressed_handle` mode. Remembers
   the handle type (`"in"` or `"out"`) and the anchor index.
   Commit on mouseup moves that handle by the drag delta
   independently (cusp behavior — the opposite handle stays
   put). A sub-0.5-pixel drag is treated as a no-op.
2. **Smooth anchor** → `pressed_smooth` mode. Commit collapses
   the smooth anchor into a corner: both handles coincide with
   the anchor position.
3. **Corner anchor** → `pressed_corner` mode. Commit converts
   the corner into a smooth anchor whose out-handle sits at
   the mouseup position; the in-handle is mirrored through the
   anchor. A sub-1-pixel drag is treated as a no-op (a plain
   click on a corner anchor is intentionally unchanged).
4. **Miss** → `idle`, mouseup is a no-op.

**No live preview.** The final document state is computed on
mouseup; the user doesn't see the rearranged handles while
dragging. Matching Illustrator's live-preview is a follow-up.

**State lives on the `anchor_point` tool scope:**

| Key               | Type                      | Meaning                                    |
|-------------------|---------------------------|--------------------------------------------|
| `mode`            | `idle` / `pressed_*`      | Set by `probe_anchor_hit`                  |
| `hit_path`        | Path value (__path__ dict)| Which element the latched hit belongs to  |
| `hit_anchor_idx`  | number                    | Index into `control_points(elem)`          |
| `handle_type`     | `"in"` / `"out"` / `""`   | Only meaningful in `pressed_handle` mode   |

The YAML handler for `on_mouseup` reads these and dispatches
through `doc.path.commit_anchor_edit` which maps each mode to
the matching `Element.convert_*` / `move_path_handle_independent`
kernel call.

## Related tools

- **Pen tool** — creates paths anchor-by-anchor. The three
  tools here edit the result.
- **Partial Selection tool** — moves existing anchors and
  their handles along their current vector. Anchor Point
  *changes* the handle geometry (corner ↔ smooth); Partial
  Selection *translates* whatever geometry is already there.
