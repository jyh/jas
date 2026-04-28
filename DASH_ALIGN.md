# Dash Alignment

## Motivation

Dashed strokes laid out by raw `stroke-dasharray` semantics — pattern
walked along arc-length end-to-end — make corner anchors fall wherever
the math lands. A 12 pt dash on a path whose first segment is 17 pt
ends a dash 7 pt past the corner; the corner sits in the middle of a
gap. The same path with a 13 pt segment puts the corner inside a
dash. The result is visually arbitrary: identical-looking paths that
differ only in segment lengths render with different corner
treatments.

Production vector apps offer an opt-in mode that adjusts each
segment's dash period slightly so a dash is centered on every corner
anchor and a full dash sits at each open path end. The dash and gap
lengths the user typed remain the user's *intent*; the renderer flexes
those lengths per-segment so corners and endpoints fall on
anchor-relative positions instead of arbitrary arc-length positions.

This spec defines the feature, the algorithm, and the persistence
model for jas.

## Modes

A new boolean panel state field `dash_align_anchors` selects between
two modes for any given stroke:

- **Preserve** (`dash_align_anchors = false`, default). The
  `stroke-dasharray` is applied along arc-length exactly as the user
  typed it. Corners and path ends fall wherever the math lands. This
  is the default because it matches plain SVG semantics, so any path
  imported from a non-jas SVG round-trips visually identical to the
  source tool.

- **Align to anchors** (`dash_align_anchors = true`). For each
  subpath, alignment points are:
  - **Open subpath**: { first endpoint, every interior anchor, last endpoint }
  - **Closed subpath**: { every anchor }

  The dash and gap lengths flex per-segment between adjacent alignment
  points so:
  - A **full dash** starts at each open-path endpoint.
  - A **dash is centered on each interior anchor** (the dash spans the
    anchor; one half-dash on each side).

  The user's typed dash / gap values describe the *target* lengths;
  the per-segment scale factor is chosen so an integer number of dash
  periods fits between adjacent alignment points, with the boundary
  conditions above honored.

The two modes are mutually exclusive — represented in the panel as a
pair of radio-style icon buttons. Exactly one is shown active.

## Algorithm

```
expand_dashed_stroke(path, dash_array, align_anchors) -> [SubPath]

  if dash_array is empty or all zeros:
    return [path]              # solid stroke

  if not align_anchors:
    # Preserve mode: walk the path's full arc-length end-to-end with a
    # single dash period. Cross-segment dashes follow the original
    # path geometry through anchors.
    return walk_dashes(
      path,
      period = sum(dash_array),
      pattern = dash_array,
      offset = 0,
    )

  # Align mode: per-subpath, per-segment-between-alignment-points.
  result = []
  for subpath in path.subpaths:
    alignment_points = subpath_alignment_points(subpath)
    base_period = sum(dash_array)

    for (a, b) in adjacent_pairs(alignment_points):
      L = arc_length(subpath, a, b)
      kind = boundary_kind(a, b, subpath.closed)
      n, scale = solve_segment_period(L, base_period, kind)
      pattern = scale_pattern(dash_array, scale)
      offset = boundary_offset(kind, pattern)
      sub_subpath = subpath_between(subpath, a, b)
      result += walk_dashes(sub_subpath, n*scale*base_period, pattern, offset)

  return result
```

### `boundary_kind`

Given two adjacent alignment points and whether the subpath is closed:

- `INTERIOR_INTERIOR` — both ends are interior anchors. Dashes are
  centered on each end. Effective length = `L`.
- `END_INTERIOR` — start is an open-path endpoint. A full dash starts
  at parameter 0; a half-dash centers on the end anchor. Effective
  length = `L - half_first_dash`.
- `INTERIOR_END` — symmetric to `END_INTERIOR`.
- `END_END` — open subpath with two anchors and one segment, both
  endpoints. Full dashes at each end. Effective length = `L`.

