# Path Eraser tool

The Path Eraser tool sweeps a rectangular eraser across the
canvas; paths that intersect the rectangle are split or
deleted. Curves are preserved exactly via De Casteljau
splitting — erased paths don't re-flatten.

**Shortcut:** E (currently shared with Rounded Rectangle —
workspace YAML is authoritative for resolving the conflict).

**Cursor:** crosshair.

## Gestures

- **Press** — snapshots the document. Erases at the press
  point with a degenerate (start == end) sweep rectangle.
- **Drag** — each mousemove sweeps from the *previous* cursor
  position to the current one, expanded by `eraser_size` on
  all four sides.
- **Release** — returns to idle.

## Algorithm (per-frame)

For each unlocked Path in the document:

1. Compute the eraser AABB:
   `[min(last_x, x) − eraser_size,
     min(last_y, y) − eraser_size,
     max(last_x, x) + eraser_size,
     max(last_y, y) + eraser_size]`.
2. Flatten the path commands to a polyline.
3. Run `find_eraser_hit(flat, rect)` — returns the first
   contiguous run of flat segments that intersect the
   rectangle, plus the exact entry and exit points on the
   first / last hit segments (via Liang-Barsky clipping).
4. If no hit, leave the path alone.
5. If the path's bounding box fits inside the eraser
   (`bw ≤ eraser_size * 2` *and* `bh ≤ eraser_size * 2`),
   delete the whole element.
6. Otherwise, run `split_path_at_eraser`:
   - Open paths → 0-2 sub-paths (before the entry, after the
     exit). Each sub-path with ≥ 2 commands becomes a new
     Path element; curves are preserved by
     `split_cubic_cmd_at` / `split_quad_cmd_at`.
   - Closed paths → single open path that runs from the exit
     point around the non-erased side back to the entry point.

When any path is modified, the selection is cleared as a side
effect (matching native behavior — the old selection entries
reference paths that may no longer exist).

## What the fragments inherit

**The Ship of Theseus law (JYH, ratified 2026-07-26):** "the ship
is the same ship even when planks are removed, replaced, the
anchor is heaved — that's what an artist will expect." **Erase
does not remove identity** — it is still the same object.

Stated as a law rather than a field list, so it cannot rot as
fields are added to the Path element:

- **Exactly one surviving fragment** — always the case for a
  closed path (`split_path_at_eraser`'s closed branch returns a
  single unwrapped path), and also reachable on an open path
  erased near either end, where the short side is dropped by
  `split_path_at_eraser` itself — every fragment it emits is
  already gated at `len >= 2`, so the caller's filter is a
  redundant guard, not the mechanism. The fragment is the
  SAME element: everything except `d`
  carries across, including `transform`, the element id, the
  name, fill and stroke, both gradients, the variable-width
  profile, the brush reference and overrides, opacity,
  visibility, blend mode, mask and tool origin.
- **More than one surviving fragment** (a severing erase) —
  appearance, `transform` and `name` carry to every fragment,
  but the element **id does not**, because a live document may
  not hold two elements with the same id (`REFERENCE_GRAPH.md`
  §2.5) and nothing on the erase path can mint a fresh one.
  Minting deterministic per-fragment ids is deferred; so is
  remapping a linear gradient's stops onto each fragment's own
  bounding box, so a fragment currently re-fits the whole ramp
  rather than showing its slice. Both are named in
  `BOOLEAN.md` §"Does a path EDIT preserve the declared rule?".

The same law governs the other path edits — delete / insert
anchor, the anchor-point conversions, Smooth, and the
Paintbrush edit-gesture splice. Each replaces one element with
one element and so preserves everything but `d`. (Delete-anchor
has one non-edit outcome: on a path with too few anchors left it
removes the element entirely rather than rewriting it.)

## eraser_size parameter

`eraser_size` is the half-extent of the eraser rectangle
perpendicular to the cursor path. Default 2 pt. Exposed as a
YAML parameter so a future Path Eraser Options dialog could
wire it to a combo.

## Overlay

The native Path Eraser draws a red outlined circle of radius
`eraser_size` at the cursor. The YAML-driven overlay for this
tool isn't wired yet (no `path_eraser_overlay` render type in
the workspace dispatcher); adding one is a small follow-up
since the circle-at-cursor shape is already well-known.

## Limitations

- **Open paths only, really** — closed path "unwrapping" is
  implemented but the result may lose the visual distinction
  between "closed region erased through" and "open path
  around". Users who want to preserve the closed nature of a
  path should use a different tool (e.g. Boolean subtraction
  via the Boolean panel).
- **Stroke-only paths** — the algorithm flattens the d
  commands, not the rendered stroke. For very thick strokes,
  cursor positions near the stroke's outer edge but inside
  the stroked extent don't trigger erasure.
- **No eraser-shape variants** — the sweep is always an
  axis-aligned rectangle. Circular erasers, pressure-varying
  shapes, etc., are out of scope today.

## Related tools

- **Boolean panel** subtract-from and intersect-with operators
  are the "clean" way to remove a region from a path.
- **Smooth tool** addresses the opposite problem — too many
  anchors from a jittery pencil drag, rather than too many
  anchors from an erase-through.