For closed subpaths, all boundary kinds are `INTERIOR_INTERIOR`.

### `solve_segment_scale`

Given segment length `L`, base period `P = d + g` (sum of the first
two pattern entries), first-dash length `d`, and boundary kind, find
the integer `m` and scale `s` such that the segment's dash layout
fits exactly in length `L`. The scale `s` is the per-segment flex
applied uniformly to every dash and gap in the pattern.

The layouts and resulting formulas:

```
II — half-dash, gap, dash, gap, ..., dash, gap, half-dash
   layout: m gaps + (m-1) full dashes + 2 half-dashes = m*P
   m = max(1, round(L / P))
   s = L / (m * P)

EE — dash, gap, dash, ..., gap, dash
   layout: m gaps + (m+1) full dashes = m*P + d
   m = max(0, round((L - d) / P))
   s = L / (m*P + d)

EI / IE — dash, gap, ..., gap, dash, gap, half-dash  (or symmetric)
   layout: m gaps + m full dashes + 1 half-dash = m*P + 0.5*d
   m = max(1, round((L - 0.5*d) / P))
   s = L / (m*P + 0.5*d)
```

The `0.5*d` term reflects that the half-dash absorbed at an interior
boundary is half a *dash* (not half a period). The earlier draft of
this spec used `(n - 0.5) * P`, which only matched for d = P (a
solid stroke). The corrected formulas above pass the per-language
parity tests for all dash:gap ratios.

Edge case: `m = 0` for II / EI / IE (or `m = 0` for EE with `d > L`)
means the segment is shorter than one dash period. Snap to a single
dash covering the entire segment (no gap). Rare in practice (very
short segments at small dash sizes) and looks correct: the segment
is "all dash".

### `walk_dashes`

Given a subpath, the total scaled period `T = n * s * P`, the scaled
pattern, and an offset:

1. Compute arc-length for every primitive segment (line / cubic / arc)
   in the subpath via flattened polylines (~32 samples per curve;
   accuracy is irrelevant beyond a fraction of the smallest dash).
2. Walk the cumulative arc-length from `offset` to total length,
   stepping through the scaled pattern: dash → gap → dash → gap.
3. For each `dash` interval `[t_start, t_end]`, emit a sub-path that
   follows the original geometry between those parameters via
   `subpath_between`.
4. `gap` intervals emit nothing.

### `subpath_between`

Given a subpath and two arc-length parameters `t1 < t2`, emit a
sub-path that follows the original geometry exactly between them.

- **Locate.** Find the primitive segment containing `t1` (call it
  segment A at parameter `α`) and the segment containing `t2` (segment
  B at parameter `β`).
- **Single-segment case (A == B).**
  - **Line:** linear interpolation; emit `M point(α) L point(β)`.
  - **Cubic:** De Casteljau twice — split at `α`, take right half;
    rescale `β` for the right half, split, take left half. Emit `M`
    plus `C` with the resulting control points.
  - **Arc:** split at parameter angle.
- **Multi-segment case.**
  - Truncate segment A to `[α, end_A]`, emit as the first command.
  - Emit segments fully between A and B verbatim.
  - Truncate segment B to `[start_B, β]`, emit as the last command.
- **De Casteljau split** is the standard recursive subdivision: given
  control points `[P0,P1,P2,P3]` and parameter `t`, the left half is
  `[P0, lerp(P0,P1,t), lerp(lerp(P0,P1,t), lerp(P1,P2,t), t),
  lerp(lerp(lerp(P0,P1,t),lerp(P1,P2,t),t), lerp(lerp(P1,P2,t),lerp(P2,P3,t),t), t)]`
  and the right half is the mirror.

## Persistence

A new boolean SVG attribute on stroked elements:

- `data-jas-dash-align-anchors="true"` when align mode is on.
- Attribute is **omitted** when align mode is off (default false,
  identity-omitted per the SCHEMA.md convention).

The user-typed dash / gap pattern is persisted as the literal
`stroke-dasharray` value. The renderer reads `dash_align_anchors` from
the document model + the dasharray, runs `expand_dashed_stroke` at
draw time, and emits solid sub-paths.

### SVG round-trip

- **Save.** A jas-authored stroke with `dash_align_anchors=true` emits
  `stroke-dasharray="12 6 0 6"` (the literal pattern) plus
  `data-jas-dash-align-anchors="true"`. Reopening the same file
  reconstructs the alignment intent exactly.
- **Open** a non-jas SVG. There's no `data-jas-dash-align-anchors`
  attr, so the field defaults to `false` (preserve mode). The path
  renders with the source SVG's literal dasharray semantics.
- **Cross-tool import** (e.g. opening jas-authored SVG in Inkscape).
  The `data-jas-*` attribute is ignored; the path renders preserve-mode
  with the literal dasharray. The alignment intent is lost in the
  cross-tool import, which is the conscious tradeoff: source-of-truth
  remains the user's typed values, not render-time-derived ones.

A future "interoperable export" mode (when we add print / publish
output) can opt to pre-tessellate the aligned dashes into solid
sub-paths at export time. That output is renderer-derived and lossy
on round-trip — fine for printable output, never the workspace's
canonical save format.

## Edge cases

- **Zero-length segment.** `arc_length(a, b) = 0`. `solve_segment_period`
  returns `n = 0` → emit no dash for this segment.
- **Pattern of length 1** (`dash_array = [d]`, single dash, no gap).
  Equivalent to a solid stroke. The `walk_dashes` step emits one dash
  per period, but successive dashes butt against each other with no
  gap → visually one solid stroke. Correct behavior, no special case
  needed.
- **All-gap pattern** (`dash_array = [0, g]` or similar). The dash
  intervals all have zero length → no sub-paths emitted. The path is
  invisible. Matches preserve-mode behavior, expected.
- **Subpath with one anchor and zero segments.** Degenerate; emit
  nothing.
- **Subpath with two anchors and one segment, open**
  (`END_END` boundary). One segment, full dashes at both ends.
- **Subpath with two anchors and one segment, closed**
  (`INTERIOR_INTERIOR` boundary). Algorithm handles uniformly.
- **Very short segments** (`L < P`). `solve_segment_period` returns
  `n = 0` for `INTERIOR_INTERIOR` — handled by the snap-to-single-dash
  edge case above.

## Cross-language parity tests

Pin three reference inputs in every app's test suite. The
`expand_dashed_stroke` function must return identical sub-path lists
across all five apps for these inputs:

1. **Closed rect.** A 100×60 axis-aligned rectangle, dasharray
   `[12, 6]`, align mode on. Verifies symmetric anchor centering on a
   simple closed shape.
2. **Open zigzag.** Three line segments forming a 'z' shape, total
   arc-length ~150 pt, dasharray `[12, 6, 0, 6]`, align mode on.
   Verifies endpoint full-dash + interior-anchor centering.
3. **Compound path.** Two disjoint subpaths in one element (a square +
   a triangle), dasharray `[10, 4]`, align mode on. Verifies
   per-subpath independence.

Each test asserts the emitted sub-path list as JSON; the JSON is
generated once per language from the algorithm and compared to a
shared golden file under `transcripts/`.

## Out of scope (future work)

- **Custom alignment points.** Future: align to user-tagged anchors
  only (e.g., "corner" anchors but not "smooth" anchors). Today every
  anchor is treated as an alignment point.
- **Per-segment override.** Future: toggle alignment per-stroke or
  per-shape; today it's a single document-model bool.
- **Print / publish export.** A future export pipeline will
  pre-tessellate aligned dashes into solid sub-paths for
  cross-tool fidelity.
- **`Object → Path → Outline Stroke` command.** The same
  `expand_dashed_stroke` engine, but applied as a destructive
  conversion that replaces the dashed stroke with a compound path
  in the document.
